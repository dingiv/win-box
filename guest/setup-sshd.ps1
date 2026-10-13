<#
code-master:title win-box · guest · 建立 SSH 通道（在客机内以管理员运行）

为什么需要它：客机侧的一切动作（查显卡状态、应用 IDD 偏好、看 IDD 日志）都经这条通道。
比"注入按键 + HTTP 回传"可靠得多——后者会被 Defender 拦下载、被 Win+R 自动补全搞坏、
还依赖剪贴板通道。

用法（在客机内、以管理员身份运行 PowerShell）：
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\setup-sshd.ps1 -PublicKey "ssh-ed25519 AAAAC3... 你@宿主"

  # 常用参数：
  #   -User piagent            专用账号名（默认 piagent）
  #   -Password '...'          账号口令；省略则用随机口令并打印（别用空口令）
  #   -AllowBlankPassword      允许空口令账号登录（仅在确实需要时用）
  #   -SkipFirewallRule        不动防火墙（已经放行过时）

之后在宿主上：
  winbox conf WB_GUEST_USER=piagent        # 写进配置
  winbox conf WB_GUEST_HOST=<客机IP>
  winbox conf WB_GUEST_KEY=~/.ssh/vm-win11
  winbox status --guest                    # 应能看到客机检查项

步骤依据：OpenSSH.Server 能力安装 → 服务自启 → 防火墙放行 22 →
专用账号加入 Administrators → 公钥写入 administrators_authorized_keys（含 ACL）→ 验证监听。
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$User = 'piagent',
  [string]$Password,
  [Parameter(Mandatory = $true)][string]$PublicKey,
  [switch]$AllowBlankPassword,
  [switch]$SkipFirewallRule
)

$ErrorActionPreference = 'Continue'
function Step($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  ✓ $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  ⚠ $t" -ForegroundColor Yellow }

Step '1/6 安装 OpenSSH Server 能力'
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -eq 'Installed') {
  Ok '已安装'
} else {
  Write-Host "  安装中（可能要几分钟）…"
  $r = Add-WindowsCapability -Online -Name $cap.Name
  Ok ("安装结果: " + $r.RestartNeeded)
}

Step '2/6 服务自启并启动'
foreach ($svc in 'sshd', 'ssh-agent') {
  if (Get-Service $svc -ErrorAction SilentlyContinue) {
    Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name $svc -ErrorAction SilentlyContinue
    $s = Get-Service $svc
    Ok "$svc → $($s.Status) / $($s.StartType)"
  } else {
    Warn "$svc 不存在"
  }
}

Step '3/6 防火墙放行 22 端口'
if ($SkipFirewallRule) {
  Warn '按参数跳过'
} else {
  if (-not (Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'sshd' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
      -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Ok '已新建规则 sshd'
  } else {
    Ok '规则已存在'
  }
}

Step '4/6 专用账号'
if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
  Ok "账号已存在: $User"
} else {
  if (-not $Password) {
    $Password = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
    Write-Host "  已生成随机口令（请记录）: $Password" -ForegroundColor Yellow
  }
  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  New-LocalUser -Name $User -Password $sec -PasswordNeverExpires -AccountNeverExpires | Out-Null
  Ok "已创建账号: $User"
}
Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue
Ok "$User 属于 Administrators"

# 空口令账号默认被 LSA 策略挡住（LimitBlankPasswordUse）——只有确实需要时才关掉
$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
if ($AllowBlankPassword) {
  Set-ItemProperty -Path $lsa -Name LimitBlankPasswordUse -Value 0 -Type DWord
  Warn '已允许空口令账号（LimitBlankPasswordUse=0）—— 不建议长期保持'
} else {
  Write-Host "  当前 LimitBlankPasswordUse = $((Get-ItemProperty $lsa).LimitBlankPasswordUse)（1 = 空口令不放行，正常）"
}

Step '5/6 授权宿主公钥'
# 管理员账号用 administrators_authorized_keys（不是用户家目录下的 authorized_keys）
$dir = 'C:\ProgramData\ssh'
$file = Join-Path $dir 'administrators_authorized_keys'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
$key = $PublicKey.Trim()
$cur = @(Get-Content $file -ErrorAction SilentlyContinue)
if ($cur -notcontains $key) {
  Add-Content -Path $file -Value $key
  Ok '公钥已追加'
} else {
  Ok '公钥已存在'
}
# ACL 必须是 Administrator + SYSTEM，否则 sshd 会拒绝使用这个文件
icacls $file /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Ok 'ACL 已收紧（Administrators + SYSTEM）'

Step '6/6 验证监听'
$hit = netstat -an | Select-String ':22\s+.*LISTEN'
if ($hit) { Ok ($hit | Select-Object -First 3 | ForEach-Object { $_.Line.Trim() } | Out-String).Trim() }
else { Warn '没看到 22 端口监听——检查 Get-Service sshd 与事件日志' }

Write-Host "`n完成。在宿主上配置并验证：" -ForegroundColor Cyan
Write-Host "  winbox conf WB_GUEST_USER=$User"
Write-Host "  winbox conf WB_GUEST_HOST=<客机IP>"
Write-Host "  winbox conf WB_GUEST_KEY=~/.ssh/vm-win11"
Write-Host "  winbox status --guest"
