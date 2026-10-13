#!/usr/bin/env bash
# code-master:title win-box · 域 XML（模板渲染与重定义）（lib/xml.sh）
#
# 契约：docs/interfaces/04-lib-api.md ／ 链路：docs/calltrees/02-create-and-attach.md
#
# 本文件是"模板即真相源"的实现：
#
#   * **不就地编辑 XML**：域定义由 config/templates/domain.xml.in 渲染而成，
#     所以不需要 xmlstarlet，也不需要 python。
#   * **一次写盘路径**：所有 mutating 操作 = 改配置键 + wb_vm_redeploy（渲染→备份→define）。
#     没有第二条改 XML 的路，也就不会有"某条路径忘了同步"的漂移。
#   * **形态靠片段**：视频/固件/直通设备/共享内存/x-vga 各是一个片段文件，
#     由配置键选出"用哪个片段"，主模板保持线性可读（没有条件分支）。
#   * **可离线验证**：渲染是纯文本替换，测试里用 xmllint + libvirt 的 domain.rng 校验。
#
# 想改 VM 结构（加磁盘、改 USB、换网络）→ 改模板文件；不要用 virsh edit（下次渲染会覆盖）。

[[ -n ${WB_LIB_XML_LOADED:-} ]] && return 0
WB_LIB_XML_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"
# shellcheck source=./conf.sh
[[ -n ${WB_LIB_CONF_LOADED:-} ]] || source "$WB_LIB_DIR/conf.sh"

# 本模块引入的配置键：统一登记在 conf 的键表里，`winbox conf` 才看得到它们
WB_CONF_KEYS+=(
  WB_VM_UUID WB_VM_MAC WB_VM_MEMORY_MB WB_VM_VCPUS WB_VM_DISK WB_VM_ISO
  WB_VM_NVRAM WB_VM_NETWORK WB_MACHINE WB_VM_SECUREBOOT WB_OVMF_CODE WB_OVMF_VARS
  WB_VIDEO_MODE WB_GPU_ATTACHED WB_SHMEM_ENABLED
  WB_ROOTPORT_INDEX WB_ROOTPORT_CHASSIS WB_ROOTPORT_PORT
  WB_IGPU_GUEST_BUS WB_IGPU_GUEST_SLOT
)

declare -gA WB_XML_VARS=()

# ── 路径与默认值 ──────────────────────────────────────────────────────────

# 模板解析顺序：$WB_XML_TEMPLATE > config/domain.local.xml（用户改过的副本）> 仓库模板
wb_xml_template_path() {
  if [[ -n ${WB_XML_TEMPLATE:-} ]]; then printf '%s\n' "$WB_XML_TEMPLATE"; return 0; fi
  if [[ -f $WB_ROOT/config/domain.local.xml ]]; then
    printf '%s\n' "$WB_ROOT/config/domain.local.xml"; return 0
  fi
  printf '%s\n' "$WB_ROOT/config/templates/domain.xml.in"
}

wb_xml_fragment_path() { printf '%s\n' "$WB_ROOT/config/templates/fragment/$1.xml.in"; }

# 模板会用到、但允许不写进配置的键的默认值；未知键返回 1
wb_xml_default() {
  case ${1:-} in
    WB_VM_MEMORY_MB)     printf '16384' ;;
    WB_VM_VCPUS)         printf '8' ;;
    WB_VM_NETWORK)       printf 'default' ;;
    WB_MACHINE)          printf 'q35' ;;
    WB_VM_SECUREBOOT)    printf '0' ;;
    WB_OVMF_CODE)        printf '/usr/share/OVMF/OVMF_CODE_4M.fd' ;;
    WB_OVMF_VARS)        printf '/usr/share/OVMF/OVMF_VARS_4M.fd' ;;
    WB_VM_ISO)           printf '' ;;
    WB_VM_NVRAM)         printf '/var/lib/libvirt/qemu/nvram/%s_VARS.fd' "$(wb_conf_get_default WB_VM_NAME win11)" ;;
    WB_VIDEO_MODE)       printf 'lg' ;;
    WB_GPU_ATTACHED)     printf '0' ;;
    WB_SHMEM_ENABLED)    printf '0' ;;
    WB_SHM_SIZE_MB)      printf '128' ;;
    WB_VBIOS_DIR)        printf '/var/lib/libvirt/vbios' ;;
    WB_ROOTPORT_INDEX)   printf '15' ;;
    WB_ROOTPORT_CHASSIS) printf '15' ;;
    WB_ROOTPORT_PORT)    printf '0x0' ;;
    WB_IGPU_GUEST_BUS)   printf '0x0f' ;;
    WB_IGPU_GUEST_SLOT)  printf '0x00' ;;
    *) return 1 ;;
  esac
}

# ── 变量表 ────────────────────────────────────────────────────────────────

# 0000:0d:00.0 → WB_GPU_DOMAIN/BUS/SLOT/FUNCTION（十六进制带 0x 前缀）
# 注意：每一步必须分开赋值——同一个 local 命令里的多个赋值会先做完所有展开，
# 因此 ${rest} 在被赋值前就会展开（set -u 下直接报错）。
wb_xml__derive_bdf() {
  local pre=${2:-} bdf=${WB_XML_VARS[${1:-}]:-}
  [[ -n $bdf ]] || return 0
  [[ $bdf == *:*:* ]] || bdf="0000:$bdf"

  local dom rest bus rest2 slot fn
  dom=${bdf%%:*}
  rest=${bdf#*:}
  bus=${rest%%:*}
  rest2=${rest#*:}
  slot=${rest2%%.*}
  fn=${rest2##*.}

  WB_XML_VARS["${pre}_DOMAIN"]="0x$dom"
  WB_XML_VARS["${pre}_BUS"]="0x$bus"
  WB_XML_VARS["${pre}_SLOT"]="0x$slot"
  WB_XML_VARS["${pre}_FUNCTION"]="0x$fn"
}

# 构造渲染用的变量表：环境变量 > 配置文件 > 内置默认
wb_xml_vars_init() {
  declare -gA WB_XML_VARS=()
  local k v
  while IFS= read -r k; do
    v=$(printenv "$k" 2>/dev/null || true)
    [[ -n $v ]] || v=${WB_CONF[$k]:-}
    [[ -n $v ]] || v=$(wb_xml_default "$k" || true)
    if [[ -n $v ]]; then WB_XML_VARS[$k]=$v; else WB_XML_VARS[$k]=""; fi
  done < <(printf '%s\n' "${WB_CONF_KEYS[@]}" | sort -u)

  wb_xml__derive_bdf WB_GPU_BDF WB_GPU
  wb_xml__derive_bdf WB_AUDIO_BDF WB_AUDIO

  if [[ -n ${WB_XML_VARS[WB_SHM_SIZE_MB]:-} ]]; then
    WB_XML_VARS[WB_SHM_SIZE_BYTES]=$(( WB_XML_VARS[WB_SHM_SIZE_MB] * 1048576 ))
  fi
  # 身份键缺失是最常见的前置错误，这里立刻说清楚（而不是等渲染时报一堆占位符）
  local need=(WB_VM_NAME WB_VM_UUID WB_VM_DISK) missing=()
  for k in "${need[@]}"; do [[ -n ${WB_XML_VARS[$k]:-} ]] || missing+=("$k"); done
  if (( ${#missing[@]} )); then
    wb_fail 3 xml "VM 身份信息缺失: ${missing[*]}（先跑 winbox adopt 接管现有 VM，或 winbox vm-create 新建）" \
      "docs/interfaces/01-winbox-cli.md"
  fi
}

# ── 片段选择：形态由这里决定 ──────────────────────────────────────────────

wb_xml_prepare_fragments() {
  local mode=${WB_XML_VARS[WB_VIDEO_MODE]:-lg} sb=${WB_XML_VARS[WB_VM_SECUREBOOT]:-0}
  local fw video xvga='' igpu='' shmem='' cdrom=''

  case $sb in
    1 | yes | true)  fw=firmware-secboot ;;
    0 | no | false)  fw=firmware-nosb ;;
    *) wb_fail 2 xml "WB_VM_SECUREBOOT 取值非法: $sb（应为 0 或 1）" "docs/interfaces/04-lib-api.md" ;;
  esac

  # 注：值用引号包住——shellcheck 会把未引号的 "video-none" 当成算术表达式（SC2100）
  case $mode in
    test)    video='video-none'; xvga='xvga-on' ;;   # 核显是 Primary → 需要 VBIOS 的 POST 路径
    lg)      video='video-none' ;;                   # 非启动显示适配器 → 避开 0xC01E0438
    inspect) video='video-qxl' ;;                    # QXL 取证：SPICE 里看客机内部
    both)    video='video-qxl'; xvga='xvga-on' ;;
    *) wb_fail 2 xml "WB_VIDEO_MODE 取值非法: $mode（应为 test|inspect|both|lg）" \
         "docs/interfaces/04-lib-api.md" ;;
  esac

  [[ ${WB_XML_VARS[WB_GPU_ATTACHED]:-0} == 1 ]] && igpu=igpu
  [[ ${WB_XML_VARS[WB_SHMEM_ENABLED]:-0} == 1 ]] && shmem=shmem
  [[ -n ${WB_XML_VARS[WB_VM_ISO]:-} ]] && cdrom=cdrom

  if [[ -n $igpu ]]; then
    local need=(WB_GPU_BDF WB_GPU_DOMAIN WB_GPU_BUS WB_GPU_SLOT WB_GPU_FUNCTION
                WB_AUDIO_BDF WB_AUDIO_DOMAIN WB_AUDIO_BUS WB_AUDIO_SLOT WB_AUDIO_FUNCTION
                WB_VBIOS_DIR WB_VBIOS_GPU WB_VBIOS_AUDIO)
    local k missing=()
    for k in "${need[@]}"; do [[ -n ${WB_XML_VARS[$k]:-} ]] || missing+=("$k"); done
    if (( ${#missing[@]} )); then
      wb_fail 3 xml "直通模式缺少配置: ${missing[*]}（先 winbox detect --write / rom 子命令补上）" \
        "docs/interfaces/04-lib-api.md"
    fi
  fi

  WB_XML_VARS[WB_XML_FRAGMENT_FIRMWARE]=$(wb_xml_render_fragment "$fw")
  WB_XML_VARS[WB_XML_FRAGMENT_VIDEO]=$(wb_xml_render_fragment "$video")
  WB_XML_VARS[WB_XML_FRAGMENT_CDROM]=$(wb_xml_render_fragment "$cdrom")
  WB_XML_VARS[WB_XML_FRAGMENT_IGPU]=$(wb_xml_render_fragment "$igpu")
  WB_XML_VARS[WB_XML_FRAGMENT_SHMEM]=$(wb_xml_render_fragment "$shmem")
  WB_XML_VARS[WB_XML_FRAGMENT_XVGA]=$(wb_xml_render_fragment "$xvga")
}

# ── 渲染 ──────────────────────────────────────────────────────────────────

wb_xml_render_fragment() {
  local name=${1:-} f
  [[ -n $name ]] || return 0
  f=$(wb_xml_fragment_path "$name")
  [[ -f $f ]] || wb_fail 3 xml "片段不存在: $f" "docs/calltrees/02-create-and-attach.md"
  wb_xml__substitute < "$f"
}

# 值会进入 XML 属性，含特殊字符就会破坏结构 → 早报错、报清楚
wb_xml__check_value() {
  local name=${1:-} value=${2-}
  case $value in
    *[\&\<\>\"\']*)
      wb_fail 3 xml "配置值含 XML 特殊字符，不能渲染: $name=$value" "docs/interfaces/04-lib-api.md" ;;
  esac
  return 0
}

# 逐行替换 ${WB_*}；多行值（片段）按占位符所在列的缩进重排
# ★ 替换必须用**引号模式** ${out/"$ph"/"$val"}：引号模式禁用 glob 与 & 展开，
#   而我们的值里含 &apos; 这类实体，非引号模式会被 patsub_replacement 搞坏。
wb_xml__substitute() {
  local line out indent ph name val
  local nl=$'\n'
  local -a missing=()

  # bash 5.2+ 的 patsub_replacement 会把替换串里的 & 当作"匹配到的文本"。
  # 我们的值里合法地包含 XML 实体（如 &apos;），因此显式关掉它——
  # 否则哪天把引号模式写成非引号模式就会静默损坏 XML。
  local patsub_was=0
  if shopt -q patsub_replacement 2>/dev/null; then
    patsub_was=1
    shopt -u patsub_replacement
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    indent=${line%%[![:space:]]*}
    out=$line
    while [[ $out =~ \$\{(WB_[A-Z0-9_]+)\} ]]; do
      ph=${BASH_REMATCH[0]}
      name=${BASH_REMATCH[1]}
      if [[ -z ${WB_XML_VARS[$name]+set} ]]; then
        missing+=("$name")
        out=${out/"$ph"/}
        continue
      fi
      val=${WB_XML_VARS[$name]}
      [[ $name == WB_XML_FRAGMENT_* ]] || wb_xml__check_value "$name" "$val"
      if [[ $val == *$nl* ]]; then val=${val//$nl/$nl$indent}; fi
      out=${out/"$ph"/"$val"}
    done
    printf '%s\n' "$out"
  done

  if (( ${#missing[@]} )); then
    local uniq
    uniq=$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')
    wb_fail 3 xml "模板需要但变量表里没有: ${uniq% }" "docs/interfaces/04-lib-api.md"
  fi
  (( patsub_was )) && shopt -s patsub_replacement
  return 0
}

# wb_xml_render [TEMPLATE] [NAME=VALUE…] → stdout
#   变量表为空时自动初始化（方便"只 source 一个函数就能预览"的场景）
wb_xml_render() {
  local tmpl=${1:-}
  if [[ -n $tmpl && $tmpl == *=* ]]; then
    tmpl=''                 # 第一个参数就是覆盖项 → 保留全部参数，用默认模板
  else
    shift || true           # 第一个参数是模板路径（或为空）→ 去掉它
  fi
  [[ -n $tmpl ]] || tmpl=$(wb_xml_template_path)
  [[ -f $tmpl ]] || wb_fail 3 xml "模板不存在: $tmpl" "docs/calltrees/02-create-and-attach.md"

  if (( ${#WB_XML_VARS[@]} == 0 )); then
    wb_xml_vars_init
    wb_xml_prepare_fragments
  fi

  local kv
  for kv in "$@"; do
    [[ $kv == *=* ]] || wb_fail 2 xml "覆盖参数格式应为 NAME=VALUE: $kv" "docs/interfaces/04-lib-api.md"
    WB_XML_VARS[${kv%%=*}]=${kv#*=}
  done

  wb_xml__substitute < "$tmpl"
}

# 渲染到文件（temp+rename；受 --dry-run 控制）
wb_xml_render_file() {
  local tmpl=${1:-} out=${2:-}
  shift 2 || true
  [[ -n $out ]] || wb_fail 2 xml "wb_xml_render_file 需要输出路径" "docs/interfaces/04-lib-api.md"
  if wb_is_dry_run; then
    wb_log "  [dry-run] 渲染 ${tmpl:-<默认模板>} → $out"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$out")"
  local tmp
  tmp=$(mktemp -- "${out}.XXXXXX")
  if ! wb_xml_render "$tmpl" "$@" > "$tmp"; then
    rm -f -- "$tmp"
    wb_fail 3 xml "渲染失败: ${tmpl:-<默认模板>}" "docs/calltrees/02-create-and-attach.md"
  fi
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$out"
}

# ── 与 libvirt 交互 ───────────────────────────────────────────────────────

# wb_xml_dump [FILE] → stdout = 备份文件路径
#   任何改动之前都必须先调用它：里面存着"改坏了怎么回去"的唯一凭据
wb_xml_dump() {
  local vm out=${1:-}
  vm=$(wb_conf_get_default WB_VM_NAME win11)
  if [[ -z $out ]]; then
    mkdir -p -- "$WB_ROOT/logs"
    out="$WB_ROOT/logs/$(date +%Y%m%d-%H%M%S)-${vm}-${WB_OP:-dump}.xml"
  fi
  if ! virsh -c qemu:///system dumpxml "$vm" > "$out" 2>/dev/null; then
    rm -f -- "$out"
    wb_fail 3 xml "读不到域定义: $vm（VM 不存在，或 libvirtd 未运行）" "docs/interfaces/02-vmctl.md"
  fi
  printf '%s\n' "$out"
}

# 改配置前的前置条件：VM 必须处于 shut off
wb_xml_require_stopped() {
  local vm state
  wb_require_cmd virsh
  vm=$(wb_conf_get_default WB_VM_NAME win11)
  state=$(virsh -c qemu:///system domstate "$vm" 2>/dev/null | tr -d ' ') || state=''
  [[ -n $state ]] || wb_fail 3 xml "VM 不存在: $vm（winbox adopt 可接管现有 VM）" "docs/interfaces/01-winbox-cli.md"
  [[ $state == shutoff ]] || wb_fail 3 xml "VM $vm 正在运行（$state）——先 ACPI 关机再改配置" \
    "docs/interfaces/02-vmctl.md"
  return 0
}

wb_xml_define() {
  local f=${1:-}
  wb_require_file "$f"
  wb_run virsh -c qemu:///system define "$f" >/dev/null \
    || wb_fail 1 xml "virsh define 被拒绝（渲染结果不合法？）: $f" \
      "docs/calltrees/02-create-and-attach.md"
  return 0
}

# 回读 QEMU 参数：确认关键设置真的落到了命令行上（而不是"以为改上了"）
wb_vm_verify_xml() {
  local vm tmp argv
  vm=$(wb_conf_get_default WB_VM_NAME win11)
  tmp=$(mktemp)
  if ! virsh -c qemu:///system dumpxml "$vm" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    wb_fail 3 xml "读不到域定义: $vm" "docs/interfaces/02-vmctl.md"
  fi
  argv=$(virsh -c qemu:///system domxml-to-native qemu-argv "$tmp" 2>/dev/null || true)
  rm -f -- "$tmp"
  if [[ -z $argv ]]; then
    wb_warn "无法回读 QEMU 参数（domxml-to-native 不可用），跳过验证"
    return 0
  fi

  local mode gpu_attached shmem
  mode=$(wb_conf_get_default WB_VIDEO_MODE lg)
  gpu_attached=$(wb_conf_get_default WB_GPU_ATTACHED 0)
  shmem=$(wb_conf_get_default WB_SHMEM_ENABLED 0)

  if [[ $gpu_attached == 1 ]]; then
    local n; n=$(grep -o 'vfio-pci' <<< "$argv" | wc -l)
    if (( n >= 2 )); then wb_ok "QEMU 参数含 $n 个 vfio-pci 设备（核显两功能）"
    else wb_warn "QEMU 参数里 vfio-pci 设备只有 $n 个（期望 2）"; fi
  fi
  if [[ $mode == test || $mode == both ]]; then
    grep -q 'x-vga=on' <<< "$argv" && wb_ok 'QEMU 参数含 x-vga=on' \
      || wb_warn 'x-vga=on 不在 QEMU 参数里（模板/片段没生效？）'
  fi
  if [[ $mode == lg || $mode == test ]]; then
    grep -q '\-vga none\|vga=none' <<< "$argv" && wb_ok 'QEMU 参数含 vga=none' \
      || wb_warn '未找到 vga=none'
  fi
  if [[ $shmem == 1 ]]; then
    grep -q 'ivshmem-plain' <<< "$argv" && wb_ok 'QEMU 参数含 ivshmem-plain' \
      || wb_warn '未找到 ivshmem-plain（共享内存片段没生效？）'
    grep -q 'memory-backend-file' <<< "$argv" && wb_ok 'QEMU 参数含 memory-backend-file' \
      || wb_warn '未找到 memory-backend-file'
  fi
  return 0
}

# ── 唯一的"改 XML"入口 ───────────────────────────────────────────────────

# wb_vm_redeploy REASON
#   备份 → 渲染 → define → 回读 → 与备份 diff（让用户看见到底改了什么）
wb_vm_redeploy() {
  local reason=${1:-redeploy} vm backup tmp after
  vm=$(wb_conf_get_default WB_VM_NAME win11)

  wb_xml_require_stopped
  wb_xml_vars_init
  wb_xml_prepare_fragments

  # libvirt 快照与磁盘链有耦合：重定义可能影响 snapshot-revert
  local snaps
  snaps=$(virsh -c qemu:///system snapshot-list --name "$vm" 2>/dev/null | tr -d ' ' | sed '/^$/d' || true)
  if [[ -n $snaps ]]; then
    wb_warn "$vm 存在快照: $(tr '\n' ' ' <<< "$snaps")"
    wb_warn "重定义域定义可能影响快照回滚（磁盘链与快照元数据有耦合）；事后先验证回滚再继续"
    wb_confirm "仍然继续?" || wb_fail 5 xml "用户取消了重定义（快照存在）" "docs/interfaces/02-vmctl.md"
  fi

  WB_OP=$reason
  backup=$(wb_xml_dump)
  wb_log "  已备份当前定义: $backup"

  tmp="$WB_ROOT/logs/${reason}-render.xml"
  wb_xml_render_file "$(wb_xml_template_path)" "$tmp"
  wb_log "  渲染结果: $tmp"
  wb_xml_define "$tmp"

  after=$(mktemp)
  virsh -c qemu:///system dumpxml "$vm" > "$after" 2>/dev/null
  wb_log ""
  wb_log "=== 定义变化（左: 改前备份 / 右: 改后）==="
  if diff -u "$backup" "$after" > "$tmp.diff" 2>&1; then
    wb_ok "定义无变化"
  else
    sed -n '1,200p' "$tmp.diff" >&2
    wb_hint "完整 diff: $tmp.diff"
    wb_hint "要回退: virsh -c qemu:///system define $backup"
  fi
  rm -f -- "$after"

  wb_vm_verify_xml
  return 0
}

# ── 四种显示模式 / 直通 / 共享内存的配置开关（都是"改键 + 重定义"）─────────

wb_vm_set_video_mode() {
  local mode=${1:-}
  case $mode in test | inspect | both | lg) ;; *) wb_fail 2 xml "未知显示模式: ${mode:-<空>}（test|inspect|both|lg）" "winbox --help" ;; esac
  wb_conf_set WB_VIDEO_MODE "$mode"
  wb_vm_redeploy "video-$mode"
  case $mode in
    test) wb_hint '测试模式：核显是 Primary GPU，判据是**物理显示器**（SPICE 窗口无画面是正常的）' ;;
    lg)   wb_hint 'Looking Glass 模式：核显是非启动显示适配器，桌面在 IDD 虚拟显示器上' ;;
    inspect) wb_hint '取证模式：用 SPICE 窗口看客机内部（设备管理器/事件查看器）' ;;
    both) wb_hint '双显示：SPICE + 物理显示器同时可用（实验组合）' ;;
  esac
}

wb_vm_attach_igpu() {
  local rom=${1:-} arom=${2:-}
  wb_require_file "$rom"
  wb_conf_set WB_VBIOS_DIR "$(dirname -- "$rom")"
  wb_conf_set WB_VBIOS_GPU "$(basename -- "$rom")"
  if [[ -n $arom ]]; then
    wb_require_file "$arom"
    wb_conf_set WB_VBIOS_AUDIO "$(basename -- "$arom")"
  fi
  wb_conf_set WB_GPU_ATTACHED 1
  wb_vm_redeploy "gpu-attach"
}

wb_vm_detach_igpu() {
  wb_conf_set WB_GPU_ATTACHED 0
  wb_vm_redeploy "gpu-detach"
}

wb_vm_attach_shmem() {
  local size=${1:-}
  [[ -n $size ]] && wb_conf_set WB_SHM_SIZE_MB "$size"
  wb_conf_set WB_SHMEM_ENABLED 1
  wb_vm_redeploy "lg-shmem"
}

wb_vm_detach_shmem() {
  wb_conf_set WB_SHMEM_ENABLED 0
  wb_vm_redeploy "lg-shmem-remove"
}
