# guest/ —— 客机（Windows）侧脚本

这些脚本在**客机内**运行，用来做两件事：建立宿主→客机的 SSH 通道，以及在通道不可用时
手动体检。

| 文件 | 作用 | 何时用 |
| --- | --- | --- |
| `setup-sshd.ps1` | 安装并启用 OpenSSH Server、创建专用账号、授权宿主公钥、验证监听 | 装完 Windows 之后一次性动作 |
| `verify-gpu.ps1` | 打印显示适配器状态 + IDD 状态与偏好 + IDD 日志尾部 | SSH 通道不通，或想快速确认"客机现在什么状态" |

## 怎么把它们送进客机

通道建好之前，用任何方式都行（共享文件夹、剪贴板、ISO、U 盘）。通道建好之后：

```bash
# 宿主侧：把文件投递到客机桌面（scp 走的是同一条 SSH 通道）
scp -i ~/.ssh/vm-win11 setup-sshd.ps1 piagent@<客机IP>:C:/Users/piagent/Desktop/
```

在 win-box 里，这一步由 `lib/guest.sh` 的 `wb_guest_put` 承担。

## 为什么是 PowerShell 而不是批处理

本项目工作区里最初的一批 `.bat` 是临时排障产物：里面写死了内网地址、遥测上传端点、
甚至账号口令，而且是"边试边改"堆出来的。这些不适合放进可分享的仓库，因此客机侧
按最终形态重写为参数化的 PowerShell 脚本（口令、公钥、账号名都是参数）。

## 不在这里的东西

- **Windows 镜像**：自备合法授权镜像。
- **AMD 显卡驱动**：从官方渠道下载**离线**安装包（在线安装器会拒绝在直通环境安装）。
- **Looking Glass IDD 安装包**：来自 `third_party/LookingGlass` 的构建产物
  （`winbox lg-prepare` 构建客户端；IDD 安装包需自行从 LG 项目获取或构建）。
- **VirtIO 驱动**：如需 virtio 磁盘/网卡，从 Fedora 的 virtio-win 项目获取。

原因见根 README 的"本仓库不包含、也不分发"一节与 `.gitignore`。
