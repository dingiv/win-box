#!/usr/bin/env bash
# code-master:title win-box · PCI 设备操作（lib/pci.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 本文件把**三个内核陷阱**固化成函数——它们是本项目最大的隐性知识：
#
#   1) driver_override 必须在 unbind **之前**写。
#      否则 /etc/modprobe.d/vfio.conf 里的 `options vfio-pci ids=...` 会让
#      vfio-pci 在解绑的瞬间把设备抢回去，复位轮回直接失效。
#   2) unbind 之后内核**不会**自动重新探测，必须显式写 /sys/bus/pci/drivers_probe。
#   3) unbind 文件里要写**设备名**（0000:0d:00.0），不是驱动名。
#
# 约定：写操作幂等（已达成目标状态就不动手），且一律经 wb_write 以便 --dry-run 生效。

[[ -n ${WB_LIB_PCI_LOADED:-} ]] && return 0
WB_LIB_PCI_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"

wb__pci_path() { printf '/sys/bus/pci/devices/%s\n' "$1"; }

# ── 查询（不需要 root，永不失败）─────────────────────────────────────────

wb_pci_exists() { [[ -d $(wb__pci_path "$1") ]]; }

# stdout = 当前驱动名，或 (none)
wb_pci_driver() {
  local p
  p=$(wb__pci_path "$1")
  if [[ -e $p/driver ]]; then
    basename -- "$(readlink -f "$p/driver")"
  else
    printf '(none)\n'
  fi
  return 0
}

wb_pci_driver_override() {
  local p
  p=$(wb__pci_path "$1")
  if [[ -r $p/driver_override ]]; then cat "$p/driver_override"; else printf '\n'; fi
  return 0
}

# ── 写操作（需要 root；失败码 1 = 内核拒绝了这次写）──────────────────────

wb__pci_require() {
  [[ -d $(wb__pci_path "${1:-}") ]] || wb_fail 4 pci "设备不存在: ${1:-}" "docs/interfaces/04-lib-api.md"
  wb_require_root
}

# 钉死驱动归属（陷阱 1 的前半：必须在 unbind 之前调用）
wb_pci_override() {
  local bdf=${1:-} drv=${2:-}
  wb__pci_require "$bdf"
  [[ -n $drv ]] || wb_fail 2 pci "wb_pci_override 需要驱动名" "docs/interfaces/04-lib-api.md"
  wb_write "$(wb__pci_path "$bdf")/driver_override" "$drv" \
    || wb_fail 1 pci "写 driver_override 失败: $bdf（内核 < 4.9 或该属性不可写）" \
      "docs/interfaces/04-lib-api.md"
}

wb_pci_override_clear() {
  local bdf=${1:-}
  wb__pci_require "$bdf"
  wb_write "$(wb__pci_path "$bdf")/driver_override" "" \
    || wb_fail 1 pci "清空 driver_override 失败: $bdf" "docs/interfaces/04-lib-api.md"
}

# 从当前驱动解绑（陷阱 3：写设备名）；未绑定 → 直接成功（幂等）
wb_pci_unbind() {
  local bdf=${1:-} p
  wb__pci_require "$bdf"
  p=$(wb__pci_path "$bdf")
  [[ -e $p/driver ]] || return 0
  wb_write "$p/driver/unbind" "$bdf" \
    || wb_fail 1 pci "解绑失败: $bdf（当前驱动 $(wb_pci_driver "$bdf")）" \
      "docs/interfaces/04-lib-api.md"
}

# 触发内核重新探测（陷阱 2：unbind 后必须显式调用，否则设备停在无驱动状态）
wb_pci_probe() {
  local bdf=${1:-}
  wb__pci_require "$bdf"
  wb_write /sys/bus/pci/drivers_probe "$bdf" \
    || wb_fail 1 pci "drivers_probe 失败: $bdf" "docs/interfaces/04-lib-api.md"
}

# 绑定到指定驱动；已在该驱动上 → 直接成功（幂等）
wb_pci_bind() {
  local bdf=${1:-} drv=${2:-}
  wb__pci_require "$bdf"
  [[ -n $drv ]] || wb_fail 2 pci "wb_pci_bind 需要驱动名" "docs/interfaces/04-lib-api.md"
  [[ $(wb_pci_driver "$bdf") == "$drv" ]] && return 0
  wb_write "/sys/bus/pci/drivers/$drv/bind" "$bdf" \
    || wb_fail 1 pci "绑定失败: $bdf → $drv（驱动未加载？）" "docs/interfaces/04-lib-api.md"
}

# ── "软"变体：返回 1 而不是 wb_fail 退出 ─────────────────────────────────
#
# 为什么需要：`wb_pci_bind x y || true` **拦不住** wb_fail —— 它是 exit，
# 于是"尽力而为"的循环会在第一个失败处整体中断（实测踩过：GPU 绑定失败后
# 音频没处理、期望姿态没写、设备被丢在无驱动状态）。
# 软变体还负责**把内核的原话带出来**（errno 文本），否则失败原因无从查起。

# 写 sysfs 并把内核/shell 的错误信息回显出来（不退出）
wb__pci_write_report() {
  local path=$1 value=$2 what=$3 msg
  [[ -n $path ]] || { wb_warn "${what:-写 sysfs} 失败：缺少路径"; return 1; }
  if wb_is_dry_run; then
    wb_log "  [dry-run] $path ← ${value:-（空）}"
    return 0
  fi
  # 注意括号：重定向失败时是 **shell** 报错，必须把整个语句组重定向才能捕获到
  if msg=$( { printf '%s\n' "$value" > "$path"; } 2>&1 ); then
    return 0
  fi
  wb_warn "${what:-写 sysfs} 失败: ${msg:-（内核未返回信息）}（$path ← ${value:-（空）}）"
  return 1
}

wb_pci_try_override() {
  local bdf=${1:-} drv=${2:-}
  [[ -d $(wb__pci_path "$bdf") ]] || { wb_warn "设备不存在: $bdf"; return 1; }
  wb__pci_write_report "$(wb__pci_path "$bdf")/driver_override" "$drv" "$bdf driver_override=$drv"
}

wb_pci_try_override_clear() {
  local bdf=${1:-}
  [[ -d $(wb__pci_path "$bdf") ]] || { wb_warn "设备不存在: $bdf"; return 1; }
  wb__pci_write_report "$(wb__pci_path "$bdf")/driver_override" "" "$bdf 清 driver_override"
}

wb_pci_try_unbind() {
  local bdf=${1:-} p
  p=$(wb__pci_path "$bdf")
  [[ -e $p/driver ]] || return 0
  wb__pci_write_report "$p/driver/unbind" "$bdf" "$bdf 解绑（当前 $(wb_pci_driver "$bdf")）"
}

wb_pci_try_bind() {
  local bdf=${1:-} drv=${2:-}
  [[ $(wb_pci_driver "$bdf") == "$drv" ]] && return 0
  wb__pci_write_report "/sys/bus/pci/drivers/$drv/bind" "$bdf" "$bdf 绑定 $drv"
}

# 触发内核按 ID 匹配重新认领（在 driver_override 路径失败时可作回退）
wb_pci_try_probe() {
  local bdf=${1:-}
  wb__pci_write_report /sys/bus/pci/drivers_probe "$bdf" "$bdf drivers_probe"
}

# 轮询等待驱动就位；超时 → 返回 1（**不退出**，由调用方决定严苛程度）
wb_pci_wait_driver() {
  local bdf=${1:-} drv=${2:-} timeout=${3:-20} i
  for (( i = 0; i < timeout; i++ )); do
    [[ $(wb_pci_driver "$bdf") == "$drv" ]] && return 0
    sleep 1
  done
  return 1
}
