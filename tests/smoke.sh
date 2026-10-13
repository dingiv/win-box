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
for lib in log sys conf; do
  if bash -c "source '$WB_ROOT/scripts/lib/$lib.sh' && declare -F | grep -q wb_" 2>/dev/null; then
    ok "lib/$lib.sh 可单独 source"
  else
    bad "lib/$lib.sh 无法单独 source"
  fi
done

printf '\n== 4. 契约要求的函数都在 ==\n'
for fn in wb_log wb_step wb_ok wb_warn wb_fail wb_run wb_capture \
          wb_is_dry_run wb_is_yes wb_have_cmd wb_require_cmd wb_require_root \
          wb_require_file wb_require_dir wb_confirm \
          wb_conf_path wb_conf_load wb_conf_get wb_conf_get_default wb_conf_set \
          wb_conf_require wb_conf_dump; do
  if bash -c "source '$WB_ROOT/scripts/lib/conf.sh' && declare -F $fn >/dev/null" 2>/dev/null; then
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
check '未实现命令 → 码 1' 1 "$WB_ROOT/scripts/bin/winbox" status
check 'winbox conf key=value 往返' 0 bash -c "
  '$WB_ROOT/scripts/bin/winbox' -c '$WB_CONF_PATH' conf WB_VM_NAME=beta
  [[ \$('$WB_ROOT/scripts/bin/winbox' -c '$WB_CONF_PATH' conf WB_VM_NAME) == beta ]]"

printf '\n== 9. 仓库卫生 ==\n'
check '没有 .bin/.rom/.iso 被 git 跟踪' 0 bash -c "
  cd '$WB_ROOT' && ! git ls-files | grep -Eq '\.(bin|rom|iso|exe|msi|zip)$'"
check '没有 python 文件' 0 bash -c "
  cd '$WB_ROOT' && ! find . -name '*.py' -not -path './third_party/*' | grep -q ."

printf '\n────────────────────────────\n'
printf '通过: %d   失败: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
