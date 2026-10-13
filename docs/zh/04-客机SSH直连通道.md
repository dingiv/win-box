# 04 客机 SSH 直连通道（宿主 → Windows 执行命令）

> 结论：在客机里装**微软官方 OpenSSH Server** + 建专用账户 + 授权宿主公钥，
> 之后就能 `ssh piagent@192.168.122.228 '命令'` 直接在 Windows 里执行并读回输出。
> 这是本次工程里**性价比最高的基础设施**：把"注入按键 + HTTP 回传文件"的绕路全部替换掉了。

## 1. 为什么需要它

> **关于本文**：这是当时的**实录**（含走过的弯路与证据），不是使用说明。
> 命令已规整为本仓库的形式（`winbox …`）；接口以 `docs/interfaces/` 为准。

在没有 SSH 之前，宿主无法主动读客机内部状态：

- 客机在物理屏/IDD 上，画面看不见（我只有命令行）；
- **LG 剪贴板**当时因为 IDD 抖动而不通，"把命令粘进客机"经常失败；
- **注入按键**（QEMU `send-key`）可行但脆弱：`Win+R` 有自动补全、UAC 需要人工点、
  Defender 会拦"下载即执行"的命令行（`cmd /c curl … & file.bat`、`iex(iwr …)`）；
- **HTTP 回传**（`（已废弃：改用 winbox status/evidence）` + 客机 `curl -X POST`）只能单向拿文本，且要提前铺脚本。

SSH 一次性解决：**双向、可交互、可传文件（scp）、可脚本化**。

## 2. 客机侧安装（本次由用户手动执行，也可用 `guest/setup-sshd.ps1`）

管理员 PowerShell / cmd：

```cmd
curl -L -o %TEMP%\s.bat http://192.168.122.1:8000/s.bat
%TEMP%\s.bat
```

脚本做四件事：

| 步骤 | 命令 | 说明 |
|---|---|---|
| 1 | `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` | 微软一方组件（从 Windows Update 拉） |
| 2 | `Set-Service sshd -StartupType Automatic` + `Start-Service sshd` | 服务自启 |
| 3 | 防火墙放行 TCP 22（组件通常会自建规则） | |
| 4 | 建专用账户 `piagent`（Administrators） + 写入宿主公钥 | 见下 |

### 三个关键细节

1. **专用账户而不是复用现有账户**：Windows 默认策略
   *"Accounts: Limit local account use of blank passwords to console logon only"*
   会拒绝**空密码账户**的网络登录 —— 自动登录的账户往往没有密码，SSH 会被拒。
   新建一个带密码的管理员账户最省事（也不影响现有账户的自动登录）。
2. **管理员账户的密钥文件不是用户目录**：必须写
   `C:\ProgramData\ssh\administrators_authorized_keys`，并修正 ACL：

   ```
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
   ```
3. **默认 shell 是 cmd**：可改注册表让新会话用 PowerShell：

   ```cmd
   reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ ^
     /d "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" /f
   ```

## 3. 宿主侧：密钥 + 包装脚本

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vm-win11 -N '' -C 'pi-agent@ubt-vm-win11'
ssh -i ~/.ssh/vm-win11 piagent@192.168.122.228 powershell -NoProfile -Command '"PS " + $PSVersionTable.PSVersion.ToString()'
```

`lib/guest.sh（客机 SSH 通道）` 的要点：

```bash
CMD='[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '"$*"
exec ssh -i ~/.ssh/vm-win11 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o BatchMode=yes -o ConnectTimeout=15 \
    piagent@192.168.122.228 \
    powershell -NoProfile -NonInteractive -Command "$CMD"
```

- **统一走 PowerShell + 强制 UTF-8**：否则通过管道时中文会乱码
  （`[Console]::OutputEncoding` 是必须的，用 cmd 更会得到 GBK 乱码）；
- `BatchMode=yes` 让认证失败立即报错而不是卡在密码提示；
- `LogLevel=ERROR` 抑制那条 "post-quantum key exchange" 警告。

## 4. 实际用法示例

```bash
# 显示设备状态（本次排障的主力命令）
ssh -i ~/.ssh/vm-win11 piagent@192.168.122.228 powershell -NoProfile -Command 'Get-CimInstance Win32_VideoController | Format-Table Name,Status,ConfigManagerErrorCode,DriverVersion -AutoSize'

# 读 IDD 日志里感兴趣的行
ssh -i ~/.ssh/vm-win11 piagent@192.168.122.228 powershell -NoProfile -Command 'Get-Content "C:\ProgramData\Looking Glass (IDD)\looking-glass-idd.txt" -Encoding UTF8 |
  Select-String -Pattern "Selected render adapter|HeapTest|Frame graph" | Select-Object -Last 5 | ForEach-Object { $_.Line }'

# 改 IDD 偏好并重载驱动
ssh -i ~/.ssh/vm-win11 piagent@192.168.122.228 powershell -NoProfile -Command 'Set-ItemProperty "HKLM:\SOFTWARE\LookingGlass\IDD" -Name ForceIndirectCopy -Value 1 -Type DWord;
  $d="ROOT\DISPLAY\0000"; Disable-PnpDevice -InstanceId $d -Confirm:$false; Start-Sleep 4; Enable-PnpDevice -InstanceId $d -Confirm:$false'

# 看事件日志（TDR / PnP）
ssh -i ~/.ssh/vm-win11 piagent@192.168.122.228 powershell -NoProfile -Command 'Get-WinEvent -FilterHashtable @{LogName="System"; StartTime=(Get-Date).AddMinutes(-15)} |
  Where-Object { $_.Id -in 4101,4102 -or $_.ProviderName -match "Display" } | Select-Object -First 10 TimeCreated,Id,Message | Format-List'
```

**注意**：SSH 会话是**非交互会话（session 0 语义）**，因此
- `[System.Windows.Forms.Screen]::AllScreens` 之类会返回虚拟桌面（`WinDisc 1024x768`），**不能用来查真实显示器拓扑**；
- 剪贴板 API 也属于登录会话，SSH 里拿不到用户剪贴板。

## 5. 安全边界

- sshd 只监听在 libvirt NAT 网段（`192.168.122.0/24`），**只有宿主能连**，公网不可达；
- 认证是**公钥**（`~/.ssh/vm-win11`，无密码短语，仅用于本机→本 VM）；
- 需要时可随时 `Stop-Service sshd` 或卸载组件收尾。

## 6. 迁移/重装客机后的恢复步骤

1. 在客机里跑 `guest/setup-sshd.ps1`（`guest/` 里已备好，含公钥常量）；
2. 确认 `22` 端口通：`timeout 4 bash -c 'cat < /dev/null > /dev/tcp/192.168.122.228/22'`；
3. `ssh -i ~/.ssh/vm-win11 piagent@192.168.122.228 powershell -NoProfile -Command 'whoami'` 应返回 `div\piagent`。
