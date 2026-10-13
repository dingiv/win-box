#!/usr/bin/env bash
# code-master:title win-box · 日志与统一失败出口（lib/log.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 本文件是 L3 的最底层：只负责"输出"与"退出"，不依赖任何其它库，可单独 source。
#
# 硬约束：wb_fail 是整个项目里唯一允许调用 exit 的函数。
#         所有失败信息都必须经它出口，这样格式才统一：
#             ✗ <stage>: <原因> → <文档锚点>
#         直接 echo + exit 1 在本项目里视为缺陷。
#
# 输出的约定（被 docs/interfaces/01-winbox-cli.md 的 --json 依赖）：
#   * 人类可读信息 → stderr（因此 stdout 永远只有"结果"，可安全用于 $( ) 捕获）
#   * 颜色在非 TTY 或 --no-color 时自动关闭

[[ -n ${WB_LIB_LOG_LOADED:-} ]] && return 0
WB_LIB_LOG_LOADED=1

# ── 运行模式（由 dispatcher 设置；单独 source 时给出安全默认值）──────────────
WB_DRY_RUN=${WB_DRY_RUN:-0}
WB_VERBOSE=${WB_VERBOSE:-0}
WB_QUIET=${WB_QUIET:-0}
WB_YES=${WB_YES:-0}
WB_NO_COLOR=${WB_NO_COLOR:-0}
[[ -t 2 ]] || WB_NO_COLOR=1

wb__paint() {
  if (( WB_NO_COLOR )); then printf '%s' "$2"; else printf '\033[%sm%s\033[0m' "$1" "$2"; fi
}

# ── 输出 ──────────────────────────────────────────────────────────────────
wb_log()  { (( WB_QUIET )) && return 0; printf '%s\n' "$*" >&2; }
wb_hint() { (( WB_QUIET )) && return 0; printf '    %s\n' "$*" >&2; }
wb_ok()   { (( WB_QUIET )) && return 0; printf '  %s %s\n' "$(wb__paint 32 '✓')" "$*" >&2; }

# 警告不受 --quiet 抑制：它在语义上属于"必须让用户看到的信息"
wb_warn() { printf '  %s %s\n' "$(wb__paint 33 '⚠')" "$*" >&2; }

wb_step() {
  (( WB_QUIET )) && return 0
  printf '\n%s %s\n' "$(wb__paint 1 "== ${1:-}")" "${2:-}" >&2
}

# ── 唯一失败出口 ──────────────────────────────────────────────────────────
# wb_fail CODE STAGE MESSAGE [DOC]
#   CODE 见 docs/interfaces/00-overview.md 的退出码表
#   DOC  文档锚点（可省略；省略时输出的箭头段消失）
wb_fail() {
  local code=${1:-1} stage=${2:-?} msg=${3:-失败} doc=${4:-}
  printf '%s %s: %s%s\n' \
    "$(wb__paint 31 '✗')" "$(wb__paint 31 "$stage")" "$msg" "${doc:+ → $doc}" >&2
  exit "$code"
}

# ── 命令执行与文件写入（干跑与回显的唯一入口）──────────────────────────
# 所有会产生系统改动的操作都必须经这里：
#   * 执行命令                    → wb_run
#   * 向文件写值（sysfs 等）      → wb_write
# 这样 --dry-run / --verbose 才能在全局生效。
# 直接执行命令、或直接 `echo > /sys/...`，在本项目里视为缺陷。
wb_run() {
  if (( WB_DRY_RUN )); then
    printf '  %s %s\n' "$(wb__paint 36 '[dry-run]')" "$*" >&2
    return 0
  fi
  if (( WB_VERBOSE )); then
    printf '  %s %s\n' "$(wb__paint 36 '+')" "$*" >&2
  fi
  "$@"
}

# wb_write FILE VALUE —— 向文件写值的 wb_run 对应物（sysfs 之类）
# 失败时返回 1、不退出：调用方决定这是致命错误还是一句警告
wb_write() {
  local file=${1:-} value=${2-}
  [[ -n $file ]] || wb_fail 2 log "wb_write 缺少文件参数" "docs/interfaces/04-lib-api.md"
  if (( WB_DRY_RUN )); then
    printf '  %s %s ← %s\n' "$(wb__paint 36 '[dry-run]')" "$file" "$value" >&2
    return 0
  fi
  if (( WB_VERBOSE )); then
    printf '  %s %s ← %s\n' "$(wb__paint 36 '+')" "$file" "$value" >&2
  fi
  printf '%s\n' "$value" > "$file" 2>/dev/null
}

# wb_capture CMD… → stdout = 命令输出；失败不中断（调用方自行判据）
wb_capture() { "$@" 2>/dev/null || true; }
