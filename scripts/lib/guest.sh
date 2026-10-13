#!/usr/bin/env bash
# code-master:title win-box · 客机交互通道（lib/guest.sh）
#
# 契约：docs/interfaces/04-lib-api.md
#
# 客机侧的事情（装 IDD、改 IDD 偏好、查显卡状态）都经这条通道：微软官方 OpenSSH + 专用密钥
# + PowerShell 作默认 shell。比"注入按键 + HTTP 回传"可靠得多（后者被 Defender 拦下载、
# 被 Win+R 自动补全搞坏、还依赖剪贴板通道）。
#
# 纪律：**没配通道不是故障**。所有客机检查都必须先 wb_guest_ready —— 返回 1 时调用方
# 应当降级为 ⚠ 并跳过，而不是报错（调用 wb_guest_ps 才是"必须有通道"的语义）。

[[ -n ${WB_LIB_GUEST_LOADED:-} ]] && return 0
WB_LIB_GUEST_LOADED=1

WB_LIB_DIR=${WB_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./log.sh
[[ -n ${WB_LIB_LOG_LOADED:-} ]] || source "$WB_LIB_DIR/log.sh"
# shellcheck source=./sys.sh
[[ -n ${WB_LIB_SYS_LOADED:-} ]] || source "$WB_LIB_DIR/sys.sh"
# shellcheck source=./conf.sh
[[ -n ${WB_LIB_CONF_LOADED:-} ]] || source "$WB_LIB_DIR/conf.sh"

WB_CONF_KEYS+=(WB_GUEST_KEY WB_GUEST_PORT)

wb__guest_key_path() {
  local k
  # shellcheck disable=SC2088  # 这里的 ~ 是故意的：由下面一行展开（配置里写 ~ 更符合习惯）
  k=$(wb_conf_get_default WB_GUEST_KEY '~/.ssh/vm-win11')
  printf '%s\n' "${k/#\~/$HOME}"
}

# 是否已配置通道（只看配置，不探测）
wb_guest_configured() {
  local u h
  u=$(wb_conf_get_default WB_GUEST_USER '')
  h=$(wb_conf_get_default WB_GUEST_HOST '')
  [[ -n $u && -n $h ]]
}

# 通道可用？（配置齐 + 密钥存在 + 端口可达）——只返回 0/1，不打印
wb_guest_ready() {
  wb_guest_configured || return 1
  local host port key
  host=$(wb_conf_get_default WB_GUEST_HOST '')
  port=$(wb_conf_get_default WB_GUEST_PORT 22)
  key=$(wb__guest_key_path)
  [[ -f $key ]] || return 1
  timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || return 1
  return 0
}

# 执行一条 PowerShell 命令；stdout = 命令输出
wb_guest_ps() {
  local ps=${1:-}
  [[ -n $ps ]] || wb_fail 2 guest "wb_guest_ps 需要命令文本" "docs/interfaces/04-lib-api.md"
  wb_conf_require WB_GUEST_USER WB_GUEST_HOST
  local host user port key
  host=$(wb_conf_get WB_GUEST_HOST)
  user=$(wb_conf_get WB_GUEST_USER)
  port=$(wb_conf_get_default WB_GUEST_PORT 22)
  key=$(wb__guest_key_path)
  [[ -f $key ]] || wb_fail 3 guest "客机 SSH 密钥不存在: $key" "docs/zh/04-客机SSH直连通道.md"

  wb_have_cmd ssh || wb_fail 3 guest "缺少 ssh 客户端" "docs/zh/04-客机SSH直连通道.md"
  ssh -i "$key" -p "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    "${user}@${host}" \
    powershell -NoProfile -NonInteractive -Command \
    "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; \$ErrorActionPreference='Continue'; $ps"
}

# 投递文件（scp）。注意：客机侧路径用 C:\... 形式时要写成 /C:/... 给 scp
wb_guest_put() {
  local local_path=${1:-} remote=${2:-}
  [[ -f $local_path ]] || wb_fail 3 guest "文件不存在: ${local_path:-<空>}" "docs/interfaces/04-lib-api.md"
  [[ -n $remote ]] || wb_fail 2 guest "wb_guest_put 需要目标路径" "docs/interfaces/04-lib-api.md"
  wb_conf_require WB_GUEST_USER WB_GUEST_HOST
  local host user port key
  host=$(wb_conf_get WB_GUEST_HOST)
  user=$(wb_conf_get WB_GUEST_USER)
  port=$(wb_conf_get_default WB_GUEST_PORT 22)
  key=$(wb__guest_key_path)
  wb_require_file "$key"
  wb_run scp -i "$key" -P "$port" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
    -- "$local_path" "${user}@${host}:${remote}"
}

# 客机显卡状态（人可读的多行文本）
wb_guest_gpu_status() {
  wb_guest_ps 'Get-CimInstance Win32_VideoController |
    Select-Object Name,Status,ConfigManagerErrorCode,DriverVersion |
    Format-List'
}

# 客机 IDD 现状（注册表里的偏好）
wb_guest_idd_status() {
  wb_guest_ps 'Get-ItemProperty "HKLM:\SOFTWARE\LookingGlass\IDD" -ErrorAction SilentlyContinue |
    Select-Object ExclusiveMonitor,ForceIndirectCopy,ForceFullDirectCopy,DefaultRefresh,ExtraMode |
    Format-List'
}

# ── 供 status 解析的“一行一条”形式（人可读版本保留在上方）───────────────

# 每行: <名字>|<Status>|<ConfigManagerErrorCode>|<驱动版本>
wb_guest_gpu_lines() {
  wb_guest_ps 'Get-CimInstance Win32_VideoController |
    ForEach-Object { "$($_.Name)|$($_.Status)|$($_.ConfigManagerErrorCode)|$($_.DriverVersion)" }'
}

# 每行前缀式：
#   prefs|ExclusiveMonitor=..|ForceIndirectCopy=..|ForceFullDirectCopy=..
#   dev|<型号>|<状态>            （仅 IDD 虚拟显示器 ROOT\DISPLAY*）
#   log|<最近一条含 mode= 的日志行>
wb_guest_idd_lines() {
  wb_guest_ps '$k="HKLM:\SOFTWARE\LookingGlass\IDD";
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue;
    if ($p) { "prefs|ExclusiveMonitor=$($p.ExclusiveMonitor)|ForceIndirectCopy=$($p.ForceIndirectCopy)|ForceFullDirectCopy=$($p.ForceFullDirectCopy)" } else { "prefs|missing" };
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like "ROOT\DISPLAY*" } |
      ForEach-Object { "dev|$($_.FriendlyName)|$($_.Status)" };
    $log="C:\ProgramData\Looking Glass (IDD)\looking-glass-idd.txt";
    if (Test-Path $log) {
      $m = Get-Content $log -Tail 300 | Select-String "mode=" | Select-Object -Last 1;
      if ($m) { "log|" + $m.Line.Trim() }
    }'
}
