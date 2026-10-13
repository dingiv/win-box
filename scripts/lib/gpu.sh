#!/usr/bin/env bash
# code-master:title win-box · 核显专用操作（lib/gpu.sh）
#
# 契约：docs/interfaces/04-lib-api.md ／ 链路：docs/calltrees/03-vm-start-and-reset-hook.md
#
# 本文件只有一个"主角"：wb_gpu_reset_cycle —— 用 amdgpu 做一次真复位（MODE2 reset），
# 让 AMD 核显从"脏状态"回到可被 vfio-pci 交付给客机的状态。
#
# 谁调用它：**`winbox vm start`**（启动 VM 之前自动执行）。本项目**不使用 libvirt 钩子、
# 也不安装任何 systemd 服务** —— 复位就是启动流程里的一个步骤，由我们自己的命令驱动：
# 这样它和"当前姿态""是否 root""有没有别的机制在抢设备"都在同一处可见、可诊断。
#
# ★ 约束：本函数内部不使用 wb_fail（失败降级为日志），返回值表达结果：
#     0 = 确实做了一次复位（amdgpu 绑上又被解绑 → 内核执行 MODE2 reset）
#     1 = 未能复位（amdgpu 不可用等）—— 由调用方决定是警告还是拒绝继续

[[ -n ${WB_LIB_GPU_LOADED:-} ]] && return 0
WB_LIB_GPU_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"
# shellcheck source=./conf.sh
[[ -n ${WB_LIB_CONF_LOADED:-} ]] || source "$WB_LIB_DIR/conf.sh"
# shellcheck source=./pci.sh
[[ -n ${WB_LIB_PCI_LOADED:-} ]] || source "$WB_LIB_DIR/pci.sh"

WB_RESET_LOG=${WB_RESET_LOG:-/var/log/winbox-reset.log}

# 复位过程的每一步都要留下痕迹：日志文件（有权限时）+ stderr
wb__gpu_log() {
  wb_log "$*"
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$WB_RESET_LOG" 2>/dev/null || true
}

# ── 复位轮回 ──────────────────────────────────────────────────────────────
# wb_gpu_reset_cycle [WAIT_SECONDS]
#   永远 return 0；退出码不代表成败，日志才代表。
wb_gpu_reset_cycle() {
  local wait_s=${1:-} gpu aud drv t0=$SECONDS reset_done=0

  gpu=$(wb_conf_get_default WB_GPU_BDF "")
  aud=$(wb_conf_get_default WB_AUDIO_BDF "")
  [[ -n $wait_s ]] || wait_s=$(wb_conf_get_default WB_REBOOT_WAIT 30)

  if [[ -z $gpu ]]; then
    wb__gpu_log "[reset] 跳过：未配置 WB_GPU_BDF（先跑 winbox detect --write）"
    return 1
  fi
  if (( EUID != 0 )); then
    wb__gpu_log "[reset] 跳过：需要 root（复位要写 /sys）"
    return 1
  fi

  wb__gpu_log "[reset] 开始 gpu=$gpu audio=${aud:-（无）} wait=${wait_s}s"
  drv=$(wb_pci_driver "$gpu")
  wb__gpu_log "[reset] 起始状态: gpu=$drv"

  # ── 1) 让 amdgpu 短暂接管（目的是触发复位，不是为了使用它）──────────────
  if [[ $drv != amdgpu ]]; then
    wb_pci_override "$gpu" amdgpu || wb__gpu_log "[reset] ⚠ driver_override 失败（继续尝试）"
    if [[ $(wb_pci_driver "$gpu") != "(none)" ]]; then
      wb_pci_unbind "$gpu" || wb__gpu_log "[reset] ⚠ 解绑当前驱动失败"
    fi
    # ★ amdgpu 在我们的配置里被列入黑名单（host-prep 写入），开机不会自动加载，
    #   所以这里必须自己 modprobe；否则冷启动后的第一次启动会静默跳过复位。
    wb_run modprobe amdgpu || wb__gpu_log "[reset] ⚠ modprobe amdgpu 失败（模块可用?）"
    wb_pci_probe "$gpu" || wb__gpu_log "[reset] ⚠ drivers_probe 失败"

    if wb_pci_wait_driver "$gpu" amdgpu 20; then
      wb__gpu_log "[reset] amdgpu 已接管，等待 ${wait_s}s 完成 SMU/PSP/显示初始化"
      wb_run sleep "$wait_s"
    else
      wb__gpu_log "[reset] ⚠ 等待 amdgpu 接管超时（当前 $(wb_pci_driver "$gpu")）——本次无法复位"
    fi
  else
    wb__gpu_log "[reset] 已在 amdgpu 上，跳过接管步骤"
  fi

  # ── 2) 解绑 amdgpu → 内核执行 MODE2 reset ───────────────────────────────
  if [[ $(wb_pci_driver "$gpu") == amdgpu ]]; then
    wb_pci_override_clear "$gpu" || wb__gpu_log "[reset] ⚠ 清空 driver_override 失败"
    wb_pci_unbind "$gpu" || wb__gpu_log "[reset] ⚠ 解绑 amdgpu 失败"
    reset_done=1
    local evidence
    evidence=$(dmesg 2>/dev/null | grep -iE 'MODE2 reset|finishing device' | tail -1 || true)
    wb__gpu_log "[reset] 复位证据: ${evidence:-（dmesg 无相关行）}"
  else
    wb__gpu_log "[reset] ⚠ 未处于 amdgpu，跳过复位（设备状态可能仍是脏的）"
  fi

  # ── 3) 两个功能交回 vfio-pci ─────────────────────────────────────────────
  local d final=""
  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    wb_pci_override "$d" vfio-pci || wb__gpu_log "[reset] ⚠ $d driver_override → vfio-pci 失败"
    wb_pci_bind "$d" vfio-pci || wb__gpu_log "[reset] ⚠ $d 绑定 vfio-pci 失败"
    final+="$d=$(wb_pci_driver "$d") "
  done
  wb__gpu_log "[reset] 结束（$(( SECONDS - t0 ))s）: ${final% }"
  (( reset_done )) || wb__gpu_log "[reset] 结论: 本次**未完成复位**"
  return "$(( reset_done ? 0 : 1 ))"
}

# ── ROM 部署 ──────────────────────────────────────────────────────────────

# wb_gpu_rom_fingerprint FILE → stdout: <sha256前16位> <字节数> <路径>
wb_gpu_rom_fingerprint() {
  local f=${1:-}
  [[ -f $f ]] || wb_fail 3 gpu "ROM 不存在: ${f:-<空>}" "docs/zh/06-最终配置清单与复现步骤.md"
  printf '%s %s %s\n' "$(sha256sum -- "$f" | cut -c1-16)" "$(stat -c%s -- "$f")" "$f"
}

# wb_gpu_deploy_rom SRC DST
#   安装到 WB_VBIOS_DIR 并设 owner=libvirt-qemu:kvm mode=644；
#   拷贝前后校验 sha256 —— ROM 是被 QEMU 读的文件，静默损坏只会表现为"客机起不来"。
#   stdout: 部署后的指纹行
wb_gpu_deploy_rom() {
  local src=${1:-} dst=${2:-} a b
  wb_require_file "$src"
  [[ -n $dst ]] || wb_fail 2 gpu "wb_gpu_deploy_rom 需要目标路径" "docs/interfaces/04-lib-api.md"
  wb_require_root

  local owner=libvirt-qemu
  if ! id -u libvirt-qemu >/dev/null 2>&1; then
    owner=root
    wb_warn "未找到 libvirt-qemu 用户，ROM 属主退化为 root（不影响使用，但权限更宽）"
  fi

  wb_run mkdir -p -- "$(dirname -- "$dst")"
  wb_run install -o "$owner" -g kvm -m 644 -- "$src" "$dst" \
    || wb_fail 1 gpu "安装 ROM 失败: $dst" "docs/zh/06-最终配置清单与复现步骤.md"

  if wb_is_dry_run; then
    printf '%s\n' "dry-run 0 $dst"
    return 0
  fi

  a=$(sha256sum -- "$src" | cut -d' ' -f1)
  b=$(sha256sum -- "$dst" | cut -d' ' -f1)
  [[ $a == "$b" ]] || wb_fail 1 gpu "ROM 拷贝后指纹不一致: $dst" "docs/interfaces/03-romtool.md"
  wb_gpu_rom_fingerprint "$dst"
}

# 把配置里的两个功能绑到 vfio-pci（= 复位轮回第 3 步的独立入口）
wb_gpu_bind_vfio() {
  local gpu aud d
  gpu=$(wb_conf_get_default WB_GPU_BDF "")
  aud=$(wb_conf_get_default WB_AUDIO_BDF "")
  [[ -n $gpu ]] || wb_fail 3 gpu "未配置 WB_GPU_BDF（先跑 winbox detect --write）" \
    "docs/interfaces/01-winbox-cli.md"
  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    wb_pci_override "$d" vfio-pci
    wb_pci_bind "$d" vfio-pci
  done
  return 0
}
