# 接口契约：函数库 API

> 形式：bash 函数库（`source`）。这是**场景 4「单点重放」的对外接口**，也是所有 L2 长流程封装的公共基石。
> 使用者可以只 source 一个文件并调用一个函数，**不依赖任何脚本的执行历史**。

## 库分层（依赖只允许向下）

```
report.sh ─┐
guest.sh ──┤
lg.sh ─────┤
hook.sh ───┼─→ xml.sh ─→ virsh 之上
gpu.sh ────┤     ↑
pci.sh ────┼─────┘
detect.sh ─┤
sys.sh ────┤
conf.sh ───┤
log.sh ────┘        （log 不被任何库依赖其状态，只输出）
```

每个文件可独立 `source`（内部自动 source 其依赖，重复 source 幂等：用 `WB_LIB_<NAME>_LOADED` 守卫）。

**统一约定**：函数名前缀 `wb_`；命名 `wb_<域>_<动>`；纯查询函数用 **stdout 只输出结果**（日志走 stderr），便于 `x=$(wb_pci_driver "$bdf")`。

---

## `lib/log.sh` — 输出

| 函数 | 签名 | 语义 |
| --- | --- | --- |
| `wb_log` | `wb_log MSG…` | 普通信息 → stderr |
| `wb_step` | `wb_step "1/3" "描述"` | 阶段标题（带颜色，`--no-color` 时降级） |
| `wb_ok` / `wb_warn` | `wb_ok MSG` / `wb_warn MSG` | 成功 / 警告行 |
| `wb_fail` | `wb_fail CODE STAGE MSG [DOC]` | **打印标准错误行并 exit CODE**（唯一允许 exit 的函数） |
| `wb_run` | `wb_run CMD…` | 执行命令；`--dry-run` 时只打印；`--verbose` 时同时回显 |
| `wb_write` | `wb_write FILE VALUE` | 向文件写值（sysfs 等）的 `wb_run` 对应物；失败返回 1 而不退出，由调用方决定严苛程度 |

`wb_fail` 的输出格式固定（`00-overview.md` 定义），这是**所有失败信息的唯一出口**。

## `lib/conf.sh` — 配置（唯一环境变量/文件读取入口）

| 函数 | 签名 | 出参 | 失败 |
| --- | --- | --- | --- |
| `wb_conf_load` | `wb_conf_load [FILE]` | 载入到内存（关联数组），返回 0 | 码 3 = 文件存在但语法错误 |
| `wb_conf_get` | `wb_conf_get KEY` | stdout = 值 | 码 3 = 键未定义（**不返回空串**） |
| `wb_conf_get_default` | `wb_conf_get_default KEY DEFAULT` | stdout = 值或默认值 | 永不失败 |
| `wb_conf_set` | `wb_conf_set KEY VALUE` | 原子写回文件（temp+rename，保留注释） | 码 3 = 不可写 |
| `wb_conf_require` | `wb_conf_require KEY…` | 全存在则 0 | 码 3 = 列出缺失键并提示 `winbox detect` |
| `wb_conf_dump` | `wb_conf_dump [--json]` | 全键 + 来源（default/file/env/cli） | — |

**纪律**：业务代码**禁止**直接读环境变量（`$WB_*` 也禁止）——一律经 `wb_conf_get`。

### 配置键（`config/win-box.conf`）

| 键 | 含义 | 默认 | 由谁写 |
| --- | --- | --- | --- |
| **硬件** | | | |
| `WB_GPU_BDF` | 核显 VGA 功能 PCI 地址 | 探测 | `detect --write` |
| `WB_AUDIO_BDF` | 核显 HDMI 音频功能 | 探测 | `detect --write` |
| `WB_GPU_ID` | `vendor:device` | 探测 | `detect --write` |
| `WB_AUDIO_ID` | 音频功能 `vendor:device` | 探测 | `detect --write` |
| `WB_IOMMU_GROUP` | 核显所在 IOMMU 组 | 探测 | `detect --write` |
| **ROM** | | | |
| `WB_VBIOS_DIR` | ROM 部署目录 | `/var/lib/libvirt/vbios` | 用户 / `gpu-attach` |
| `WB_VBIOS_GPU` | VGA 功能 ROM 文件名 | — | `gpu-attach` / `adopt` |
| `WB_VBIOS_AUDIO` | 音频功能 ROM 文件名 | — | `gpu-attach` / `adopt` |
| **VM 身份**（模板渲染必需） | | | |
| `WB_VM_NAME` | 虚拟机名 | `win11` | 用户 / `adopt` |
| `WB_VM_UUID` | 域 UUID（必须固定：变了等于换机，Windows 可能重新激活） | — | `adopt` / `vm-create` |
| `WB_VM_MEMORY_MB` | 内存 | `16384` | 用户 / `adopt` |
| `WB_VM_VCPUS` | vCPU 数（同时也是拓扑 cores） | `8` | 用户 / `adopt` |
| `WB_VM_DISK` | 系统盘文件路径 | — | `adopt` / `vm-create` |
| `WB_VM_ISO` | 安装镜像（空 = 不挂光驱） | 空 | 用户 |
| `WB_VM_MAC` | 网卡 MAC（固定：变了客机会当新网卡） | — | `adopt` / `vm-create` |
| `WB_VM_NETWORK` | 网络名 | `default` | 用户 |
| `WB_VM_NVRAM` | NVRAM 文件路径 | — | `adopt` / `vm-create` |
| `WB_MACHINE` | 机器类型 | `q35` | 用户（接管现有 VM 时沿用原值） |
| `WB_VM_SECUREBOOT` | Secure Boot（1/0） | `0` | 用户 |
| `WB_OVMF_CODE` / `WB_OVMF_VARS` | OVMF 固件与变量模板路径 | Ubuntu 默认路径 | 用户 / `adopt` |
| **形态开关**（决定模板用哪些片段） | | | |
| `WB_VIDEO_MODE` | `test` / `lg` / `inspect` / `both` | `lg` | `vm mode` / `adopt` |
| `WB_GPU_ATTACHED` | 是否挂核显（1/0） | `0` | `gpu-attach` / `adopt` |
| `WB_SHMEM_ENABLED` | 是否挂共享内存（1/0） | `0` | `lg-shmem` / `adopt` |
| `WB_ROOTPORT_INDEX` / `WB_ROOTPORT_CHASSIS` / `WB_ROOTPORT_PORT` | 专属 root port 参数 | `15` / `15` / `0x0` | 用户 |
| `WB_IGPU_GUEST_BUS` / `WB_IGPU_GUEST_SLOT` | 客机侧 PCI 地址（与 root port 成对） | `0x0f` / `0x00` | 用户 |
| **Looking Glass** | | | |
| `WB_SHM_SIZE_MB` | KVMFR 共享内存（必须与模块参数一致） | `128` | 用户 |
| `WB_LG_SRC` | 客户端源码目录 | `third_party/LookingGlass` | 用户 |
| `WB_LG_CLIENT` | 客户端二进制路径 | — | 用户 |
| **客机通道 / 复位** | | | |
| `WB_GUEST_USER` / `WB_GUEST_HOST` | 客机 SSH（空 = 相关检查降级为 ⚠ 并跳过） | 空 | 用户 |
| `WB_REBOOT_WAIT` | 复位时等 amdgpu 初始化的秒数 | `30` | 用户 |

## `lib/sys.sh` — 环境守卫

| 函数 | 语义 | 失败 |
| --- | --- | --- |
| `wb_require_root MSG` | 非 root 时 `wb_fail 3` 并给出 `sudo` 命令 | 码 3 |
| `wb_require_cmd CMD…` | 缺命令时 `wb_fail 3` 并给出安装命令 | 码 3 |
| `wb_have_cmd CMD` | 返回 0/1（**不打印**） | — |
| `wb_require_file PATH…` | 缺文件 → 码 3 | 码 3 |
| `wb_is_dry_run` / `wb_is_yes` | 布尔查询 | — |

## `lib/detect.sh` — 硬件探测（只读）

| 函数 | 出参（stdout） | 说明 |
| --- | --- | --- |
| `wb_detect_display_devices` | 每行 `<BDF> <VENDOR:DEVICE> <CLASS>` | 全部显示类设备（不限厂商） |
| `wb_detect_igpu [BDF]` | 首行 `vga <BDF> <CLASS> <V:D> <BAR>`，次行 `audio …`（若有同槽音频） | 启发式选核显（评分：同槽 HDMI 音频 +2、BAR 合计 <4G +2）；无候选 → **码 4**；多候选同分 → **码 4** 并列出候选；给出 BDF 时直接验证该设备 |
| `wb_detect_audio_sibling BDF` | 同槽 `.1` 的音频 BDF | 无则返回 1（不打印） |
| `wb_detect_bar_total BDF` | 全部 BAR 合计字节数 | 读 `/sys/.../resource` |
| `wb_detect_human_size BYTES` | `258M` 这类可读值 | 纯格式化 |
| `wb_detect_iommu` | `enabled\|disabled` | 读 `/sys/kernel/iommu_groups` |
| `wb_detect_iommu_count` | 分组数 | — |
| `wb_detect_iommu_group BDF` | 组号 | 码 4 = 设备无组 |
| `wb_detect_iommu_peers BDF` | 同组其它设备（每行一个） | 空输出 = 独占 |
| `wb_detect_vbios_roms [BDF]` | 已部署 ROM 的文件名 | 在 `WB_VBIOS_DIR` 中枚举，不做 ID 匹配（那需要解析 ROM） |
| `wb_detect_submodules` | `ok\|missing:…` | `third_party/` 是否已初始化 |
| `wb_detect_libvirt_tools` | `ok\|missing:…` | virsh/virt-install/qemu-system-x86_64 可用性 |

**探测即契约**：`detect` 的输出格式是对外承诺——`--json` 与文本共用同一份字段。

## `lib/pci.sh` — PCI 设备操作（**有副作用**，需 root 才能成功）

| 函数 | 语义 | 失败 | 幂等 |
| --- | --- | --- | --- |
| `wb_pci_driver BDF` | stdout 驱动名或 `(none)` | 永不失败 | — |
| `wb_pci_override BDF DRIVER` | 写 `driver_override` | 码 1 | ✅ |
| `wb_pci_override_clear BDF` | 清空 `driver_override` | 码 1 | ✅ |
| `wb_pci_unbind BDF` | 从当前驱动解绑（写设备名，**不是驱动名**） | 码 1 | ✅（未绑定直接 0） |
| `wb_pci_probe BDF` | 写 `drivers_probe` 触发重新探测 | 码 1 | ✅ |
| `wb_pci_bind BDF DRIVER` | 绑定到指定驱动 | 码 1 | ✅ |
| `wb_pci_wait_driver BDF DRIVER TIMEOUT` | 轮询等待 | 码 1 = 超时 | — |

**三个内核陷阱用函数封装固化**（这是本项目的核心经验之一）：
1. `driver_override` 必须在 unbind **之前**写，否则 `vfio-pci ids=` 会瞬间抢回；
2. unbind 之后内核**不会自动 probe**，必须显式写 `drivers_probe`；
3. `unbind` 文件里要写**设备名**（`0000:0d:00.0`），不是驱动名。

## `lib/gpu.sh` — 核显专用（真复位轮回等）

#### `wb_gpu_reset_cycle [--wait SECONDS]`
- **输入**：`--wait` 覆盖配置里的等待秒数
- **输出**：日志到 stderr + `/var/log/winbox-reset.log`（钩子复用同一函数）
- **失败**：码 5 = amdgpu 未能绑定（通常意味着需要冷启动宿主）；**不返回码 1 的中间失败**——每一步的失败都降级为"跳过"，判定只在最后
- **生命周期**：`MODE2 reset` 由内核在 unbind 时触发；函数结束状态 = 两个功能都回到 `vfio-pci`
- **关键约束**：**永不阻塞上层**。被 libvirt 钩子调用时，函数内部异常也必须让钩子 `exit 0`

| 其他函数 | 语义 |
| --- | --- |
| `wb_gpu_deploy_rom SRC DST` | 安装 ROM 到 `WB_VBIOS_DIR`，设 owner `libvirt-qemu:kvm`、mode 644，**校验 sha256 后打印指纹** |
| `wb_gpu_rom_fingerprint FILE` | stdout = `sha256前16位 大小 路径` |
| `wb_gpu_bind_vfio` | 两个功能绑到 vfio-pci（= `wb_pci_bind` ×2，带前置检查） |

## `lib/xml.sh` — 域定义（**模板渲染**）

**这一节是项目最重要的架构决策**：域定义不"就地编辑"，而是**从模板渲染**。

```
config/templates/domain.xml.in           完整域骨架（含 ${WB_*} 占位符）
config/templates/fragment/*.xml.in       形态片段（视频/固件/直通/共享内存/x-vga/光驱）
config/domain.local.xml                  可选：用户改过的骨架副本（优先级高于仓库模板）
```

**为什么**：Libvirt 域 XML 极难用 shell 可靠地改写（需要 xmlstarlet 或 python），而本项目只允许 bash + C。
模板渲染把"改 XML"变成"纯文本替换"，于是：不需要 XML 工具、不需要 Python、**且可以完全离线验证**
（测试用 `xmllint --relaxng /usr/share/libvirt/schemas/domain.rng` 跑 libvirt 自己的 schema）。

代价（已接受并写入文档）：**手工 `virsh edit` 的改动会被下一次渲染覆盖**。
改结构请改模板文件，然后 `winbox vm redeploy`。

| 函数 | 语义 | 失败 |
| --- | --- | --- |
| `wb_xml_template_path` | stdout = 模板路径（`$WB_XML_TEMPLATE` > `config/domain.local.xml` > 仓库模板） | — |
| `wb_xml_fragment_path NAME` | stdout = 片段路径 | — |
| `wb_xml_vars_init` | 构造变量表（环境变量 > 配置 > 内置默认），推导 BDF 分量与共享内存字节数；缺 VM 身份 → 码 3 | 码 3 |
| `wb_xml_prepare_fragments` | 按 `WB_VIDEO_MODE` / `WB_VM_SECUREBOOT` / `WB_GPU_ATTACHED` / `WB_SHMEM_ENABLED` / `WB_VM_ISO` 选出片段并渲染到 `WB_XML_FRAGMENT_*` | 码 2/3 |
| `wb_xml_render [TEMPLATE] [NAME=VALUE…]` | stdout = 渲染结果；严格模式：未知占位符、含 `& < > " '` 的值都报错 | 码 3 |
| `wb_xml_render_fragment NAME` | 渲染单个片段（空名 → 空输出） | 码 3 |
| `wb_xml_render_file TEMPLATE OUT` | 渲染到文件（temp+rename；受 `--dry-run` 控制） | 码 3 |
| `wb_xml_dump [FILE]` | stdout = 备份文件路径（默认 `logs/<时间戳>-<vm>-<操作>.xml`）；**改动前必调** | 码 3 |
| `wb_xml_require_stopped` | VM 必须 `shut off`（否则码 3）；VM 不存在也是码 3 | 码 3 |
| `wb_xml_define FILE` | `virsh define`；被拒绝 → 码 1（渲染结果不合法） | 码 1 |
| `wb_vm_redeploy REASON` | **唯一的"改 XML"入口**：快照警告与确认 → 备份 → 渲染 → define → 回读 → 打印前后 diff | 码 1/3/5 |
| `wb_vm_verify_xml` | `domxml-to-native qemu-argv` 回读，检查 vfio 设备数 / `x-vga=on` / `vga=none` / ivshmem | 码 3 |
| `wb_vm_set_video_mode test\|inspect\|both\|lg` | 写 `WB_VIDEO_MODE` + 重定义（= 换片段） | 码 2 |
| `wb_vm_attach_igpu ROM AUDIO_ROM` / `wb_vm_detach_igpu` | 写 ROM 键 与 `WB_GPU_ATTACHED` + 重定义 | 码 3 |
| `wb_vm_attach_shmem [SIZE_MB]` / `wb_vm_detach_shmem` | 写 `WB_SHMEM_ENABLED`（+ 尺寸）+ 重定义 | 码 3 |

**形态矩阵**（片段选择的唯一真相）：

| `WB_VIDEO_MODE` | 视频片段 | x-vga | 用途与判据 |
| --- | --- | --- | --- |
| `test` | `video-none` | on | 核显是 Primary GPU；判据是**物理显示器** |
| `lg` | `video-none` | off | 核显是非启动显示适配器（避开 `0xC01E0438`）；Look. Glass 的正确形态 |
| `inspect` | `video-qxl` | off | QXL：在 SPICE 窗口里看客机内部（设备管理器/事件查看器） |
| `both` | `video-qxl` | on | 双显示（实验组合） |

## `lib/lg.sh` — Looking Glass 宿主侧

| 函数 | 语义 | 失败 |
| --- | --- | --- |
| `wb_kvmfr_install SIZE_MB` | DKMS 安装 kvmfr + 写模块参数/开机加载/udev 规则 | 码 3 = VM 运行中 |
| `wb_kvmfr_check` | 检查 `/dev/kvmfr0` 存在且**是字符设备**（QEMU 误建普通文件是已知坑） | 码 3 |
| `wb_lg_build SRC` | 从 submodule 源码构建客户端，产物 → `WB_LG_CLIENT` | 码 3 = 缺构建依赖 |
| `wb_lg_run [args…]` | 前台运行客户端；首次生成 `client.ini` | 码 3 = 未构建 |
| `wb_lg_client_ini_write` | 写默认 `client.ini`（lgmp + DMA + 分辨率策略） | 已存在则不覆盖（除非 `--force`） |
| `wb_idd_prefs_apply` | 经客机 SSH 改 IDD 注册表偏好并重载驱动 | 码 3 = 无 SSH 通道 |

## `lib/guest.sh` — 客机交互（经 SSH）

| 函数 | 语义 | 失败 |
| --- | --- | --- |
| `wb_guest_ready` | 返回 0/1（**不打印**），用于跳过而非失败 | — |
| `wb_guest_ps PS_COMMAND` | PowerShell 执行，UTF-8 安全，stdout 返回 | 码 3 = 未配置/不可达 |
| `wb_guest_put LOCAL REMOTE` | 投递文件（HTTP 或 scp，由实现选择） | 码 1 |
| `wb_guest_gpu_status` | stdout = `Status/ConfigManagerErrorCode/DriverVersion` | 码 3 |
| `wb_guest_idd_status` | stdout = IDD 版本与工作模式 | 码 3 |

**纪律**：所有客机交互**必须先 `wb_guest_ready`**——没有通道时相关检查降级为 ⚠ 并跳过，**不得把「没配 SSH」当作系统故障**。

## `lib/report.sh` — 报告（`status` / `evidence` 共用）

| 函数 | 语义 |
| --- | --- |
| `wb_report_section TITLE` | 起一节 |
| `wb_report_item ok\|bad\|warn\|info TEXT [HINT]` | 一条检查项；`--json` 模式下写结构化缓冲 |
| `wb_report_result` | 收尾：打印 `RESULT: OK\|DEGRADED\|BROKEN`，**返回** 0/6/7（返回值，不自己 exit——由 L1 命令决定是否把结论变退出码；`evidence` 等命令拿到值后忽略） |
| `wb_evidence_manifest DIR` | 生成清单 + sha256 |

**判定规则**：任一 `bad` → `BROKEN`；只有 `warn` → `DEGRADED`；全 `ok` → `OK`。

---

## 附：本契约不做的事

- 不定义内部数据结构（bash 关联数组的键名是实现自由）
- 不定义拆分粒度与文件内顺序
- 不写单元测试（bash 不自带测试框架；靠 `winbox status` + `--dry-run` 做验收）
- 不定义性能指标（本项目的瓶颈在 I/O 与人工，不在 CPU）
