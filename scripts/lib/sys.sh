#!/usr/bin/env bash
# code-master:title win-box · 环境守卫（lib/sys.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 只做"前置条件"判断：缺什么就报什么，绝不替用户"尽力而为"。
# 前置不满足一律用退出码 3（见 docs/interfaces/00-overview.md）。

[[ -n ${WB_LIB_SYS_LOADED:-} ]] && return 0
WB_LIB_SYS_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"

wb_is_dry_run() { (( ${WB_DRY_RUN:-0} )); }
wb_is_yes()     { (( ${WB_YES:-0} )); }

# ── 查询（不打印、不退出）────────────────────────────────────────────────
wb_have_cmd() { command -v -- "$1" >/dev/null 2>&1; }

# ── 前置条件（不满足即 wb_fail 3）────────────────────────────────────────
wb_require_cmd() {
  local missing=() c
  for c in "$@"; do
    wb_have_cmd "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    wb_fail 3 sys "缺少命令: ${missing[*]}" "docs/zh/06-最终配置清单与复现步骤.md"
  fi
  return 0
}

wb_require_root() {
  if (( EUID != 0 )); then
    wb_fail 3 sys "需要 root 权限：sudo ${WB_SELF:-$(basename -- "$0")} ${WB_ARGS:-}" \
      "docs/interfaces/00-overview.md"
  fi
  return 0
}

wb_require_file() {
  local p
  for p in "$@"; do
    [[ -f $p ]] || wb_fail 3 sys "缺少文件: $p" "docs/zh/06-最终配置清单与复现步骤.md"
  done
  return 0
}

wb_require_dir() {
  local p
  for p in "$@"; do
    [[ -d $p ]] || wb_fail 3 sys "缺少目录: $p" "docs/zh/06-最终配置清单与复现步骤.md"
  done
  return 0
}

# ── 交互确认（--yes 时自动通过）──────────────────────────────────────────
wb_confirm() {
  wb_is_yes && return 0
  local ans
  printf '%s [y/N] ' "${1:-确认继续?}" >&2
  read -r ans || true
  [[ $ans == [yY] || $ans == [yY][eE][sS] ]]
}
