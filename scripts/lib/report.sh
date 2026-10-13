#!/usr/bin/env bash
# code-master:title win-box · 分节报告与取证清单（lib/report.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 被 winbox status 与 winbox evidence 共用。两条设计：
#
#   * **报告即结果**：人类可读报告走 stdout（不是 stderr）——它是这条命令的产物，
#     要能 `winbox status | tee`、能 grep、能贴进 issue。
#   * **两种模式共用同一份数据**：--json 时不边跑边打印，而是把条目缓冲下来，
#     最后一次性输出结构化结果。这样文本与 JSON 永远描述同一件事。
#
# 判定规则（唯一）：任一 bad → BROKEN(7)；只有 warn → DEGRADED(6)；全 ok → OK(0)。

[[ -n ${WB_LIB_REPORT_LOADED:-} ]] && return 0
WB_LIB_REPORT_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"

WB_REPORT_JSON=${WB_REPORT_JSON:-0}
WB_REPORT_QUIET=${WB_REPORT_QUIET:-0}
declare -gA WB_REPORT_COUNT=([ok]=0 [warn]=0 [bad]=0 [info]=0)
declare -ga WB_REPORT_LINES=()

wb_report_reset() {
  WB_REPORT_COUNT=([ok]=0 [warn]=0 [bad]=0 [info]=0)
  WB_REPORT_LINES=()
}

wb_report_section() {
  WB_REPORT_LINES+=("SECTION|${1:-}")
  (( WB_REPORT_JSON )) && return 0
  printf '\n%s %s\n' "$(wb__paint 1 '==')" "$(wb__paint 1 "${1:-}")"
  return 0
}

# wb_report_item LEVEL TEXT [HINT]
wb_report_item() {
  local level=${1:-info} text=${2:-} hint=${3:-}
  case $level in ok | warn | bad | info) ;; *) level=info ;; esac
  WB_REPORT_COUNT[$level]=$(( ${WB_REPORT_COUNT[$level]} + 1 ))
  WB_REPORT_LINES+=("ITEM|$level|$text|$hint")
  (( WB_REPORT_JSON )) && return 0
  local mark color
  case $level in
    ok)   mark='✓'; color=32 ;;
    warn) mark='⚠'; color=33 ;;
    bad)  mark='✗'; color=31 ;;
    *)    mark='·'; color=0 ;;
  esac
  printf '  %s %s\n' "$(wb__paint "$color" "$mark")" "$text"
  [[ -n $hint ]] && printf '      %s\n' "$hint"
  return 0
}

wb_report_counts() {
  printf 'ok=%d warn=%d bad=%d info=%d\n' \
    "${WB_REPORT_COUNT[ok]}" "${WB_REPORT_COUNT[warn]}" "${WB_REPORT_COUNT[bad]}" "${WB_REPORT_COUNT[info]}"
}

wb__json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

wb__report_json_emit() {
  local result=${1:-} line kind level text hint first_item first_sec=1 in_sec=0
  printf '{\n  "result": "%s",\n' "$result"
  printf '  "counts": {"ok": %d, "warn": %d, "bad": %d, "info": %d},\n' \
    "${WB_REPORT_COUNT[ok]}" "${WB_REPORT_COUNT[warn]}" "${WB_REPORT_COUNT[bad]}" "${WB_REPORT_COUNT[info]}"
  printf '  "sections": ['
  for line in "${WB_REPORT_LINES[@]}"; do
    kind=${line%%|*}
    if [[ $kind == SECTION ]]; then
      [[ $in_sec == 1 ]] && printf '\n    ]}'
      (( first_sec )) || printf ','
      first_sec=0
      printf '\n    {"title": "%s", "items": [' "$(wb__json_escape "${line#SECTION|}")"
      in_sec=1
      first_item=1
      continue
    fi
    # 没有显式 section 时自动补一个（否则 items 数组会以逗号开头 → 非法 JSON）
    [[ $in_sec == 1 ]] || { printf '\n    {"title": "", "items": ['; in_sec=1; first_sec=0; first_item=1; }
    level=${line#ITEM|}; level=${level%%|*}
    text=${line#ITEM|*|}; text=${text%%|*}
    hint=${line##*|}
    (( first_item )) || printf ','
    first_item=0
    printf '\n      {"level": "%s", "text": "%s"' "$level" "$(wb__json_escape "$text")"
    [[ -n $hint ]] && printf ', "hint": "%s"' "$(wb__json_escape "$hint")"
    printf '}'
  done
  [[ $in_sec == 1 ]] && printf '\n    ]}'
  printf '\n  ]\n}\n'
}

# 收尾：打印结论并**返回** 0/6/7（不自己 exit —— 由命令决定是否把结论变退出码）
wb_report_result() {
  local result code
  if (( WB_REPORT_COUNT[bad] > 0 )); then result=BROKEN; code=7
  elif (( WB_REPORT_COUNT[warn] > 0 )); then result=DEGRADED; code=6
  else result=OK; code=0; fi

  if (( WB_REPORT_JSON )); then
    wb__report_json_emit "$result"
  elif (( ! WB_REPORT_QUIET )); then
    local color=32
    case $result in DEGRADED) color=33 ;; BROKEN) color=31 ;; esac
    printf '\n%s %s（%s）\n' "$(wb__paint 1 'RESULT:')" \
      "$(wb__paint "$color" "$result")" "$(wb_report_counts)"
  fi
  return "$code"
}

# wb_evidence_manifest DIR → 在目录里生成 manifest.txt（文件清单 + sha256 前 16 位）
wb_evidence_manifest() {
  local dir=${1:-}
  wb_require_dir "$dir"
  (
    cd "$dir" || exit 1
    {
      printf '# win-box 取证清单  生成时间: %s\n' "$(date '+%F %T')"
      printf '# 主机: %s   内核: %s\n' "$(uname -n)" "$(uname -r)"
      printf '# 用途: 排障时把整个目录发给别人，凭 sha256 确认内容未被改动\n#\n'
      printf '# %-16s %s\n' 'SHA256(前16位)' '文件'
      find . -maxdepth 1 -type f ! -name manifest.txt -printf '%f\n' | sort | while IFS= read -r f; do
        printf '  %-16s %s\n' "$(sha256sum -- "$f" | cut -c1-16)" "$f"
      done
      printf '#\n# 共 %d 个文件\n' "$(find . -maxdepth 1 -type f ! -name manifest.txt | wc -l)"
    } > manifest.txt
  )
  return 0
}
