<#
code-master:title win-box · guest · 客机侧一次性诊断（无需 SSH 即可运行）

用途：SSH 通道还没建好、或者通道本身出问题时，在客机内手动跑一次，
把"显卡驱动状态 + IDD 状态与偏好 + IDD 日志尾部"一次打全。

用法（在客机内 PowerShell 里，普通权限即可）：
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\verify-gpu.ps1              # 打印到屏幕
  .\verify-gpu.ps1 -OutFile C:\Users\Public\winbox-gpu.txt   # 同时存文件

判据（对照 docs/zh/01、05）：
  * 核显 Status=OK 且 ConfigManagerErrorCode=0   → 直通成功（代码 43 已解）
  * IDD 偏好 ExclusiveMonitor=0 / ForceIndirectCopy=1 → 物理屏与 LG 可共存、GPU 不被挂起
  * IDD 日志出现 Device Removed (0x887A0007)    → 命中了 D3D12 直传路径的驱动缺陷
#>
[CmdletBinding()]
param([string]$OutFile)

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$s) { $lines.Add($s); Write-Host $s }

Add-Line "== win-box 客机诊断 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =="
Add-Line "主机: $env:COMPUTERNAME   用户: $env:USERNAME"

Add-Line "`n== 1. 显示适配器 =="
$adapters = Get-CimInstance Win32_VideoController
foreach ($a in $adapters) {
  $flag = if ($a.Status -eq 'OK' -and $a.ConfigManagerErrorCode -eq 0) { 'OK ' } else { 'BAD' }
  Add-Line ("  [{0}] {1}" -f $flag, $a.Name)
  Add-Line ("        Status={0}  ErrCode={1}  驱动={2}" -f $a.Status, $a.ConfigManagerErrorCode, $a.DriverVersion)
  if ($a.ConfigManagerErrorCode -ne 0) {
    Add-Line ("        → 常见含义: 43 = 显示驱动因“不是 POST 设备驱动”被拒（见 docs/zh/01）")
  }
}

Add-Line "`n== 2. 直通设备与 IDD 设备 =="
Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
  ForEach-Object { Add-Line ("  {0,-8} {1}  [{2}]" -f $_.Status, $_.FriendlyName, $_.InstanceId) }

Add-Line "`n== 3. Looking Glass IDD 偏好（注册表）=="
$k = 'HKLM:\SOFTWARE\LookingGlass\IDD'
$p = Get-ItemProperty $k -ErrorAction SilentlyContinue
if ($p) {
  foreach ($n in 'ExclusiveMonitor', 'ForceIndirectCopy', 'ForceFullDirectCopy', 'DefaultRefresh', 'ExtraMode') {
    Add-Line ("  {0,-20} = {1}" -f $n, $p.$n)
  }
  Add-Line "  建议: ExclusiveMonitor=0 / ForceIndirectCopy=1 / ForceFullDirectCopy=0"
} else {
  Add-Line "  （没有该键 = IDD 未安装：运行 looking-glass-idd-setup.exe /S /ivshmem）"
}

Add-Line "`n== 4. IDD 日志尾部（判白方块 / Device Removed 的依据）=="
$log = 'C:\ProgramData\Looking Glass (IDD)\looking-glass-idd.txt'
if (Test-Path $log) {
  $tail = Get-Content $log -Tail 40 -ErrorAction SilentlyContinue
  foreach ($l in $tail) { Add-Line "  $l" }
  $bad = Get-Content $log -Tail 300 | Select-String 'Device Removed|HeapTest' | Select-Object -Last 3
  if ($bad) {
    Add-Line "`n  ⚠ 检测到 Device Removed / HeapTest —— 命中了 D3D12 直传路径的 AMD 驱动缺陷："
    Add-Line "     修法: winbox lg --idd-prefs（把 IDD 切到间接拷贝路径）"
  }
} else {
  Add-Line "  （没有日志文件：IDD 可能未安装或未运行）"
}

Add-Line "`n== 5. Windows 版本与内存 =="
Add-Line ("  " + (Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption))
Add-Line ("  内存: {0:N1} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB))

if ($OutFile) {
  $lines | Set-Content -Path $OutFile -Encoding UTF8
  Write-Host "`n已写入 $OutFile" -ForegroundColor Cyan
  Write-Host "传到宿主（在宿主上跑）: scp -i ~/.ssh/vm-win11 piagent@<客机IP>:C:/Users/Public/winbox-gpu.txt ."
}
