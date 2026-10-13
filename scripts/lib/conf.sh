#!/usr/bin/env bash
# code-master:title win-box · 配置（lib/conf.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 本文件是**唯一**允许读取配置的入口。业务代码禁止直接读环境变量，
# 也禁止自己解析 config/win-box.conf —— 否则优先级规则会到处复制、早晚不一致。
#
# 配置优先级：命令行（dispatcher 写 WB_CONF_PATH/标志） > 环境变量 WB_* > 文件 > 内置默认
# 空值视为未设置（因此"留空"与"没写"等价）。

[[ -n ${WB_LIB_CONF_LOADED:-} ]] && return 0
WB_LIB_CONF_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"

declare -gA WB_CONF=()
WB_CONF_PATH=${WB_CONF_PATH:-}

# 已知键（用于 dump 与文档一致性；文件里的额外键也会被列出）
WB_CONF_KEYS=(
  WB_VM_NAME WB_GPU_BDF WB_AUDIO_BDF WB_GPU_ID WB_AUDIO_ID WB_IOMMU_GROUP
  WB_VBIOS_DIR WB_VBIOS_GPU WB_VBIOS_AUDIO
  WB_SHM_SIZE_MB WB_LG_SRC WB_LG_CLIENT
  WB_GUEST_USER WB_GUEST_HOST WB_REBOOT_WAIT
)

wb_conf_path() {
  if [[ -n ${WB_CONF_PATH:-} ]]; then printf '%s\n' "$WB_CONF_PATH"; return 0; fi
  printf '%s\n' "${WB_ROOT:-$(pwd)}/config/win-box.conf"
}

wb__conf_valid_key() { [[ ${1:-} =~ ^WB_[A-Z0-9_]+$ ]]; }

# 载入配置文件。文件不存在不算错误（全部走默认/环境变量）。
# 语法错误 → 码 3（带行号），因为静默忽略错误行会让"配置没生效"变得极难排查。
wb_conf_load() {
  local file=${1:-$(wb_conf_path)} line key val n=0
  WB_CONF=()
  [[ -f $file ]] || return 0

  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ -z ${line//[[:space:]]/} ]] && continue          # 空行
    [[ $line =~ ^[[:space:]]*# ]] && continue           # 注释
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[2]}
      val=${BASH_REMATCH[3]}
      val=${val#"${val%%[![:space:]]*}"}                 # 去首空白
      val=${val%"${val##*[![:space:]]}"}                 # 去尾空白
      if [[ $val == \"*\" || $val == \'*\' ]]; then val=${val:1:${#val}-2}; fi
      wb__conf_valid_key "$key" || wb_fail 3 conf "配置文件第 $n 行键名非法: $key" "docs/interfaces/04-lib-api.md"
      WB_CONF[$key]=$val
    else
      wb_fail 3 conf "配置文件第 $n 行语法错误: $line" "docs/interfaces/04-lib-api.md"
    fi
  done < "$file"
  return 0
}

# wb_conf_get KEY → stdout = 值；未定义 → 码 3（**不返回空串**）
wb_conf_get() {
  local key=${1:-} v
  wb__conf_valid_key "$key" || wb_fail 2 conf "配置键名非法: ${key:-<空>}" "docs/interfaces/04-lib-api.md"

  v=$(printenv "$key" 2>/dev/null || true)
  if [[ -n $v ]]; then printf '%s\n' "$v"; return 0; fi

  v=${WB_CONF[$key]:-}
  if [[ -n $v ]]; then printf '%s\n' "$v"; return 0; fi

  wb_fail 3 conf "配置键未定义: $key（先跑 winbox detect --write，或写入 $(wb_conf_path)）" \
    "docs/interfaces/04-lib-api.md"
}

# wb_conf_get_default KEY DEFAULT → stdout = 值或默认值；永不失败
wb_conf_get_default() {
  local key=$1 def=${2-} v
  v=$(printenv "$key" 2>/dev/null || true)
  [[ -n $v ]] || v=${WB_CONF[$key]:-}
  printf '%s\n' "${v:-$def}"
}

# wb_conf_set KEY VALUE → 原子写回（temp+rename），保留注释与顺序，改前备份 .bak
wb_conf_set() {
  local key=${1:-} val=${2-} file tmp found=0 line

  wb__conf_valid_key "$key" || wb_fail 2 conf "配置键名非法: ${key:-<空>}" "docs/interfaces/04-lib-api.md"
  if [[ $val == *[[:space:]]* ]]; then
    wb_fail 3 conf "配置值不能含空白: $key=$val（配置是简单 KEY=VALUE 格式）" \
      "docs/interfaces/04-lib-api.md"
  fi

  file=$(wb_conf_path)
  if wb_is_dry_run; then
    wb_log "  [dry-run] 写配置: $key=$val → $file"
    return 0
  fi

  mkdir -p -- "$(dirname -- "$file")"
  [[ -f $file ]] && cp -f -- "$file" "${file}.bak"
  tmp=$(mktemp -- "${file}.XXXXXX")

  if [[ -f $file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?${key}= ]]; then
        printf '%s=%s\n' "$key" "$val"
        found=1
      else
        printf '%s\n' "$line"
      fi
    done < "$file" > "$tmp"
  fi
  (( found )) || printf '%s=%s\n' "$key" "$val" >> "$tmp"

  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$file"

  WB_CONF[$key]=$val
  return 0
}

# 一次检查多个键是否存在（存在 = 环境变量或文件里有非空值）
wb_conf_require() {
  local missing=() k
  for k in "$@"; do
    if [[ -z $(printenv "$k" 2>/dev/null || true) && -z ${WB_CONF[$k]:-} ]]; then
      missing+=("$k")
    fi
  done
  if (( ${#missing[@]} )); then
    wb_fail 3 conf "缺少配置: ${missing[*]}（先跑 winbox detect --write）" \
      "docs/interfaces/01-winbox-cli.md"
  fi
  return 0
}

# wb_conf_dump [--json] → 全键 + 来源（env / file / -）
wb_conf_dump() {
  local json=0 k v src first=1
  [[ ${1:-} == --json ]] && json=1

  if (( json )); then printf '{'; else printf '%-20s %-6s %s\n' KEY 来源 值; fi

  while IFS= read -r k; do
    v=$(printenv "$k" 2>/dev/null || true); src='env'
    if [[ -z $v ]]; then v=${WB_CONF[$k]:-}; src='file'; fi
    if [[ -z $v ]]; then
      if (( json )); then continue; fi
      v='(未设置)'; src=-
    fi
    if (( json )); then
      (( first )) || printf ','; first=0
      printf '"%s":"%s"' "$k" "$v"
    else
      printf '%-20s %-6s %s\n' "$k" "$src" "$v"
    fi
  done < <(wb__conf_all_keys)

  if (( json )); then printf '}\n'; fi
  return 0
}

# 已知键 ∪ 文件里出现的额外键（排序、去重）
wb__conf_all_keys() {
  printf '%s\n' "${WB_CONF_KEYS[@]}" "${!WB_CONF[@]}" | sort -u
}
