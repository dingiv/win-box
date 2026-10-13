# 接口契约：`winbox` 主入口

> 形式：CLI。本文件是 `winbox --help` 的**唯一真相源**。

## 签名

```
winbox [全局选项] <command> [command 选项]
```

全局选项（对所有命令生效）：

| 选项 | 语义 | 默认 |
| --- | --- | --- |
| `-c, --config FILE` | 使用指定配置文件 | `config/win-box.conf` |
| `-n, --dry-run` | 只打印将执行的系统改动，不落盘 | off |
| `-y, --yes` | 不交互确认（脚本化用） | off |
| `-q, --quiet` | 只输出错误 | off |
| `-v, --verbose` | 打印每条被执行的底层命令 | off |
| `--no-color` | 关闭颜色（日志/CI） | off |
| `-h, --help` / `--version` | 帮助 / 版本 | — |

**失败语义**（全局）：退出码见 `00-overview.md`；每个命令在失败时**必须**给出 `<stage> + 原因 + 文档锚点`。

---

## 命令清单

### 探测与状态（只读，不需要 root）

#### `winbox detect [--write]`

- **输入**：无（自动探测 IOMMU、AMD 核显 VGA/音频功能、BDF、IOMMU 分组、KVMFR/ivshmem 现状、libvirt 与 OVMF 可用性、Looking Glass submodule 是否存在）
- **输出**：stdout 打印探测结果表；`--write` 时写入配置文件（原子写，先备份 `win-box.conf.bak`）
- **失败**：码 4 = 未发现 AMD 核显（附 `lspci -nn` 里 class 0x030000 的候选列表供人工判断）
- **生命周期**：可重复执行；不产生任何系统改动（除 `--write` 的配置写入）

#### `winbox conf [KEY[=VALUE]]`

- **输入**：无参 = 打印全部配置与来源（默认/文件/环境）；`KEY` = 打印单键；`KEY=VALUE` = 写回配置文件
- **输出**：stdout
- **失败**：码 2 = KEY 未知；码 3 = 配置文件不可写
- **生命周期**：读路径纯查询；写路径幂等（同值重写不产生变更）

#### `winbox adopt [VM_NAME]`

- **输入**：要接管的虚拟机名（默认用配置里的 `WB_VM_NAME`）
- **输出**：把该 VM 的**身份信息**提取到配置——名称/UUID/内存/vCPU/机器类型/SecureBoot/OVMF/nvram/磁盘/ISO/MAC/网络，以及核显 BDF 与 ROM 路径、视频型号与 x-vga、共享内存开关与尺寸、root port 与客机侧地址
- **失败**：码 3 = VM 不存在或读不到定义
- **生命周期**：**只读**（不碰域定义，只读 `dumpxml`）；提取结果写入配置（受 `--dry-run` 控制）
- **为什么需要**：本项目用模板渲染而不是就地编辑 XML；对已有 VM，模板必须先知道它的身份参数，否则重定义会把磁盘/网络/NVRAM 换掉

> `adopt` 之后不要再用 `virsh edit`：手工改动会在下一次渲染时被覆盖。
> 要改结构就改 `config/templates/domain.xml.in`（或复制为 `config/domain.local.xml` 后改），再 `winbox vm redeploy`。

#### `winbox status [--host|--guest|--lg] [--json] [--quiet]`

- **输入**：可选的检查面过滤；`--json` 输出机器可读结果；`--quiet` 只输出 JSON/结论
- **输出**：分段报告（✓/✗/⚠/· 逐项）+ 结论行 `RESULT: OK|DEGRADED|BROKEN（计数）`；报告走 **stdout**（它是这条命令的产物）
- **失败**：**退出码即结论**——`0` = OK（全 ✓）、`6` = DEGRADED（有 ⚠ 无 ✗）、`7` = BROKEN（有 ✗）、`1` = 检查本身无法执行（如缺 virsh）。**注意**：因退出码承载结论，在 `set -e` 的脚本里串联时需显式处理（`winbox status || true`）
- **生命周期**：纯只读；不需要 root；可在虚拟机运行中/停止时调用

#### `winbox evidence [--out DIR] [--after]`

- **输入**：输出目录（默认 `logs/evidence-<时间戳>/`）；`--after` = VM 关闭后的补采
- **输出**：一组文本文件（宿主机 GPU/IOMMU/dmesg/libvirt XML/ROM 指纹/客机报告……）+ `manifest.txt`（文件清单与 sha256）
- **失败**：码 1 = 目录不可写（与 `status` 不同，`evidence` **不**用退出码承载采集内容）
- **生命周期**：只读采集；采集 `dmesg` 需要 root（缺 root 时跳过该项并标 ⚠，不失败）

### 阶段流程（mutating；标注 sudo 的需 root）

#### `winbox host-prep [--skip-deps]`

- **输入**：`--skip-deps` 跳过 apt 安装（只做 vfio/initramfs/内核参数/用户组）
- **输出**：六步——依赖 → libvirtd 与默认网络/存储池 → vfio 模块配置（`ids=` + `softdep` + 黑名单）→
  initramfs 模块表（把 amdgpu 拿掉、把 vfio 四件套补齐）→ 内核参数（IOMMU + 关宿主 framebuffer）→ 用户组
- **失败**：码 3 = 非 root（除非 `--dry-run`）/ 缺 dpkg·apt-get·update-initramfs / 读不到核显 ID；
  码 1 = apt·update-initramfs·update-grub 失败；**码 5 = 改动涉及内核参数或 initramfs，必须重启宿主**
- **sudo**：真跑需 root；**`--dry-run` 不需要 root**（只读检查 + 打印将写入的内容）
- **生命周期**：幂等——已配好的机器上跑它应报“无需改动”且**不要求重启**

#### `winbox vm-create [--name N] [--memory MB] [--vcpus N] [--disk GB] [--iso PATH] [--disk-path P] [--reuse-disk]`

- **输入**：规格参数（默认值来自配置）；`--disk-path` 指定磁盘位置（默认 `/var/lib/libvirt/images/<名字>.qcow2`）
- **输出**：生成身份（UUID/MAC 写入配置）→ 创建 qcow2 磁盘 → 从模板渲染并 `virsh define`
  （初始形态固定为 `inspect`：QXL + SPICE，装系统时**看得见**；不挂核显、不挂共享内存）
- **失败**：码 2 = VM 名已存在（**不幂等，绝不覆盖或删除**）/ 磁盘已存在（除非 `--reuse-disk`）；
  码 3 = 缺 virsh·qemu-img / OVMF 文件不存在 / ISO 不存在；码 5 = 配置里已有别的 VM 而用户在确认时拒绝
- **生命周期**：**终点是码 5**——装 Windows 本身是人工步骤，命令不假装成功
- **引导顺序**：模板里磁盘 `order=1`、光驱 `order=2`。空盘时 UEFI 自动落到光驱装系统，
  装完盘能直接启动——**不需要想起来去 eject**（旧流程的经典坑）

#### `winbox gpu-attach [--rom FILE] [--audio-rom FILE] [--mode test|inspect|lg|both] [--detach]`

- **输入**：ROM 路径（默认取 `WB_VBIOS_DIR` 里配置的 ROM）、显示模式、`--detach`
- **输出**：ROM 部署到 `WB_VBIOS_DIR`（sha256 校验）→ 写配置键 → 从模板重定义域定义（含专属 root port + 双功能 hostdev + ROM + 显示模式）
- **失败**：码 3 = VM 运行中 / ROM 不存在 / 非 root 且需部署；码 4 = 配置的核显 BDF 在当前硬件上不存在
- **生命周期**：幂等（模板渲染天然幂等）；改前自动备份 XML 到 `logs/`，改后打印前后 diff

#### `winbox lg-prepare [--size MB] [--skip-deps] [--skip-kvmfr] [--skip-build]`

- **输入**：共享内存大小（默认 `WB_SHM_SIZE_MB`）、跳过开关
- **输出**：构建依赖 → KVMFR 模块（DKMS + 模块参数 + 开机加载 + udev 权限）→ 构建客户端到 `$HOME/.local/bin`
- **失败**：码 3 = submodule 未初始化 / 缺构建依赖；码 1 = DKMS 或编译失败
- **sudo**：前两步需 root，**构建不需要** —— 非 root 时自动跳过前两步（明确告知），而不是整个失败
- **生命周期**：幂等（依赖逐包检查、已构建的客户端不重建）

#### `winbox lg-shmem [--size MB] [--remove]`

- **输入**：大小、是否移除
- **输出**：写 `WB_SHMEM_ENABLED`/`WB_SHM_SIZE_MB` + 从模板重定义域定义（共享内存片段 = `qemu:commandline` 里的 ivshmem-plain + memory-backend-file）
- **失败**：码 3 = VM 运行中 / `/dev/kvmfr0` 不是字符设备
- **生命周期**：幂等（渲染即全量重建）

#### `winbox reset-hook <install|remove|test>`

- **输入**：动作
- **输出**：`/etc/libvirt/hooks/qemu.d/<vm>/prepare/begin/10-*.sh` 与日志 `/var/log/winbox-reset.log`
- **失败**：码 3 = 非 root；`test` 时若 amdgpu 未能绑定 → 码 5（提示需冷启动）
- **生命周期**：幂等；钩子本体**永远 exit 0**（绝不阻塞 VM 启动）

#### `winbox lg [--idd-prefs|--idd-show|--ini-reset] [客户端参数…]`

- **输入**：透传给 Looking Glass 客户端的参数；两个特殊开关：
  `--idd-prefs` = 只应用客机 IDD 偏好（ExclusiveMonitor=0 / ForceIndirectCopy=1 / ForceFullDirectCopy=0 + 重载驱动）；
  `--ini-reset` = 强制重写 `client.ini`
- **输出**：前台窗口（Ctrl+C 结束）
- **失败**：码 3 = 客户端未构建 / 无 SSH 通道（仅 `--idd-prefs` 时）
- **生命周期**：前台进程；首次运行生成 `~/.config/looking-glass/client.ini`（已存在**不覆盖**——使用者手改的配置不能被脚本重置）

#### `winbox rom <子命令>`

见 `03-romtool.md`（C 工具 `romtool` 的 CLI 契约）。`winbox rom …` 是薄包装：
路径解析（裸文件名按 `WB_VBIOS_DIR` 解释）、按需自动构建、`dump` 的 root 前置检查；
其余参数原样透传，包装层不重新实现任何 ROM 逻辑。

| 子命令 | 用途 |
| --- | --- |
| `build` | 构建 romtool（首次使用会自动构建） |
| `info FILE [--json]` | 结构报告 + ATOM/横幅 + SHA256 |
| `verify [--strict] FILE` | 结构校验（致命）+ 校验和（默认仅警告） |
| `patch --vendor --device [--class] [--fix-checksum] [--dry-run] IN OUT` | 盖 ID |
| `merge --vbios A [--gop B] OUT` | 合并 legacy VBIOS 与 GOP 镜像 |
| `dump --bdf … OUT` | 提取本机设备 ROM（需 root） |
| `extract --from BIOS.IMG [--list] [--index N] OUT` | 在 BIOS 镜像里扫 ROM 候选 |

#### `winbox host-gpu [status|passthrough|host] [--takeover]`

宿主核显姿态开关。**姿态只看持久化配置**（不看"此刻绑在哪个驱动"，那属于细节）：

| 姿态 | `/etc/modprobe.d` | initramfs | 核显驱动 |
| --- | --- | --- | --- |
| `passthrough` | `options vfio-pci ids=…` + `softdep amdgpu pre: vfio-pci` + 黑名单 | amdgpu 已移除、vfio 三件套在 | `vfio-pci` |
| `host` | 以上全部撤掉 | 重建（否则早期启动仍按旧 modprobe.d 挡 amdgpu） | `amdgpu` |
| `mixed` | 只有其中一项 | — | 视情况 —— **语义不完整**，`status` 会报 bad |

- **输入**：动作（默认 `status`）；`--takeover` = 把**别人文件里**的直通配置注释掉（改前备份 + 逐条打印，带
  `# win-box host-gpu --takeover:` 标记）
- **输出**：`status` 打印 `mode / desired / blacklisted / vfio_ids / softdep / driver / amdgpu_loaded / framebuffer_in_use`；
  切换做两件事：**持久化配置**（modprobe.d + initramfs）与**立即生效**（当前会话的绑定）
- **失败**：码 2 = 动作非法；码 3 = 非 root（真跑）/ VM 正在运行 / 有冲突而未给 `--takeover` / 未配置 BDF；
  **码 5 = 持久化有改动（需要重启）**，或用户在"核显正被宿主使用"的确认处取消
- **生命周期**：幂等——没有持久化改动时退出 0 且**不要求重启**；两个方向的"当前会话"部分也幂等（已在该驱动上就跳过）
- **为什么"只删黑名单"不够**、**为什么内核参数不用动**：见 `04-lib-api.md` 的 `lib/host.sh` 一节

### 运维转发

#### `winbox vm <子命令>`

等价于 `vmctl <子命令>`（见 `02-vmctl.md`）。保留 `vmctl` 作为独立可执行文件，方便直接使用。
子命令包含日常运维（list/status/start/shutdown/snapshot…）与模板驱动的域定义操作（render/redeploy/verify/mode/template-path）。

---

## 附一：vm 定义的真相源是模板，不是 `virsh edit`

```
config/templates/domain.xml.in          完整域骨架（含 ${WB_*} 占位符）
config/templates/fragment/*.xml.in      形态片段（视频 / 固件 / 直通 / 共享内存 / x-vga / 光驱）
config/domain.local.xml                 可选：用户改过的骨架副本（优先于仓库模板）
```

所有改 VM 结构的命令（`gpu-attach` / `lg-shmem` / `vm mode` / `vm redeploy`）都是**同一个动作**：
改配置键 → 渲染模板 → 备份 → `virsh define` → 回读校验 → 打印前后 diff。
因此没有“只改了一半”的中间态，也不需要 XML 编辑工具。

---

## 附：函数库的可见性

`winbox` 只暴露上表命令。**函数库不是命令行接口**——它是给「场景 4 单点重放」和脚本作者用的（`source scripts/lib/pci.sh` 后直接调用 `wb_pci_bind`）。函数契约见 `04-lib-api.md`。
