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

#### `winbox status [--host|--guest|--lg] [--json]`

- **输入**：可选的检查面过滤
- **输出**：分段报告（✓/✗/⚠ 逐项）+ 结论行 `RESULT: OK|DEGRADED|BROKEN`；`--json` 输出同构的 JSON
- **失败**：**退出码即结论**——`0` = OK（全 ✓）、`6` = DEGRADED（有 ⚠ 无 ✗）、`7` = BROKEN（有 ✗）、`1` = 检查本身无法执行（如 libvirt 连不上）。**注意**：因退出码承载结论，在 `set -e` 的脚本里串联时需显式处理（`winbox status || true`）
- **生命周期**：纯只读；不需要 root；可在虚拟机运行中/停止时调用

#### `winbox evidence [--out DIR] [--after]`

- **输入**：输出目录（默认 `logs/evidence-<时间戳>/`）；`--after` = VM 关闭后的补采
- **输出**：一组文本文件（宿主机 GPU/IOMMU/dmesg/libvirt XML/ROM 指纹/客机报告……）+ `manifest.txt`（文件清单与 sha256）
- **失败**：码 1 = 目录不可写（与 `status` 不同，`evidence` **不**用退出码承载采集内容）
- **生命周期**：只读采集；采集 `dmesg` 需要 root（缺 root 时跳过该项并标 ⚠，不失败）

### 阶段流程（mutating；标注 sudo 的需 root）

#### `winbox host-prep`

- **输入**：无
- **输出**：apt 依赖、libvirtd、vfio 模块配置、initramfs 清理（移除 amdgpu）、内核参数、用户组
- **失败**：码 3 = distro 不在支持列表 / 缺 apt
- **生命周期**：幂等；执行后**可能需要重启** → 若检测到需要重启，打印提示并以 **码 5** 退出（区别于失败）
- **依赖**：`lib/sys.sh` `lib/detect.sh`

#### `winbox vm-create [--name N] [--memory MB] [--vcpus N] [--disk GB] [--iso PATH]`

- **输入**：规格参数（默认值来自配置）
- **输出**：一条 libvirt domain（UEFI + SecureBoot + TPM2 + q35）
- **失败**：码 3 = 缺 ovmf/swtpm/virt-install；码 2 = VM 名已存在
- **生命周期**：**不幂等**（重名拒绝而非覆盖）；安装系统本身是人工步骤（打印操作指引）

#### `winbox gpu-attach [--rom FILE] [--audio-rom FILE] [--mode test|inspect|lg|both] [--detach]`

- **输入**：ROM 路径（默认取 `WB_VBIOS_DIR` 里配置的 ROM）、显示模式、`--detach`
- **输出**：ROM 部署到 `WB_VBIOS_DIR`（sha256 校验）→ 写配置键 → 从模板重定义域定义（含专属 root port + 双功能 hostdev + ROM + 显示模式）
- **失败**：码 3 = VM 运行中 / ROM 不存在 / 非 root 且需部署；码 4 = 配置的核显 BDF 在当前硬件上不存在
- **生命周期**：幂等（模板渲染天然幂等）；改前自动备份 XML 到 `logs/`，改后打印前后 diff

#### `winbox lg-prepare [--size MB]`

- **输入**：共享内存大小（默认 128）
- **输出**：DKMS 装 kvmfr、模块参数/开机加载/udev 权限、从 submodule 源码构建客户端到 `~/.local/bin`
- **失败**：码 3 = submodule 未初始化（提示 `git submodule update --init`）；码 1 = 构建失败
- **生命周期**：幂等；**拒绝在 VM 运行中执行**（QEMU 会把 `/dev/kvmfr0` 创造成普通文件，事后难修）

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

#### `winbox lg [--] [客户端参数…]`

- **输入**：透传给 Looking Glass 客户端的参数
- **输出**：前台窗口（Ctrl+C 结束）
- **失败**：码 3 = 客户端未构建 / `/dev/kvmfr0` 不存在
- **生命周期**：前台进程；首次运行生成 `~/.config/looking-glass/client.ini`（已存在则不覆盖）

#### `winbox rom <子命令>`

见 `03-romtool.md`。`winbox rom …` 是 `romtool` 的薄包装（路径解析 + 配置注入），行为与直接调用 `romtool` 一致。

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
