#!/usr/bin/env bash
# code-master:title win-box · 宿主核显姿态（lib/host.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 「宿主核显姿态」有两种，本文件负责在它们之间切换，并让判定可复现：
#
#   passthrough（直通姿态，默认）
#     /etc/modprobe.d/vfio.conf : options vfio-pci ids=…  + softdep amdgpu pre: vfio-pci
#     amdgpu 被黑名单挡住；initramfs 里没有 amdgpu；核显绑在 vfio-pci 上
#     → 宿主不用它，客机才能直通
#
#   host（宿主姿态）
#     上述配置全部撤掉；amdgpu 可正常加载；核显交回宿主
#     → 用于把核显还给宿主（编码 / 多屏 / 调试），或验证"到底是哪一层在挡"
#
# 三个实测事实（决定了"开关"该动哪一层，动错了就表现为"改了却没生效"）：
#
#   1. **真正起作用的是"谁在开机阶段先把设备认领走"**：
#        `options vfio-pci ids=…`（认领）+ vfio_pci 在开机模块表里（早于 amdgpu 执行）
#      两者配合，在 initramfs 阶段就完成抢占；之后 amdgpu 根本没机会绑定。
#   2. **`blacklist amdgpu` 是装饰**（本工具不再管理它，也不再把它当冲突报）：
#        - 拦不住显式 modprobe：`modprobe amdgpu` 照样把依赖链解析出来（核显复位就靠这个）
#        - 它对 alias 自动加载确实有效，但那一层本来就是多余的——设备早被 vfio-pci 占住了
#      所以"黑名单在不在"与"能不能直通"无关；留着无害，只在 detail 里如实报出。
#   3. **modprobe.d 会被打进 initramfs**：改完必须 update-initramfs，否则早期启动仍按旧配置走。
#      因此两个方向都可能"需要重启才完全生效"。
#      内核参数（video=efifb:off / initcall_blacklist=sysfb_init）**不用动**：
#      它们只关掉简单 framebuffer（正是为了让 amdgpu 干净接管），不影响 amdgpu 工作。
#
# 所有函数都可单独调用（场景 4）。检测类函数只读，切换类函数受 --dry-run 控制。

[[ -n ${WB_LIB_HOST_LOADED:-} ]] && return 0
WB_LIB_HOST_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"
# shellcheck source=./conf.sh
[[ -n ${WB_LIB_CONF_LOADED:-} ]] || source "$WB_LIB_DIR/conf.sh"
# shellcheck source=./pci.sh
[[ -n ${WB_LIB_PCI_LOADED:-} ]] || source "$WB_LIB_DIR/pci.sh"
# shellcheck source=./gpu.sh
[[ -n ${WB_LIB_GPU_LOADED:-} ]] || source "$WB_LIB_DIR/gpu.sh"

WB_CONF_KEYS+=(WB_HOST_GPU_MODE)

# 可覆盖，便于离线测试（与 wb_lg__qemu_conf_acl_render 同一手法）
WB_HOST_GPU_DIR=${WB_HOST_GPU_DIR:-/etc/modprobe.d}
WB_HOST_GPU_MANAGED=${WB_HOST_GPU_MANAGED:-$WB_HOST_GPU_DIR/vfio.conf}
WB_HOST_GPU_MODFILE=${WB_HOST_GPU_MODFILE:-/etc/initramfs-tools/modules}
WB_HOST_GPU_LOADFILE=${WB_HOST_GPU_LOADFILE:-/etc/modules-load.d/vfio-pci.conf}

# ── 检测（只读；不打印其它东西）──────────────────────────────────────────

# 任意非注释行里是否黑名单了 amdgpu
wb_host_gpu_blacklisted() {
  local f
  for f in "$WB_HOST_GPU_DIR"/*.conf; do
    [[ -f $f ]] || continue
    # grep 只看没有被 # 开头的行
    if grep -qE '^[[:space:]]*blacklist[[:space:]]+amdgpu([[:space:]]|$)' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# 任意非注释行里是否有 options vfio-pci ... ids=
wb_host_gpu_has_vfio_ids() {
  local f
  for f in "$WB_HOST_GPU_DIR"/*.conf; do
    [[ -f $f ]] || continue
    if grep -qE '^[[:space:]]*options[[:space:]]+vfio-pci[[:space:]].*ids=' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# 是否有 softdep amdgpu pre: vfio-pci
wb_host_gpu_has_softdep() {
  local f
  for f in "$WB_HOST_GPU_DIR"/*.conf; do
    [[ -f $f ]] || continue
    if grep -qE '^[[:space:]]*softdep[[:space:]]+amdgpu[[:space:]]+pre:[[:space:]]*vfio-pci' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# 开机模块表里是否有**未注释**的 amdgpu（有 = 早期会加载它，与 ids= 抢占相互矛盾）
wb_host_gpu_amdgpu_in_bootlist() {
  [[ -r $WB_HOST_GPU_MODFILE ]] || return 1
  grep -qE '^[[:space:]]*amdgpu[[:space:]]*$' "$WB_HOST_GPU_MODFILE"
}

# 开机模块表里是否有**未注释**的 vfio_pci（有 = 早期就能抢占）
wb_host_gpu_vfio_in_bootlist() {
  [[ -r $WB_HOST_GPU_MODFILE ]] || return 1
  grep -qE '^[[:space:]]*vfio_pci[[:space:]]*$' "$WB_HOST_GPU_MODFILE"
}

# 结论：passthrough | host | mixed
#   判定只看**持久化配置**，不看当前绑定状态 —— "刚切完还没重启"是真实存在的中间态，
#   那属于 detail 要显示的信息，不该让结论本身摇摆。
#
#   规则的根据（第 1 条事实）：`options vfio-pci ids=` 是**真正认领设备**的那一方，
#   所以它存在就是直通姿态。唯一称得上矛盾的是"既要抢占(ids=) 又要早期加载 amdgpu
#   (开机模块表里有 amdgpu)"——那取决于加载顺序，脆弱，判为 mixed 并出声。
#   黑名单**不参与判定**（它拦不住显式 modprobe，也拦不住已经认领设备的 vfio-pci）。
wb_host_gpu_detect() {
  wb_host_gpu_has_vfio_ids || { printf 'host\n'; return 0; }
  if wb_host_gpu_amdgpu_in_bootlist; then printf 'mixed\n'; else printf 'passthrough\n'; fi
}

# 人类/机器可读的细节（供 status 与 evidence 用）
wb_host_gpu_detail() {
  local gpu drv bl ids sd
  gpu=$(wb_conf_get_default WB_GPU_BDF '')
  drv='（未配置核显）'
  [[ -n $gpu ]] && drv=$(wb_pci_driver "$gpu")
  wb_host_gpu_blacklisted && bl=yes || bl=no
  wb_host_gpu_has_vfio_ids && ids=yes || ids=no
  wb_host_gpu_has_softdep && sd=yes || sd=no
  printf 'mode=%s\n' "$(wb_host_gpu_detect)"
  printf 'desired=%s\n' "$(wb_conf_get_default WB_HOST_GPU_MODE '')"
  printf 'vfio_ids=%s\n' "$ids"
  printf 'softdep=%s\n' "$sd"
  printf 'blacklisted=%s\n' "$bl（仅记录：拦不住显式 modprobe，且设备已被 vfio-pci 认领，无实际作用）"
  printf 'amdgpu_bound=%s\n' "$(awk '$1=="amdgpu"{print $3}' /proc/modules 2>/dev/null || echo 0)"
  printf 'bootlist_amdgpu=%s\n' "$(wb_host_gpu_amdgpu_in_bootlist && echo yes || echo no)"
  printf 'bootlist_vfio=%s\n' "$(wb_host_gpu_vfio_in_bootlist && echo yes || echo no)"
  printf 'driver=%s\n' "$drv"
  # 注意：不要写成 `lsmod | grep -q` —— grep -q 命中即退出会让 lsmod 收 SIGPIPE(141)，
  # 在 pipefail 下整条管道被判失败，于是永远输出 no（踩过；直接读 /proc/modules 没这个坑）
  printf 'amdgpu_loaded=%s\n' "$(grep -q '^amdgpu' /proc/modules 2>/dev/null && echo yes || echo no)"
  printf 'framebuffer_in_use=%s\n' "$(wb_host_gpu_amdgpu_in_use && echo yes || echo no)"
}

# 冲突：不在我们管的文件里出现的黑名单 / ids 配置（每行 "文件:行号:内容"）
wb_host_gpu_conflicts() {
  local f managed_real
  managed_real=$(readlink -f "$WB_HOST_GPU_MANAGED" 2>/dev/null || printf '%s' "$WB_HOST_GPU_MANAGED")
  for f in "$WB_HOST_GPU_DIR"/*.conf "$WB_HOST_GPU_DIR"/*.conf.disabled; do
    [[ -f $f ]] || continue
    [[ $(readlink -f "$f" 2>/dev/null || printf '%s' "$f") == "$managed_real" ]] && continue
    # 只报**真正有效**的两类：谁认领设备（ids=）与加载顺序（softdep）。
    # blacklist amdgpu 不算冲突 —— 它拦不住显式 modprobe，结局由谁先认领决定。
    grep -nE '^[[:space:]]*(options[[:space:]]+vfio-pci[[:space:]].*ids=|softdep[[:space:]]+amdgpu[[:space:]]+pre:)' \
      "$f" 2>/dev/null | sed "s|^|$f:|"
  done
  return 0
}

# 核显是否正被宿主使用：
#   只查**核显自己**的 DRM 卡（曾经误写成 /sys/class/drm/card*/status —— 既看了别人的卡，
#   而且那个路径根本不存在：连接器状态在 card0-HDMI-A-1/status 这类目录里）
wb_host_gpu_amdgpu_in_use() {
  local gpu p card c st links=()
  gpu=$(wb_conf_get_default WB_GPU_BDF '')
  [[ -n $gpu ]] || return 1
  p="/sys/bus/pci/devices/$gpu/drm"
  [[ -d $p ]] || return 1        # 连 DRM 节点都没有 = 显示栈根本没接管核显

  card=''
  for c in "$p"/card[0-9]*; do
    [[ -e $c ]] || continue
    card=$(basename -- "$c")
    break
  done
  [[ -n $card ]] || return 1

  # 已连接的输出（显示器/HDMI 接收端）
  for c in /sys/class/drm/"$card"-*/status; do
    [[ -r $c ]] || continue
    st=$(cat "$c" 2>/dev/null)
    [[ $st == connected ]] && return 0
  done

  # 有进程打开着该卡的设备节点（by-path 精确指向核显；没有该目录就跳过这条判据）
  for c in /dev/dri/by-path/pci-"$gpu"-*; do
    [[ -e $c ]] && links+=("$c")
  done
  if (( ${#links[@]} )) && wb_have_cmd fuser; then
    fuser -s "${links[@]}" 2>/dev/null && return 0
  fi
  return 1
}

wb_host_gpu_vm_running() {
  local vm
  wb_have_cmd virsh || return 1
  vm=$(wb_conf_get_default WB_VM_NAME win11)
  [[ $(virsh -c qemu:///system domstate "$vm" 2>/dev/null | tr -d ' ') == running ]]
}

# ── 持久化配置 ────────────────────────────────────────────────────────────

# 需要从配置/硬件拿到的 vendor:device
wb_host_gpu__ids() {
  local gpu aud gid aid
  gpu=$(wb_conf_get_default WB_GPU_BDF '')
  aud=$(wb_conf_get_default WB_AUDIO_BDF '')
  gid=$(wb_conf_get_default WB_GPU_ID '')
  aid=$(wb_conf_get_default WB_AUDIO_ID '')
  dev_id_of() {
    local bdf=${1:-} d
    [[ -n $bdf ]] || return 0
    d="/sys/bus/pci/devices/$bdf"
    [[ -r $d/vendor && -r $d/device ]] || return 0
    printf '%s:%s\n' "$(sed 's/^0x//' "$d/vendor")" "$(sed 's/^0x//' "$d/device")"
  }
  [[ -n $gid ]] || gid=$(dev_id_of "$gpu")
  [[ -n $aid ]] || aid=$(dev_id_of "$aud")
  [[ -n $gid ]] || wb_fail 3 host-gpu "读不到核显的 vendor:device（先跑 winbox detect --write）" \
    "docs/interfaces/01-winbox-cli.md"
  if [[ -n $aid ]]; then printf '%s,%s\n' "$gid" "$aid"; else printf '%s\n' "$gid"; fi
}

# initramfs 模块表：passthrough 要求 amdgpu 不在、vfio 三件套在
# 返回 0 = 有改动
wb_host_gpu__initramfs_passthrough() {
  local changed=0 tmp
  [[ -f $WB_HOST_GPU_MODFILE ]] || wb_run touch "$WB_HOST_GPU_MODFILE"
  if grep -qE '^[[:space:]]*amdgpu[[:space:]]*$' "$WB_HOST_GPU_MODFILE" 2>/dev/null; then
    if wb_is_dry_run; then
      wb_log "  [dry-run] 从 $WB_HOST_GPU_MODFILE 注释掉 amdgpu"
    else
      tmp=$(mktemp)
      awk '{ if ($0 ~ /^[ \t]*amdgpu[ \t]*$/) print "# amdgpu（win-box：已从 initramfs 移除，核显交给 vfio-pci）"; else print }' \
        "$WB_HOST_GPU_MODFILE" > "$tmp"
      cp -a "$WB_HOST_GPU_MODFILE" "${WB_HOST_GPU_MODFILE}.bak.$(date +%Y%m%d%H%M%S)"
      install -m 644 "$tmp" "$WB_HOST_GPU_MODFILE"
      rm -f "$tmp"
      wb_ok '已从 initramfs 模块表移除 amdgpu'
    fi
    changed=1
  fi
  local m
  for m in vfio vfio_iommu_type1 vfio_pci; do
    if ! grep -qE "^[[:space:]]*${m}[[:space:]]*$" "$WB_HOST_GPU_MODFILE" 2>/dev/null; then
      if wb_is_dry_run; then
        wb_log "  [dry-run] 向 $WB_HOST_GPU_MODFILE 追加 $m"
      else
        # 追加必须走 wb_write 之外的显式分支：>> 会绕过 --dry-run 直接创建文件
        printf '%s\n' "$m" >> "$WB_HOST_GPU_MODFILE"
        wb_ok "已把 $m 加入 initramfs 模块表"
      fi
      changed=1
    fi
  done
  return "$(( changed ? 0 : 1 ))"
}

# 写 passthrough 姿态的 modprobe.d + initramfs（持久化部分；返回 0=有改动，1=无需改动）
# 黑名单只在"别处没有"时才由我们写，避免与系统/用户既有文件重复
wb_host_gpu_config_passthrough() {
  local ids want current changed=0 rc=0
  # 注意：wb_fail 在 $( ) 里只退出子壳 —— 必须显式把失败码传出去，
  # 否则会带着空 ids 继续写配置（踩过）
  ids=$(wb_host_gpu__ids) || rc=$?
  if (( rc != 0 )); then return "$rc"; fi

  # 认领设备的那一行（真正起作用的配置）+ 加载顺序。不再写 blacklist —— 它无作用，
  # 写进来只会让人误以为它是关键（实测：`modprobe amdgpu` 照样能加载）。
  want="options vfio-pci ids=$ids
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci"

  current=$(cat "$WB_HOST_GPU_MANAGED" 2>/dev/null || true)
  if [[ $current == "$want" ]]; then
    wb_ok "$WB_HOST_GPU_MANAGED 已是直通姿态"
  else
    wb_write "$WB_HOST_GPU_MANAGED" "$want"
    wb_ok "已写入 $WB_HOST_GPU_MANAGED（ids=$ids）"
    changed=1
  fi

  if [[ -f $WB_HOST_GPU_LOADFILE ]]; then
    wb_ok 'vfio-pci 已配置开机加载'
  elif grep -qE '^[[:space:]]*vfio_pci[[:space:]]*$' "$WB_HOST_GPU_MODFILE" 2>/dev/null; then
    wb_ok 'vfio_pci 已在 initramfs 模块表里（无需额外 modules-load 条目）'
  else
    wb_write "$WB_HOST_GPU_LOADFILE" 'vfio-pci'
    wb_ok '已配置 vfio-pci 开机加载'
    changed=1
  fi

  wb_host_gpu__initramfs_passthrough && changed=1

  if (( changed )) && ! wb_is_dry_run; then
    wb_run update-initramfs -u -k all || return 1
    wb_ok 'initramfs 已重建'
  fi
  return "$(( changed ? 0 : 1 ))"
}

# 写 host 姿态（撤掉我们的配置；冲突项需要 --takeover）
# 返回 0=有改动，1=无需改动
wb_host_gpu_config_host() {
  local takeover=${1:-} changed=0 conflicts bootunits
  # 开机脚本同样算冲突：它会在每次开机把核显抢回 vfio-pci，让 host 姿态失效。
  # （本工具**不新建服务**，只探测——以及在你明确要求时停用遗留的。）
  bootunits=$(wb_host_gpu_boot_units)
  if [[ -n $bootunits ]]; then
    wb_warn '检测到开机脚本会在每次开机把核显绑回 vfio-pci：'
    printf '%s\n' "$bootunits" | awk -F'|' '{printf "      %s → %s\n", $1, $3}' >&2
    if [[ $takeover == --takeover ]]; then
      wb_host_gpu_disable_boot_units
      changed=1
    else
      wb_fail 3 host-gpu '存在开机绑定脚本，未做改动（sudo winbox host-gpu host --takeover 会停用并归档它）' \
        "docs/interfaces/01-winbox-cli.md"
    fi
  fi

  conflicts=$(wb_host_gpu_conflicts)
  if [[ -n $conflicts ]]; then
    wb_warn '以下位置还有直通相关配置（不是 win-box 管的文件，默认不改动）：'
    printf '%s\n' "$conflicts" | sed 's/^/      /' >&2
    if [[ $takeover == --takeover ]]; then
      wb_host_gpu_clean_conflicts
      changed=1
    else
      wb_fail 3 host-gpu '存在冲突配置，未做改动（确认后加 --takeover 自动停用它们，或手工处理）' \
        "docs/interfaces/01-winbox-cli.md"
    fi
  fi

  if [[ -f $WB_HOST_GPU_MANAGED ]]; then
    if wb_is_dry_run; then
      wb_log "  [dry-run] 移除 $WB_HOST_GPU_MANAGED"
    else
      cp -a "$WB_HOST_GPU_MANAGED" "${WB_HOST_GPU_MANAGED}.bak.$(date +%Y%m%d%H%M%S)"
      rm -f "$WB_HOST_GPU_MANAGED"
      wb_ok "已移除 $WB_HOST_GPU_MANAGED（备份保留在同目录 .bak.*）"
    fi
    changed=1
  fi

  if [[ -f $WB_HOST_GPU_LOADFILE ]]; then
    wb_run rm -f "$WB_HOST_GPU_LOADFILE"
    wb_ok '已移除 vfio-pci 的 modules-load 条目（可选，已随上面一起撤）'
    changed=1
  fi

  # initramfs 里的 amdgpu 注释：host 姿态下不需要它提前加载，但也不需要改回来；
  # 真正要紧的是重建 initramfs，让里面那份 modprobe.d 不再挡 amdgpu。
  if (( changed )) && ! wb_is_dry_run; then
    wb_run update-initramfs -u -k all || wb_fail 1 host-gpu "update-initramfs 失败" \
      "docs/zh/07-踩坑大全.md"
    wb_ok 'initramfs 已重建（否则早期启动仍按旧的 modprobe.d 走）'
  fi
  return "$(( changed ? 0 : 1 ))"
}

# 注释掉冲突行（备份 + 逐条打印）
wb_host_gpu_clean_conflicts() {
  local line f rest last_backed=''
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    f=${line%%:*}
    rest=${line#*:}
    if wb_is_dry_run; then
      wb_log "  [dry-run] 注释掉 $f 第 ${rest%%:*} 行"
      continue
    fi
    [[ -f $f ]] || continue
    if [[ $f != "$last_backed" ]]; then
      cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
      last_backed=$f
    fi
    sed -i -E 's|^([[:space:]]*)(options[[:space:]]+vfio-pci[[:space:]].*ids=.*)$|# win-box host-gpu --takeover: \1\2|; s|^([[:space:]]*)(softdep[[:space:]]+amdgpu[[:space:]]+pre:.*)$|# win-box host-gpu --takeover: \1\2|' "$f"
    wb_ok "已停用 $f 第 ${rest%%:*} 行（备份 ${f}.bak.*）"
  done <<< "$(wb_host_gpu_conflicts)"
  return 0
}

# ── 运行时的动态 ID（踩过的坑：不清掉就会被抢回）─────────────────────────
#
# `options vfio-pci ids=…` 是在**模块加载时**注册成动态 ID 的，注册后一直有效，
# 直到模块卸载或显式 remove_id。所以"删了 modprobe.d + unbind"并不等于设备自由了：
# 任何 probe/uevent 都会让 vfio-pci 凭旧动态 ID 把设备抢回去（实测：unbind 之后
# drivers_probe 立刻把它抢回，amdgpu 再加载也绑不上）。

# stdout: "vendor device" 形式的 ID 对（每行一对）
wb_host_gpu__id_pairs() {
  local pair
  wb_host_gpu__ids | tr ',' '\n' | while IFS= read -r pair; do
    [[ -n $pair ]] || continue
    printf '%s %s\n' "${pair%%:*}" "${pair##*:}"
  done
}

wb_host_gpu_vfio_remove_ids() {
  local v d
  wb_require_root
  [[ -w /sys/bus/pci/drivers/vfio-pci/remove_id ]] || return 0
  while read -r v d; do
    [[ -n $v && -n $d ]] || continue
    if wb_write /sys/bus/pci/drivers/vfio-pci/remove_id "$v $d"; then
      wb_ok "已从 vfio-pci 移除动态 ID $v:$d"
    else
      wb_log "  （$v:$d 不在 vfio-pci 的动态 ID 里，跳过）"
    fi
  done < <(wb_host_gpu__id_pairs)
  return 0
}

wb_host_gpu_vfio_add_ids() {
  local v d
  wb_require_root
  [[ -w /sys/bus/pci/drivers/vfio-pci/new_id ]] || return 0
  while read -r v d; do
    [[ -n $v && -n $d ]] || continue
    if wb_write /sys/bus/pci/drivers/vfio-pci/new_id "$v $d"; then
      wb_ok "已给 vfio-pci 注册动态 ID $v:$d"
    else
      wb_log "  （$v:$d 已在 vfio-pci 动态 ID 里，跳过）"
    fi
  done < <(wb_host_gpu__id_pairs)
  return 0
}

# ── 开机阶段会"把核显抢回 vfio-pci"的遗留脚本（只探测/停用，不新建）──────
#
# 本工具**不引入 systemd 服务**：只负责发现"别人写的开机绑定脚本"，因为它会在每次
# 开机时覆盖我们的姿态（实测：旧 vfio-bind-gpu.service 会让 host 姿态失效）。
# 探测方式：unit 文件的 ExecStart 指向的脚本里提到 vfio-pci，且该 unit 处于 enabled。

WB_HOST_GPU_SYSTEMD=${WB_HOST_GPU_SYSTEMD:-/etc/systemd/system}

# 要扫描的 systemd 目录（去重；WB_HOST_GPU_SYSTEMD 可覆盖，测试用）
wb_host_gpu__systemd_dirs() {
  printf '%s\n' "$WB_HOST_GPU_SYSTEMD" /etc/systemd/system /usr/lib/systemd/system | awk '!seen[$0]++'
}

# unit 是否处于启用状态：先看 .wants 软链（文件系统判据 —— 可测、且不依赖 systemd 运行），
# 再退回问 systemctl（覆盖 enable --now 到别的 target 之类的情况）
wb_host_gpu__unit_enabled() {
  local unit=${1:-} d
  for d in "$WB_HOST_GPU_SYSTEMD" /etc/systemd/system; do
    if [[ -L "$d/multi-user.target.wants/$unit" || -L "$d/graphical.target.wants/$unit" ]]; then
      return 0
    fi
  done
  case $(systemctl is-enabled "$unit" 2>/dev/null || true) in
    enabled | enabled-runtime) return 0 ;;
  esac
  return 1
}

# stdout 每行: <unit名>|<unit文件>|<ExecStart 脚本>
wb_host_gpu_boot_units() {
  local d u ex
  # 目录去重：WB_HOST_GPU_SYSTEMD 默认就是 /etc/systemd/system，写死再列一遍会报两次（踩过）
  for d in $(wb_host_gpu__systemd_dirs); do
    [[ -d $d ]] || continue
    for u in "$d"/*.service; do
      [[ -f $u ]] || continue
      ex=$(awk -F= '/^[[:space:]]*ExecStart=/{print $2; exit}' "$u" 2>/dev/null | awk '{print $1}')
      [[ -n $ex && -f $ex ]] || continue
      grep -qE 'vfio[-_]pci' "$ex" 2>/dev/null || continue
      wb_host_gpu__unit_enabled "$(basename -- "$u")" || continue
      printf '%s|%s|%s\n' "$(basename -- "$u")" "$u" "$ex"
    done
  done
  return 0
}

# 被我们归档过的 unit（'*.disabled-by-winbox'）：stdout 每行 <归档文件>|<ExecStart脚本>
# 只认我们自己的归档标记 —— 系统自带的服务绝不会出现在这里
wb_host_gpu_archived_units() {
  local d f ex
  for d in $(wb_host_gpu__systemd_dirs); do
    for f in "$d"/*.service.disabled-by-winbox; do
      [[ -f $f ]] || continue
      ex=$(awk -F= '/^[[:space:]]*ExecStart=/{print $2; exit}' "$f" 2>/dev/null | awk '{print $1}')
      printf '%s|%s\n' "$f" "${ex:-}"
    done
  done
  return 0
}

# 删除归档 unit 与它引用的脚本（仅限上面探测到的；dry-run 下只打印）
wb_host_gpu_purge_archived_units() {
  local f ex found=0
  while IFS='|' read -r f ex; do
    [[ -n $f ]] || continue
    found=1
    if wb_is_dry_run; then
      # 干跑只列清单，**不能**打印"已删除"（否则就是另一种假成功）
      [[ -n $ex && $ex == /* ]] && wb_log "  [dry-run] 将删除脚本: $ex"
      wb_log "  [dry-run] 将删除归档 unit: $f"
      continue
    fi
    if [[ -n $ex && $ex == /* && -f $ex ]]; then
      rm -f -- "$ex" && wb_ok "已删除脚本: $ex"
    elif [[ -n $ex ]]; then
      wb_log "  （脚本不存在或路径可疑，保留: $ex）"
    fi
    rm -f -- "$f" && wb_ok "已删除归档 unit: $f"
  done < <(wb_host_gpu_archived_units)
  (( found )) || wb_ok '没有我们归档过的 unit（无需清理）'
  # 顺手报告仍然处于启用状态的开机脚本（不在本函数的职责内，只提醒）
  local live
  live=$(wb_host_gpu_boot_units)
  [[ -n $live ]] && wb_warn '仍有处于 enabled 的开机绑定脚本（先用 host-gpu host --takeover 停用，再 purge）'
  if ! wb_is_dry_run; then wb_run systemctl daemon-reload >/dev/null 2>&1 || true; fi
  return 0
}

# --takeover 时停用它们（停用 + 归档 unit 文件，改前不改动脚本本身）
wb_host_gpu_disable_boot_units() {
  local unit file ex
  while IFS='|' read -r unit file ex; do
    [[ -n $unit ]] || continue
    if wb_is_dry_run; then
      wb_log "  [dry-run] systemctl disable --now $unit；归档 $file"
      continue
    fi
    wb_run systemctl disable --now "$unit" >/dev/null 2>&1 || wb_warn "停用 $unit 失败"
    wb_run mv -- "$file" "${file}.disabled-by-winbox"
    wb_ok "已停用并归档: $unit（${file}.disabled-by-winbox；脚本 $ex 未删）"
  done < <(wb_host_gpu_boot_units)
  if ! wb_is_dry_run; then wb_run systemctl daemon-reload >/dev/null 2>&1 || true; fi
  return 0
}

# 带重试的绑定。
# 依据（实测）：刚 unbind —— 尤其 unbind amdgpu 会触发 MODE2 reset —— 之后立刻 bind
# 可能失败（设备处于瞬时状态）；同一台机器上第一次失败、几分钟后重试即成功。
# 因此这里重试若干次，仍失败才交给回退路径（drivers_probe）与最终的校验报告。
wb_host_gpu__bind_retry() {
  local bdf=$1 drv=$2 tries=${3:-3} wait=${4:-2} i
  for (( i = 1; i <= tries; i++ )); do
    if wb_pci_try_bind "$bdf" "$drv"; then return 0; fi
    (( i < tries )) || break
    wb_log "  重试绑定 $bdf → $drv（第 $((i + 1))/$tries 次，等 ${wait}s）"
    wb_run sleep "$wait"
  done
  return 1
}

# ── 立即生效（当前会话）───────────────────────────────────────────────────

# 把核显交给 vfio-pci（当前会话）。返回 0 = 已校验达成目标
wb_host_gpu_live_passthrough() {
  local gpu aud d drv ok=1
  wb_require_root
  gpu=$(wb_conf_get_default WB_GPU_BDF '')
  aud=$(wb_conf_get_default WB_AUDIO_BDF '')
  [[ -n $gpu ]] || wb_fail 3 host-gpu '未配置 WB_GPU_BDF' 'docs/interfaces/01-winbox-cli.md'

  # 让运行中的 vfio_pci 也带上动态 ID（与持久化姿态一致；否则后续 uevent 可能把它交给别人）
  wb_host_gpu_vfio_add_ids

  # 逐个设备尽力而为：**用软变体**，任一失败都不中断循环
  # （严格版 wb_pci_* 会 wb_fail 退出，`|| true` 拦不住 —— 实测踩过）
  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    [[ $(wb_pci_driver "$d") == vfio-pci ]] && continue
    wb_pci_try_override "$d" vfio-pci
    wb_pci_try_unbind "$d"
    if ! wb_host_gpu__bind_retry "$d" vfio-pci; then
      # 回退：让内核按 ID 重新匹配（动态 ID 已注册时这条能成）
      wb_log "  回退：让内核按 ID 重新匹配 $d"
      wb_pci_try_probe "$d"
    fi
  done

  # 校验后才打勾（曾经在校验之前就打印"已交回宿主"，出现自相矛盾的输出）
  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    if wb_pci_wait_driver "$d" vfio-pci 10; then
      wb_ok "$d → vfio-pci（已校验）"
    else
      drv=$(wb_pci_driver "$d"); wb_warn "$d 目标 vfio-pci，当前 $drv"
      ok=0
    fi
  done
  (( ok )) && return 0 || return 1
}

# 把核显交回宿主（当前会话）。返回 0 = 已校验达成目标
#   目标驱动：VGA 功能 → amdgpu；HDMI 音频功能 → snd_hda_intel（不是 amdgpu！）
wb_host_gpu_live_host() {
  local gpu aud d drv want ok=1
  wb_require_root
  gpu=$(wb_conf_get_default WB_GPU_BDF '')
  aud=$(wb_conf_get_default WB_AUDIO_BDF '')
  [[ -n $gpu ]] || wb_fail 3 host-gpu '未配置 WB_GPU_BDF' 'docs/interfaces/01-winbox-cli.md'

  # ① 清掉运行中 vfio_pci 的动态 ID —— 不清就等着被抢回（实测踩过）
  wb_host_gpu_vfio_remove_ids

  # ② 清 driver_override（否则它钉死归属，amdgpu 绑不上）并解绑
  #    软变体：任一设备失败也不中断整条流程
  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    wb_pci_try_override_clear "$d"
    [[ $(wb_pci_driver "$d") == vfio-pci ]] && wb_pci_try_unbind "$d"
  done

  # ③ **先加载模块，再显式绑定** —— 原来顺序反了（probe 在 modprobe 之前），
  #    那会儿目标驱动还不存在，设备只能被 vfio-pci 抢回
  wb_run modprobe amdgpu || wb_warn 'modprobe amdgpu 失败（模块装了？看 dmesg）'
  [[ -n $aud ]] && wb_run modprobe snd_hda_intel || true

  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    want=amdgpu
    [[ $d == "$aud" ]] && want=snd_hda_intel
    [[ $(wb_pci_driver "$d") == "$want" ]] && continue
    wb_host_gpu__bind_retry "$d" "$want" || wb_pci_try_probe "$d"
  done

  # ④ 校验后才打勾
  for d in "$gpu" "$aud"; do
    [[ -n $d ]] || continue
    want=amdgpu
    [[ $d == "$aud" ]] && want=snd_hda_intel
    if wb_pci_wait_driver "$d" "$want" 10; then
      wb_ok "$d → $want（已校验）"
    else
      drv=$(wb_pci_driver "$d"); wb_warn "$d 目标 $want，当前 $drv"
      ok=0
    fi
  done
  (( ok )) && return 0 || return 1
}
