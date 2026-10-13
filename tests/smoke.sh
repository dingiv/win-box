#!/usr/bin/env bash
# code-master:title win-box · 冒烟测试（tests/smoke.sh）
#
# 目的：在没有虚拟机、没有核显、没有 root 的情况下，验证"基础设施层"是好的。
#       （Bootstrap 阶段只有 lib 与 dispatcher；后续每加一个命令就加一组断言。）
#
# 用法: bash tests/smoke.sh
set -uo pipefail

WB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check() { # check 描述 期望退出码 命令…
  local desc=$1 want=$2; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc == "$want" ]]; then ok "$desc"; else bad "$desc（期望退出码 $want，实得 $rc）"; printf '%s\n' "$out" | sed 's/^/      /'; fi
}

printf '\n== 1. 语法检查 ==\n'
for f in "$WB_ROOT"/scripts/lib/*.sh "$WB_ROOT"/scripts/bin/*; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename -- "$f")"; else bad "bash -n $(basename -- "$f")"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  printf '\n== 2. shellcheck ==\n'
  if shellcheck --exclude=SC1091 --severity=warning "$WB_ROOT"/scripts/lib/*.sh "$WB_ROOT"/scripts/bin/* >"$TMP/sc.txt" 2>&1; then
    ok 'shellcheck（无 warning 及以上）'
  else
    bad 'shellcheck 有告警'; sed 's/^/      /' "$TMP/sc.txt"
  fi
else
  printf '\n== 2. shellcheck ==\n  (未安装，跳过: sudo apt install shellcheck)\n'
fi

printf '\n== 3. 函数库可独立 source ==\n'
for lib in log sys conf detect pci gpu xml guest lg; do
  if bash -c "source '$WB_ROOT/scripts/lib/$lib.sh' && declare -F | grep -q wb_" 2>/dev/null; then
    ok "lib/$lib.sh 可单独 source"
  else
    bad "lib/$lib.sh 无法单独 source"
  fi
done

printf '\n== 4. 契约要求的函数都在 ==\n'
WB_ALL_LIBS="source $WB_ROOT/scripts/lib/log.sh; source $WB_ROOT/scripts/lib/sys.sh; source $WB_ROOT/scripts/lib/conf.sh; source $WB_ROOT/scripts/lib/detect.sh; source $WB_ROOT/scripts/lib/pci.sh; source $WB_ROOT/scripts/lib/gpu.sh; source $WB_ROOT/scripts/lib/xml.sh; source $WB_ROOT/scripts/lib/guest.sh; source $WB_ROOT/scripts/lib/lg.sh"
for fn in wb_log wb_step wb_ok wb_warn wb_fail wb_run wb_write wb_capture \
          wb_is_dry_run wb_is_yes wb_have_cmd wb_require_cmd wb_require_root \
          wb_require_file wb_require_dir wb_confirm \
          wb_conf_path wb_conf_load wb_conf_get wb_conf_get_default wb_conf_set \
          wb_conf_require wb_conf_dump \
          wb_detect_display_devices wb_detect_igpu wb_detect_audio_sibling \
          wb_detect_bar_total wb_detect_human_size wb_detect_iommu wb_detect_iommu_count \
          wb_detect_iommu_group wb_detect_iommu_peers wb_detect_vbios_roms \
          wb_detect_submodules wb_detect_libvirt_tools \
          wb_pci_exists wb_pci_driver wb_pci_override wb_pci_override_clear \
          wb_pci_unbind wb_pci_probe wb_pci_bind wb_pci_wait_driver \
          wb_gpu_reset_cycle wb_gpu_deploy_rom wb_gpu_rom_fingerprint wb_gpu_bind_vfio \
          wb_xml_render wb_xml_render_file wb_xml_render_fragment wb_xml_template_path \
          wb_xml_vars_init wb_xml_prepare_fragments wb_xml_dump wb_xml_define \
          wb_xml_require_stopped wb_vm_redeploy wb_vm_verify_xml wb_vm_set_video_mode \
          wb_vm_attach_igpu wb_vm_detach_igpu wb_vm_attach_shmem wb_vm_detach_shmem \
          wb_guest_configured wb_guest_ready wb_guest_ps wb_guest_put \
          wb_guest_gpu_status wb_guest_idd_status \
          wb_kvmfr_state wb_kvmfr_check wb_kvmfr_size_mb wb_kvmfr_install \
          wb_lg_src_dir wb_lg_client_bin wb_lg_deps_install wb_lg_build_check wb_lg_build \
          wb_lg_client_ini_write wb_lg_run wb_lg_permissions_fix wb_lg_permissions_state \
          wb_idd_prefs_apply; do
  if bash -c "$WB_ALL_LIBS; declare -F $fn >/dev/null" 2>/dev/null; then
    ok "函数存在: $fn"
  else
    bad "函数缺失: $fn"
  fi
done

printf '\n== 5. 退出码语义 ==\n'
check 'wb_fail 3 → 退出码 3' 3 bash -c "source '$WB_ROOT/scripts/lib/log.sh'; wb_fail 3 stage msg"
check 'wb_fail 5 → 退出码 5' 5 bash -c "source '$WB_ROOT/scripts/lib/log.sh'; wb_fail 5 stage msg"
check 'wb_conf_get 未定义键 → 码 3' 3 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$TMP/none.conf
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load; wb_conf_get WB_NOT_A_KEY"

printf '\n== 6. 配置读写（隔离在临时文件）==\n'
export WB_CONF_PATH="$TMP/conf"
printf '# 注释保留测试\nWB_VM_NAME=alpha\nWB_SHM_SIZE_MB=32\n' > "$WB_CONF_PATH"

check '读取已有键' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$WB_CONF_PATH
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
  [[ \$(wb_conf_get WB_VM_NAME) == alpha ]]"

check '默认值回落' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$WB_CONF_PATH
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
  [[ \$(wb_conf_get_default WB_NOT_SET fallback) == fallback ]]"

check '写入新键' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$WB_CONF_PATH
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
  wb_conf_set WB_GUEST_USER tester
  [[ \$(wb_conf_get WB_GUEST_USER) == tester ]]"

check '改键后注释与其它键保留' 0 bash -c "
  grep -q '^# 注释保留测试' '$WB_CONF_PATH' && grep -q '^WB_SHM_SIZE_MB=32' '$WB_CONF_PATH'"

check 'env 覆盖文件' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$WB_CONF_PATH WB_VM_NAME=from-env
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
  [[ \$(wb_conf_get WB_VM_NAME) == from-env ]]"

check '含空白的值被拒绝（码 3）' 3 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$WB_CONF_PATH
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
  wb_conf_set WB_VM_NAME 'a b'"

check '语法错误的配置 → 码 3' 3 bash -c "
  printf 'this is not a config\n' > '$TMP/bad.conf'
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$TMP/bad.conf
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load"

printf '\n== 7. --dry-run 不落盘 ==\n'
check 'dry-run 下 wb_conf_set 不写文件' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$WB_CONF_PATH WB_DRY_RUN=1
  source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
  wb_conf_set WB_REBOOT_WAIT 99
  ! grep -q '^WB_REBOOT_WAIT=99' '$WB_CONF_PATH'"

check 'dry-run 下 wb_run 不执行' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_DRY_RUN=1
  source '$WB_ROOT/scripts/lib/log.sh'
  wb_run touch '$TMP/should-not-exist'
  [[ ! -e '$TMP/should-not-exist' ]]"

printf '\n== 8. dispatcher ==\n'
check 'winbox --help' 0 "$WB_ROOT/scripts/bin/winbox" --help
check 'winbox --version' 0 "$WB_ROOT/scripts/bin/winbox" --version
check '未知选项 → 码 2' 2 "$WB_ROOT/scripts/bin/winbox" --nope
check '未知命令 → 码 2' 2 "$WB_ROOT/scripts/bin/winbox" frobnicate
check '未实现命令 → 码 1' 1 "$WB_ROOT/scripts/bin/winbox" host-prep
check 'winbox conf key=value 往返' 0 bash -c "
  '$WB_ROOT/scripts/bin/winbox' -c '$WB_CONF_PATH' conf WB_VM_NAME=beta
  [[ \$('$WB_ROOT/scripts/bin/winbox' -c '$WB_CONF_PATH' conf WB_VM_NAME) == beta ]]"

printf '\n== 9. 仓库卫生 ==\n'
check '没有 .bin/.rom/.iso 被 git 跟踪' 0 bash -c "
  cd '$WB_ROOT' && ! git ls-files | grep -Eq '\.(bin|rom|iso|exe|msi|zip)$'"
check '没有 python 文件' 0 bash -c "
  cd '$WB_ROOT' && ! find . -name '*.py' -not -path './third_party/*' | grep -q ."
check 'scripts/bin/* 都有可执行位' 0 bash -c "
  cd '$WB_ROOT' && for f in scripts/bin/*; do [[ -x \$f ]] || exit 1; done"
check '本机配置（win-box.conf）未被 git 跟踪' 0 bash -c "
  cd '$WB_ROOT' && ! git ls-files | grep -qx 'config/win-box.conf'"

printf '\n== 10. 探测（只读，不碰硬件）==\n'
check 'wb_detect_iommu 输出 enabled/disabled' 0 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/detect.sh'
  [[ \$(wb_detect_iommu) =~ ^(enabled|disabled)\$ ]]"
check 'wb_detect_display_devices 每行 3 字段且 class 为显示类' 0 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/detect.sh'
  out=\$(wb_detect_display_devices)
  while read -r a b c; do
    [[ -n \$a && \$b =~ ^[0-9a-f]{4}: && \$c =~ ^0x03 ]] || exit 1
  done <<< \"\$out\""
check 'wb_detect_submodules 输出 ok|missing:…' 0 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/detect.sh'
  [[ \$(wb_detect_submodules) =~ ^(ok|missing:) ]]"
check 'wb_detect_iommu_group 对不存在设备 → 码 4' 4 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/detect.sh'
  wb_detect_iommu_group 0000:ff:ff.7"

out=$("$WB_ROOT/scripts/bin/winbox" detect 2>&1); rc=$?
if [[ $rc == 0 ]]; then
  ok 'winbox detect 在本机跑通（码 0）'
  [[ $out == *'== 选中核显 =='* ]] && ok '报告含「选中核显」段' || bad '报告缺少「选中核显」段'
elif [[ $rc == 4 ]]; then
  ok '本机无 AMD 核显（码 4，语义正确）'
else
  bad "winbox detect 异常退出（码 $rc）"; printf '%s\n' "$out" | sed 's/^/      /'
fi

printf '\n== 11. detect --write 落盘（隔离配置）==\n'
rc=0
"$WB_ROOT/scripts/bin/winbox" -c "$TMP/detect.conf" detect --write >/dev/null 2>&1 || rc=$?
if [[ $rc == 0 ]]; then
  check '写入 WB_GPU_BDF' 0 grep -q '^WB_GPU_BDF=0000:' "$TMP/detect.conf"
  check '写入 WB_GPU_ID' 0 grep -q '^WB_GPU_ID=[0-9a-f]*:' "$TMP/detect.conf"
  check '写入后能读回' 0 bash -c "
    export WB_ROOT=$WB_ROOT WB_CONF_PATH=$TMP/detect.conf
    source '$WB_ROOT/scripts/lib/conf.sh'; wb_conf_load
    [[ \$(wb_conf_get WB_GPU_BDF) == \$(grep '^WB_GPU_BDF=' $TMP/detect.conf | cut -d= -f2) ]]"
elif [[ $rc == 4 ]]; then
  ok '本机无 AMD 核显，跳过写入断言'
else
  bad "detect --write 异常退出（码 $rc）"
fi

printf '\n== 12. wb_write 与 pci 库 ==\n'
check 'wb_write 干跑不落盘' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_DRY_RUN=1
  source '$WB_ROOT/scripts/lib/log.sh'
  wb_write '$TMP/nowrite' hello
  [[ ! -e '$TMP/nowrite' ]]"
check 'wb_write 正常写入' 0 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/log.sh'
  wb_write '$TMP/yeswrite' hello && [[ \$(cat '$TMP/yeswrite') == hello ]]"
check 'wb_pci_driver 对不存在的设备返回 (none)' 0 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/pci.sh'
  [[ \$(wb_pci_driver 0000:ff:ff.7) == '(none)' ]]"
check 'wb_pci_exists 对不存在的设备返回 1' 1 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/pci.sh'
  wb_pci_exists 0000:ff:ff.7"
if (( EUID != 0 )); then
  check '非 root 写 sysfs → 码 3（前置不满足）' 3 bash -c "
    export WB_ROOT=$WB_ROOT
    source '$WB_ROOT/scripts/lib/pci.sh'
    wb_pci_override 0000:00:00.0 vfio-pci"
else
  ok '以 root 运行，跳过「非 root → 码 3」断言（避免真写 sysfs）'
fi

printf '\n== 13. gpu 库（不触碰硬件）==\n'
check 'wb_gpu_rom_fingerprint 对不存在文件 → 码 3' 3 bash -c "
  export WB_ROOT=$WB_ROOT
  source '$WB_ROOT/scripts/lib/gpu.sh'
  wb_gpu_rom_fingerprint '$TMP/nope.rom'"
check '未配置核显时 wb_gpu_reset_cycle 安全返回 0' 0 bash -c "
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$TMP/absent.conf WB_RESET_LOG=$TMP/reset.log
  source '$WB_ROOT/scripts/lib/gpu.sh'
  wb_gpu_reset_cycle"
check 'set -e 下 wb_gpu_reset_cycle 也不中断' 0 bash -c "
  set -euo pipefail
  export WB_ROOT=$WB_ROOT WB_CONF_PATH=$TMP/absent.conf WB_RESET_LOG=$TMP/reset.log
  source '$WB_ROOT/scripts/lib/gpu.sh'
  wb_gpu_reset_cycle 1
  echo reached"

printf '\n== 14. 模板渲染（完全离线，用 libvirt 自己的 schema 校验）==\n'
RENDER_CONF=$TMP/render.conf
cat > "$RENDER_CONF" <<'CONF'
WB_VM_NAME=testbox
WB_VM_UUID=11111111-2222-3333-4444-555555555555
WB_VM_MEMORY_MB=4096
WB_VM_VCPUS=4
WB_VM_DISK=/tmp/testbox.qcow2
WB_VM_MAC=52:54:00:aa:bb:cc
WB_VM_SECUREBOOT=0
WB_OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
WB_OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
WB_VIDEO_MODE=lg
WB_GPU_ATTACHED=1
WB_GPU_BDF=0000:0d:00.0
WB_AUDIO_BDF=0000:0d:00.1
WB_VBIOS_DIR=/tmp/vbios
WB_VBIOS_GPU=vbios.rom
WB_VBIOS_AUDIO=audio.rom
WB_SHMEM_ENABLED=1
WB_SHM_SIZE_MB=64
CONF

render() { WB_CONF_PATH="$RENDER_CONF" "$WB_ROOT/scripts/bin/winbox" vm render; }
R=$TMP/render.xml
render > "$R" 2>"$TMP/render.err" && ok 'winbox vm render 成功' || { bad 'winbox vm render 失败'; sed 's/^/      /' "$TMP/render.err"; }

check '渲染结果良构（xmllint --noout）' 0 xmllint --noout "$R"
if [[ -f /usr/share/libvirt/schemas/domain.rng ]]; then
  check '渲染结果符合 libvirt domain.rng（RELAX NG）' 0 \
    xmllint --noout --relaxng /usr/share/libvirt/schemas/domain.rng "$R"
else
  ok '本机无 libvirt schema，跳过 RNG 校验'
fi

check 'lg 模式：video=none 且无 x-vga 属性' 0 bash -c "
  grep -q \"<model type='none'/>\" '$R' && ! grep -q \"name='x-vga'\" '$R'"
check '直通片段：两个 hostdev + ROM' 0 bash -c "
  [[ \$(grep -c '<hostdev ' '$R') == 2 ]] && grep -q 'vbios.rom' '$R' && grep -q 'audio.rom' '$R'"
check '共享内存片段：size 按 MiB 换算（64 → 67108864）' 0 bash -c "
  grep -q 'ivshmem-plain' '$R' && grep -q 'size&apos;:67108864' '$R'"

check 'test 模式：出现 x-vga=on' 0 bash -c "
  WB_VIDEO_MODE=test WB_CONF_PATH='$RENDER_CONF' '$WB_ROOT/scripts/bin/winbox' vm render | grep -q \"name='x-vga' type='bool' value='true'\""
check 'inspect 模式：QXL + 无 x-vga' 0 bash -c "
  out=\$(WB_VIDEO_MODE=inspect WB_CONF_PATH='$RENDER_CONF' '$WB_ROOT/scripts/bin/winbox' vm render)
  grep -q \"type='qxl'\" <<< \"\$out\" && ! grep -q \"name='x-vga'\" <<< \"\$out\""
check '不挂共享内存时无 ivshmem' 0 bash -c "
  ! WB_SHMEM_ENABLED=0 WB_CONF_PATH='$RENDER_CONF' '$WB_ROOT/scripts/bin/winbox' vm render | grep -q ivshmem"
check '不挂核显时无 hostdev' 0 bash -c "
  ! WB_GPU_ATTACHED=0 WB_CONF_PATH='$RENDER_CONF' '$WB_ROOT/scripts/bin/winbox' vm render | grep -q '<hostdev ' "
check '缺 UUID 时报码 3（而不是渲染出畸形 XML）' 3 bash -c "
  grep -v '^WB_VM_UUID=' '$RENDER_CONF' > '$TMP/nouuid.conf'
  WB_CONF_PATH='$TMP/nouuid.conf' '$WB_ROOT/scripts/bin/winbox' vm render"
check '值含 XML 特殊字符时报码 3' 3 bash -c "
  cp '$RENDER_CONF' '$TMP/bad.conf'
  printf '%s\n' 'WB_VM_DISK=/tmp/a&b.qcow2' >> '$TMP/bad.conf'
  WB_CONF_PATH='$TMP/bad.conf' '$WB_ROOT/scripts/bin/winbox' vm render"

printf '\n== 15. adopt：从样本 XML 提取身份（用假 virsh，离线）==\n'
mkdir -p "$TMP/bin"
cat > "$TMP/bin/virsh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *dominfo*) exit 0 ;;
  *dumpxml*) cat "$WB_ROOT/docs/samples/win11-reference.xml" ;;
  *domstate*) printf 'shut off\n' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/virsh"
OLD_PATH=$PATH
export PATH="$TMP/bin:$PATH"
export WB_CONF_PATH="$TMP/adopt.conf"

check 'adopt 能跑通（假 virsh + 样本 XML）' 0 "$WB_ROOT/scripts/bin/winbox" adopt samplevm
for kv in \
  'WB_VM_UUID=00000000-1111-2222-3333-444444444444' \
  'WB_VM_MEMORY_MB=16384' \
  'WB_VM_VCPUS=8' \
  'WB_VM_DISK=/var/lib/libvirt/images/win11.gpu-working' \
  'WB_GPU_BDF=0000:0d:00.0' \
  'WB_AUDIO_BDF=0000:0d:00.1' \
  'WB_VIDEO_MODE=test' \
  'WB_GPU_ATTACHED=1' \
  'WB_SHMEM_ENABLED=1' \
  'WB_SHM_SIZE_MB=128' \
  'WB_ROOTPORT_INDEX=15' \
  'WB_IGPU_GUEST_BUS=0x0f' \
  'WB_VBIOS_GPU=vbios_ref_9800x3d.bin' ; do
  check "adopt 提取 ${kv%%=*}" 0 grep -qx -- "$kv" "$TMP/adopt.conf"
done

printf '\n== 16. gpu-attach 与 reset-hook（假 virsh，离线）==\n'
# 本机真实核显 BDF（没核显就跳过——测试不能假设硬件存在）
GBDF=$(bash -c "export WB_ROOT='$WB_ROOT'; source '$WB_ROOT/scripts/lib/detect.sh'; wb_detect_igpu" 2>/dev/null | awk '/^vga /{print $2}')
ABDF=$(bash -c "export WB_ROOT='$WB_ROOT'; source '$WB_ROOT/scripts/lib/detect.sh'; wb_detect_igpu" 2>/dev/null | awk '/^audio /{print $2}')

if [[ -n $GBDF ]]; then
  VBD=$TMP/vbios
  mkdir -p "$VBD"
  : > "$VBD/vbios.rom"; : > "$VBD/audio.rom"
  sed -e '/^WB_VBIOS_DIR=/d' -e '/^WB_GPU_BDF=/d' -e '/^WB_AUDIO_BDF=/d' "$RENDER_CONF" > "$TMP/attach.conf"
  {
    printf 'WB_VBIOS_DIR=%s\n' "$VBD"
    printf 'WB_VBIOS_GPU=vbios.rom\n'
    printf 'WB_VBIOS_AUDIO=audio.rom\n'
    printf 'WB_GPU_BDF=%s\n' "$GBDF"
    [[ -n $ABDF ]] && printf 'WB_AUDIO_BDF=%s\n' "$ABDF"
  } >> "$TMP/attach.conf"

  check 'gpu-attach --mode lg 全流程（假 virsh 下渲染+define）' 0 \
    env WB_CONF_PATH="$TMP/attach.conf" "$WB_ROOT/scripts/bin/winbox" gpu-attach \
      --rom "$VBD/vbios.rom" --audio-rom "$VBD/audio.rom" --mode lg
  check 'attach 后配置记录了 lg 模式' 0 grep -qx 'WB_VIDEO_MODE=lg' "$TMP/attach.conf"
  check 'attach 后配置标记为已挂载' 0 grep -qx 'WB_GPU_ATTACHED=1' "$TMP/attach.conf"
else
  ok '本机无 AMD 核显，跳过 gpu-attach 断言'
fi

HOOKS=$TMP/hooks
check 'reset-hook install（WB_HOOK_ROOT 覆盖，不需 root）' 0 \
  env WB_HOOK_ROOT="$HOOKS" WB_CONF_PATH="$TMP/attach.conf" "$WB_ROOT/scripts/bin/winbox" reset-hook install
HOOKFILE=$(find "$HOOKS" -name '10-winbox-reset.sh' -print -quit 2>/dev/null || true)
check '钩子文件已生成' 0 bash -c "[[ -n '$HOOKFILE' && -x '$HOOKFILE' ]]"
check '钩子内容调 wb_gpu_reset_cycle 且总 exit 0' 0 bash -c "
  grep -q wb_gpu_reset_cycle '$HOOKFILE' && grep -qx 'exit 0' '$HOOKFILE'"
check '钩子里的配置路径是绝对路径（libvirt 环境没有 cwd）' 0 bash -c "
  grep -q \"^WB_CONF_PATH='/\" '$HOOKFILE'"
check 'reset-hook remove' 0 \
  env WB_HOOK_ROOT="$HOOKS" WB_CONF_PATH="$TMP/attach.conf" "$WB_ROOT/scripts/bin/winbox" reset-hook remove
check '卸载后钩子文件消失' 0 bash -c "[[ ! -e '$HOOKFILE' ]]"

export PATH=$OLD_PATH
unset WB_CONF_PATH

printf '\n== 17. Looking Glass 链（离线部分）==\n'
has()   { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1（未找到: $3）"; fi; }
lacks() { if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1（不应出现: $3）"; fi; }

# 17.1 qemu.conf 的 cgroup_device_acl 重写（原来这段是用 python 改配置的）
lg_lib="export WB_ROOT='$WB_ROOT'; source '$WB_ROOT/scripts/lib/lg.sh'; "
acl_render() { bash -c "${lg_lib}wb_lg__qemu_conf_acl_render '$1'"; }

printf '%s\n' '# 没有任何 ACL 块' 'some_other = 1' > "$TMP/qemu-noacl.conf"
printf '%s\n' 'cgroup_device_acl = [' '    "/dev/null", "/dev/kvm",' '    "/dev/mydev"' '    ]' \
  'log_level = 3' > "$TMP/qemu-hasacl.conf"
printf '%s\n' '#cgroup_device_acl = [' '#    "/dev/null", "/dev/kvm"' '#    ]' > "$TMP/qemu-commented.conf"

acl_out=$(acl_render "$TMP/qemu-noacl.conf")
has '无 ACL 块 → 生成白名单块' "$acl_out" 'cgroup_device_acl = ['
has '无 ACL 块 → 含 /dev/kvmfr0' "$acl_out" '"/dev/kvmfr0"'
has '无 ACL 块 → 保留原有配置行' "$acl_out" 'some_other = 1'
has '无 ACL 块 → 含 libvirt 默认设备' "$acl_out" '"/dev/kvm"'

acl_out=$(acl_render "$TMP/qemu-hasacl.conf")
has '已有 ACL 块 → 保留用户自定义设备' "$acl_out" '"/dev/mydev"'
has '已有 ACL 块 → 加入 kvmfr0' "$acl_out" '"/dev/kvmfr0"'
has '已有 ACL 块 → 保留原有项' "$acl_out" '"/dev/kvm"'
has '已有 ACL 块 → 后续配置行保留' "$acl_out" 'log_level = 3'
lacks '已有 ACL 块 → kvmfr0 不重复' "$(grep -c '/dev/kvmfr0' <<< "$acl_out")" '2'

acl_out=$(acl_render "$TMP/qemu-commented.conf")
has '注释掉的 ACL 块 → 被启用' "$acl_out" 'cgroup_device_acl = ['
has '注释掉的 ACL 块 → 含 kvmfr0' "$acl_out" '"/dev/kvmfr0"'
lacks '注释掉的 ACL 块 → 不残留注释版本' "$acl_out" '#cgroup_device_acl'

# 17.2 客户端 client.ini（首次生成、不覆盖、--force 覆盖）
HOMEFAKE="$TMP/home"
mkdir -p "$HOMEFAKE"
check '首次生成 client.ini' 0 bash -c "
  export HOME='$HOMEFAKE' WB_ROOT='$WB_ROOT'
  source '$WB_ROOT/scripts/lib/lg.sh'
  wb_lg_client_ini_write"
INI="$HOMEFAKE/.config/looking-glass/client.ini"
ini_content=$(cat "$INI" 2>/dev/null)
has 'client.ini 指定了 shmDevice'  "$ini_content" 'shmDevice=/dev/kvmfr0'
has 'client.ini 开启 DMA 直导'     "$ini_content" 'allowDMA=yes'
has 'client.ini 关掉 autoResize（与 setGuestRes 互斥）' "$ini_content" 'autoResize=no'
has 'client.ini 用抓取模式（多显示器必需）' "$ini_content" 'captureOnFocus=yes'
printf '%s\n' '; 用户手改' >> "$INI"
check '已存在时不覆盖（保留手改）' 0 bash -c "
  export HOME='$HOMEFAKE' WB_ROOT='$WB_ROOT'
  source '$WB_ROOT/scripts/lib/lg.sh'
  wb_lg_client_ini_write
  grep -q '用户手改' '$INI'"
check '--force 才重置' 0 bash -c "
  export HOME='$HOMEFAKE' WB_ROOT='$WB_ROOT'
  source '$WB_ROOT/scripts/lib/lg.sh'
  wb_lg_client_ini_write --force
  ! grep -q '用户手改' '$INI'"

# 17.3 KVMFR / 权限状态查询（在本机跑，不假设结果是哪一种）
check 'wb_kvmfr_state 只输出三者之一' 0 bash -c "
  export WB_ROOT='$WB_ROOT'
  source '$WB_ROOT/scripts/lib/lg.sh'
  [[ \$(wb_kvmfr_state) =~ ^(ok|missing|notchardev)\$ ]]"
check 'wb_lg_permissions_state 输出两个字段' 0 bash -c "
  export WB_ROOT='$WB_ROOT'
  source '$WB_ROOT/scripts/lib/lg.sh'
  s=\$(wb_lg_permissions_state)
  [[ \$s == apparmor=* ]] && [[ \$s =~ cgroup=(ok|missing|unknown)\$ ]]"

# 17.4 客机通道未配置时不得当成故障
check '未配置通道时 wb_guest_configured 返回 1' 1 bash -c "
  export WB_ROOT='$WB_ROOT' WB_CONF_PATH='$TMP/empty-guest.conf'
  source '$WB_ROOT/scripts/lib/guest.sh'; wb_conf_load
  wb_guest_configured"
check '未配置通道时 wb_guest_ready 返回 1 且不报错' 1 bash -c "
  export WB_ROOT='$WB_ROOT' WB_CONF_PATH='$TMP/empty-guest.conf'
  source '$WB_ROOT/scripts/lib/guest.sh'; wb_conf_load
  wb_guest_ready"
check '客户端未构建时 winbox lg 报码 3' 3 bash -c "
  export WB_ROOT='$WB_ROOT' WB_CONF_PATH='$TMP/render.conf' WB_LG_CLIENT='$TMP/no-such-client'
  '$WB_ROOT/scripts/bin/winbox' lg"

printf '\n== 18. status 与 evidence（离线部分）==\n'
rep_lib="export WB_ROOT='$WB_ROOT' WB_REPORT_QUIET=1; source '$WB_ROOT/scripts/lib/report.sh'; "
check '报告全 ok → 返回 0' 0 bash -c "${rep_lib}wb_report_reset; wb_report_item ok '一切正常'; wb_report_result"
check '报告有 warn → 返回 6' 6 bash -c "${rep_lib}wb_report_reset; wb_report_item ok a; wb_report_item warn b; wb_report_result"
check '报告有 bad → 返回 7' 7 bash -c "${rep_lib}wb_report_reset; wb_report_item warn a; wb_report_item bad b; wb_report_result"
check '报告计数正确' 0 bash -c "
  ${rep_lib}wb_report_reset
  wb_report_item ok a; wb_report_item warn b; wb_report_item bad c; wb_report_item info d
  [[ \$(wb_report_counts) == 'ok=1 warn=1 bad=1 info=1' ]]"
cat > "$TMP/json-check.sh" <<'EOS'
export WB_ROOT="@WBR@"
export WB_REPORT_JSON=1
source "$WB_ROOT/scripts/lib/report.sh"
wb_report_reset
wb_report_item bad 'a"b' 'c"d'
wb_report_item ok '第二项'
wb_report_result > "$1" || true
EOS
sed -i "s|@WBR@|$WB_ROOT|" "$TMP/json-check.sh"
bash "$TMP/json-check.sh" "$TMP/report.json"
json_out=$(cat "$TMP/report.json")
has 'JSON 里双引号被转义' "$json_out" 'a\"b'
has 'JSON 里含 result 字段' "$json_out" '"result": "BROKEN"'
lacks 'JSON 数组不以逗号开头（曾经的 bug）' "$json_out" '[,'
lacks 'JSON 数组不以逗号结尾' "$json_out" ',]'
lacks 'JSON 对象不以逗号开头' "$json_out" '{,'
if command -v jq >/dev/null 2>&1; then
  check 'JSON 能被 jq 解析' 0 jq -e . "$TMP/report.json"
else
  ok '（未安装 jq，跳过严格 JSON 解析）'
fi

mkdir -p "$TMP/manifest-test"
printf 'a\n' > "$TMP/manifest-test/f1.txt"
printf 'b\n' > "$TMP/manifest-test/f2.txt"
check '取证清单生成' 0 bash -c "
  ${rep_lib}wb_evidence_manifest '$TMP/manifest-test'"
check '清单含两个文件与 sha256' 0 bash -c "
  grep -q 'f1.txt' '$TMP/manifest-test/manifest.txt' &&
  grep -q 'f2.txt' '$TMP/manifest-test/manifest.txt' &&
  grep -qE '  [0-9a-f]{16} f1.txt' '$TMP/manifest-test/manifest.txt'"
check '清单不把自身列进去' 0 bash -c "
  ! grep -q '  manifest.txt' '$TMP/manifest-test/manifest.txt'"

# status：本机真实环境（只读）；退出码只可能是 0/6/7
out=$("$WB_ROOT/scripts/bin/winbox" status --host 2>&1); rc=$?
if [[ $rc == 0 || $rc == 6 || $rc == 7 ]]; then
  ok "winbox status --host 正常退出（码 $rc）"
  has 'status 含分段标题' "$out" '== 宿主：硬件与隔离'
  has 'status 用退出码承载结论' "$out" 'RESULT:'
else
  bad "winbox status --host 异常退出（码 $rc）"; printf '%s\n' "$out" | sed 's/^/      /'
fi
check 'status --json 输出结构正确' 0 bash -c "
  out=\$('$WB_ROOT/scripts/bin/winbox' status --host --json 2>/dev/null || true)
  [[ \$out == \{* ]] && [[ \$out == *\} ]] && grep -q '\"result\": ' <<< \"\$out\" && grep -q '\"sections\":' <<< \"\$out\""
check '未配置 BDF 时报 warn 而非报错' 0 bash -c "
  printf '%s\n' 'WB_VM_NAME=t1' 'WB_VM_UUID=11111111-2222-3333-4444-555555555555' \
    'WB_VM_DISK=/tmp/x.qcow2' > '$TMP/status-min.conf'
  out=\$(WB_CONF_PATH='$TMP/status-min.conf' '$WB_ROOT/scripts/bin/winbox' status --host 2>&1); rc=\$?
  [[ \$rc == 6 || \$rc == 7 ]] && grep -q '未配置核显 BDF' <<< \"\$out\""

EV="$TMP/ev"
check 'evidence 采集（非 root 也应当成功）' 0 "$WB_ROOT/scripts/bin/winbox" evidence --out "$EV"
check 'evidence 产出清单' 0 bash -c "[[ -f '$EV/manifest.txt' ]] && grep -q 'SHA256' '$EV/manifest.txt'"
check 'evidence 产出关键文件' 0 bash -c "
  for f in 04-driver-binding.txt 05-iommu.txt 10-kvmfr.txt 11-reset-hook.txt 13-versions.txt 14-guest.txt; do
    [[ -f '$EV/'\$f ]] || { echo \"缺 \$f\"; exit 1; }
  done"
check 'evidence 不含私钥内容' 0 bash -c "
  ! grep -rq 'PRIVATE KEY' '$EV' 2>/dev/null"

printf '\n───────────────────────────\n'
printf '通过: %d   失败: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
