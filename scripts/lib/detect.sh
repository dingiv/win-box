#!/usr/bin/env bash
# code-master:title win-box · 硬件与环境探测（lib/detect.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 本文件**只读**：不改系统、不需要 root。探测结果的格式即契约——
# bin/detect 的报告、配置写入、status 的检查项消费同一份输出。
#
# 一个刻意的设计：核显识别是「启发式 + 显式覆盖」，不是硬编码设备 ID 表。
#   评分依据（分越高越像"核显"）：
#     +2  同槽 .1 功能是同厂商的 HDMI 音频（成对出现是直通的必要条件）
#     +2  全部 BAR 合计 < 4G（核显用系统内存，没有大显存 BAR；独显通常 8–32G）
#   多候选同分 → 报码 4 并列出候选，交给用户在配置里指定 WB_GPU_BDF。
#   硬编码 1002:13c0 这类 ID 只在"本机实录"里有意义，换机器立刻变成错误答案。

[[ -n ${WB_LIB_DETECT_LOADED:-} ]] && return 0
WB_LIB_DETECT_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"
# shellcheck source=./conf.sh
[[ -n ${WB_LIB_CONF_LOADED:-} ]] || source "$WB_LIB_DIR/conf.sh"

wb__pci_path() { printf '/sys/bus/pci/devices/%s\n' "$1"; }

# ── 设备枚举 ──────────────────────────────────────────────────────────────

# 全部显示类设备（不只 AMD）：BDF VENDOR:DEVICE CLASS
wb_detect_display_devices() {
  local d class vendor device
  for d in /sys/bus/pci/devices/*/; do
    [[ -r $d/class ]] || continue
    class=$(cat "$d/class")
    case $class in 0x03*) ;; *) continue ;; esac
    vendor=$(cat "$d/vendor")
    device=$(cat "$d/device")
    printf '%s %s:%s %s\n' "$(basename -- "$d")" "${vendor#0x}" "${device#0x}" "$class"
  done
  return 0
}

# 同槽的 HDMI 音频功能：存在则 stdout 该 BDF，否则返回 1
wb_detect_audio_sibling() {
  local slot=${1%.*}.1 p class
  p=$(wb__pci_path "$slot")
  [[ -e $p/class ]] || return 1
  class=$(cat "$p/class")
  [[ $class == 0x040300 ]] || return 1
  printf '%s\n' "$slot"
}

# 某设备全部 BAR 的合计字节数（读 /sys/.../resource，运行时 0444 可读）
wb_detect_bar_total() {
  local p start end _ total=0
  p=$(wb__pci_path "$1")
  [[ -r $p/resource ]] || { printf '0\n'; return 0; }
  while read -r start end _; do
    [[ $start == 0x0000000000000000 || $end == 0x0000000000000000 ]] && continue
    total=$(( total + end - start + 1 ))
  done < "$p/resource"
  printf '%s\n' "$total"
}

wb_detect_human_size() {
  local b=${1:-0}
  if (( b >= 1073741824 )); then printf '%sG' "$(( b / 1073741824 ))"
  elif (( b >= 1048576 )); then printf '%sM' "$(( b / 1048576 ))"
  elif (( b >= 1024 )); then printf '%sK' "$(( b / 1024 ))"
  else printf '%sB' "$b"
  fi
}

wb__igpu_score() {
  local bdf=$1 score=0 total
  wb_detect_audio_sibling "$bdf" >/dev/null && score=$(( score + 2 ))
  total=$(wb_detect_bar_total "$bdf")
  (( total > 0 && total < 4294967296 )) && score=$(( score + 2 ))
  printf '%s\n' "$score"
}

# ── 核显识别 ──────────────────────────────────────────────────────────────

# wb_detect_igpu [BDF]
#   stdout: 第一行 = vga，第二行 = audio（若同槽有 HDMI 音频功能）
#           格式: <role> <bdf> <class> <vendor:device> <bar合计>
#   BDF 给出时直接验证该设备（配置覆盖路径）
#   失败: 码 4（无 AMD 显示设备 / 指定设备不存在 / 多候选同分需人工指定）
wb_detect_igpu() {
  local want=${1:-} bdf vd class score best_score best sorted top

  if [[ -n $want ]]; then
    [[ -d $(wb__pci_path "$want") ]] || wb_fail 4 detect "指定的 GPU 不存在: $want" "docs/interfaces/04-lib-api.md"
    _wb_detect_igpu_emit "$want"
    return 0
  fi

  local cands=()
  while read -r bdf vd class; do
    [[ ${vd%%:*} == 1002 ]] || continue          # 只认 AMD（本项目直通目标）
    score=$(wb__igpu_score "$bdf")
    cands+=("$score $bdf $class $vd")
  done < <(wb_detect_display_devices)

  if (( ${#cands[@]} == 0 )); then
    wb_fail 4 detect "未找到 AMD 显示设备（vendor 1002）" "docs/zh/06-最终配置清单与复现步骤.md"
  fi

  sorted=$(printf '%s\n' "${cands[@]}" | sort -rn -k1,1)
  best_score=$(printf '%s\n' "$sorted" | head -1 | awk '{print $1}')
  top=$(printf '%s\n' "$sorted" | awk -v s="$best_score" '$1 == s' | wc -l)

  if (( top > 1 )); then
    wb_log "共 ${#cands[@]} 个 AMD 显示设备，其中 $top 个评分相同（无法自动判定）："
    local line
    while IFS= read -r line; do wb_log "  $line"; done <<< "$sorted"
    wb_fail 4 detect "候选同分，请用 winbox detect --gpu <BDF> 指定" \
      "docs/interfaces/01-winbox-cli.md"
  fi

  best=$(printf '%s\n' "$sorted" | head -1 | awk '{print $2}')
  _wb_detect_igpu_emit "$best"
}

_wb_detect_igpu_emit() {
  local bdf=$1 p class vendor device aud ap
  p=$(wb__pci_path "$bdf")
  class=$(cat "$p/class"); vendor=$(cat "$p/vendor"); device=$(cat "$p/device")
  printf 'vga %s %s %s:%s %s\n' "$bdf" "$class" "${vendor#0x}" "${device#0x}" \
    "$(wb_detect_human_size "$(wb_detect_bar_total "$bdf")")"

  if aud=$(wb_detect_audio_sibling "$bdf"); then
    ap=$(wb__pci_path "$aud")
    class=$(cat "$ap/class"); vendor=$(cat "$ap/vendor"); device=$(cat "$ap/device")
    printf 'audio %s %s %s:%s %s\n' "$aud" "$class" "${vendor#0x}" "${device#0x}" \
      "$(wb_detect_human_size "$(wb_detect_bar_total "$aud")")"
  fi
  return 0
}

# ── IOMMU ─────────────────────────────────────────────────────────────────

wb_detect_iommu() {
  local groups=(/sys/kernel/iommu_groups/*)
  if [[ -d ${groups[0]:-} ]]; then printf 'enabled\n'; else printf 'disabled\n'; fi
}

wb_detect_iommu_count() {
  local groups=(/sys/kernel/iommu_groups/*)
  if [[ -d ${groups[0]:-} ]]; then printf '%s\n' "${#groups[@]}"; else printf '0\n'; fi
}

# 设备所在 IOMMU 组号；无组 → 码 4
wb_detect_iommu_group() {
  local bdf=${1:-} p link
  p=$(wb__pci_path "$bdf")
  [[ -e $p ]] || wb_fail 4 detect "设备不存在: $bdf" "docs/interfaces/04-lib-api.md"
  link=$(readlink -f "$p/iommu_group" 2>/dev/null || true)
  [[ -n $link ]] || wb_fail 4 detect "设备无 IOMMU 分组: $bdf（IOMMU 未启用，或设备不在可隔离的总线上）" \
    "docs/zh/06-最终配置清单与复现步骤.md"
  basename -- "$link"
}

# 同组的其它设备（用于判断"能否独占"）：每行一个 BDF
wb_detect_iommu_peers() {
  local want=${1:-} p link d
  [[ -n $want ]] || return 0
  p=$(wb__pci_path "$want")
  link=$(readlink -f "$p/iommu_group" 2>/dev/null || true)
  [[ -n $link ]] || return 0
  for d in "$link"/devices/*; do
    [[ -e $d ]] || continue
    d=$(basename -- "$d")
    [[ $d == "$want" ]] && continue
    printf '%s\n' "$d"
  done
  return 0
}

# ── ROM / 依赖 / 三方源码 ─────────────────────────────────────────────────

# 已部署的 ROM 候选文件名（每行一个；目录不存在则无输出）
wb_detect_vbios_roms() {
  local dir f
  dir=$(wb_conf_get_default WB_VBIOS_DIR /var/lib/libvirt/vbios)
  [[ -d $dir ]] || return 0
  for f in "$dir"/*.rom; do
    [[ -f $f ]] || continue
    basename -- "$f"
  done
  return 0
}

# third_party/ 是否已初始化：ok / missing:名称…
wb_detect_submodules() {
  local root=${WB_ROOT:-$(pwd)} missing=() d
  for d in LookingGlass ryzen-gpu-passthrough-proxmox VBIOS-Dumper; do
    if [[ ! -d $root/third_party/$d ]] || [[ -z $(ls -A "$root/third_party/$d" 2>/dev/null || true) ]]; then
      missing+=("$d")
    fi
  done
  if (( ${#missing[@]} )); then printf 'missing:%s\n' "${missing[*]}"; else printf 'ok\n'; fi
}

# libvirt/QEMU 工具可用性：ok / missing:cmd…
wb_detect_libvirt_tools() {
  local c missing=()
  for c in virsh virt-install qemu-system-x86_64; do
    wb_have_cmd "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} )); then printf 'missing:%s\n' "${missing[*]}"; else printf 'ok\n'; fi
}
