# 架构

> 本文回答四个问题：**数据怎么流**、**状态怎么变**、**模块怎么分**、**哪些约束不能碰**。
> 接口细节在 `docs/interfaces/`，实战过程在 `docs/zh/`。

## 1. 拓扑

```
┌────────────────────────────── 宿主（Ubuntu + KVM/libvirt）──────────────────────────────┐
│                                                                                        │
│  核显 0000:0d:00.0 (VGA)  ─┐                                                           │
│         0000:0d:00.1 (HDMI音频) ─┤  直通（vfio-pci 持有，QEMU 打开）                    │
│                                                                 │                      │
│  ┌──────────────────────────────┼──────────────────────────────┼───────────────────┐  │
│  │  QEMU / libvirt 域（模板渲染而来）                             │                   │  │
│  │   • 专属 pcie-root-port（index 15）→ 客机侧 bus 0x0f          │                   │  │
│  │   • hostdev ×2（VGA + 音频，各带 ROM）                        │                   │  │
│  │   • video=none（无虚拟显卡）                                  │                   │  │
│  │   • qemu:override → x-vga（按显示模式开关）                    │                   │  │
│  │   • qemu:commandline → ivshmem-plain ← /dev/kvmfr0 ───────────┼────┐              │  │
│  │                                                              │    │              │  │
│  │   ┌──────────────── 客机 Windows 11 ────────────────┐        │    │              │  │
│  │   │  AMD 驱动（离线安装）                            │        │    │              │  │
│  │   │  ├─ 核显：可用（lg/test 模式决定是否 Primary）    │        │    │              │  │
│  │   │  └─ Looking Glass IDD（虚拟显示器 + 输入）        │        │    │              │  │
│  │   │      桌面渲染在 IDD 上 → 帧写进共享内存 ─────────┼────────┼────┤              │  │
│  │   │  OpenSSH Server（控制面） ←──── ssh ─────────────┼────────┼────┼──┐           │  │
│  │   └──────────────────────────────────────────────────┘        │    │  │           │  │
│  └───────────────────────────────────────────────────────────────┼────┼──┼───────────┘  │
│                                                                  │    │  │              │
│  KVMFR 内核模块：/dev/kvmfr0 ── mmap ──┐                          │    │  │              │
│                                       │                          │    │  │              │
│  Looking Glass 客户端（窗口）  ←──────┴────────────────────────────┘    │  │              │
│   • 从共享内存取帧（LGMP），走 DMA-BUF 直接导入宿主 GPU（零拷贝）        │  │              │
│   • 把键鼠经输入通道写回 IDD（多显示器下用抓取模式）                     │  │              │
│                                                                        │  │              │
│  winbox（本仓库）                                                        │  │              │
│   • 探测/配置/渲染域定义/复位轮回/自检/取证  ─────── libvirt & /sys ────┘  │              │
│   • 客机交互（lib/guest.sh）：ssh → PowerShell ─────────────────────────┘              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

**三条链路，彼此独立**：
- **显示**：客机 IDD → 共享内存 → 宿主 LG 客户端 → 窗口（数据量最大，零拷贝是重点）
- **控制**：`winbox` → 配置/模板 → libvirt（改定义、启停）+ `/sys`（设备驱动归属）
- **客机控制**：`winbox` → SSH → PowerShell（查状态、改 IDD 偏好、投递文件）

## 2. 三条端到端链路的实现（细节见 docs/calltrees/）

### 2.1 显示链路

```
客机: 桌面 → IDD 渲染 → 帧缓冲 → 共享内存（ivshmem → /dev/kvmfr0）
                                      │
宿主: LG 客户端 mmap /dev/kvmfr0 ─────┘
      → LGMP 取帧 → DMA-BUF → 宿主 GPU 直接采样 → 窗口
      → 反向：输入事件 → 共享内存输入通道 → 客机 IDD → 注入键鼠
```

关键约束（都是踩出来的）：

| 约束 | 后果 |
| --- | --- |
| 共享内存大小必须与 `kvmfr` 模块参数**完全一致** | 不一致时 LGMP 握手失败，窗口黑屏 |
| `/dev/kvmfr0` 必须是**字符设备** | 若 QEMU 先启动把它建成普通文件，模块再也建不出字符设备 |
| 权限**两层**都要放行（AppArmor + cgroup ACL） | 少一层就 EACCES / EPERM，启动那一刻才暴露 |
| IDD 需要 `ForceIndirectCopy=1` | 否则走 D3D12 直传路径 → AMD 驱动 Device Removed |
| 多显示器必须用抓取模式 | 绝对定位走桌面坐标，指针会跳到别的屏 |

### 2.2 控制链路（改域定义）

**模板即真相源**，只有一条写盘路径：

```
配置键（config/win-box.conf）
   → 渲染模板（config/templates/domain.xml.in + 片段）
   → 备份当前 dumpxml
   → virsh define
   → 回读 QEMU argv 校验
   → 打印前后 diff
```

`gpu-attach` / `lg-shmem` / `vm mode` / `vm redeploy` 全都走这一条路，所以：
没有"改一半"的中间态、不需要 XML 编辑工具、渲染结果能用 libvirt 自己的 RNG schema 离线校验。

代价写在明处：**手工 `virsh edit` 的改动会被下一次渲染覆盖**——改结构要改模板。

### 2.3 复位链路（免冷启动宿主）

```
winbox vm start
   → libvirt 执行钩子 /etc/libvirt/hooks/qemu.d/<vm>/prepare/begin/10-winbox-reset.sh
   → source scripts/lib/*.sh; wb_gpu_reset_cycle; exit 0
        ├─ 写 driver_override = amdgpu      ← 必须先写，否则 vfio-pci 凭 ids= 抢回
        ├─ 解绑当前驱动
        ├─ modprobe amdgpu                  ← 必须自己加载（宿主不会自动加载它：设备被 vfio-pci 认领）
        ├─ 写 drivers_probe                 ← 必须显式，unbind 后内核不会自动 probe
        ├─ 等 amdgpu 完成初始化（默认 30s）
        ├─ 解绑 amdgpu → 内核执行 MODE2 reset
        └─ 两个功能交回 vfio-pci
   → QEMU 启动 → 客机驱动初始化成功
```

**钩子必须永远 `exit 0`**：复位失败也不能阻止 VM 启动。因此 `wb_gpu_reset_cycle`
内部不使用 `wb_fail`，所有异常降级为日志（冒烟测试里有专门断言锁住这条）。

## 3. 状态机

### 3.1 核显的驱动归属（复位轮回就是它的转移）

```
                 ┌──────────────────────────────────────────┐
                 │                                          │
        host-prep│                                          │ 开机（设备被 vfio-pci 认领则停在这里）
                 ▼                                          │
            ┌─────────┐   内核 udev 自动绑定   ┌──────────┐   │
            │ (none)  │◄──────────────────── │ amdgpu   │───┘
            └─────────┘                      └──────────┘
                 │  drivers_probe                ▲
                 │  + driver_override            │ 写 override = amdgpu
                 ▼                               │ 再 probe
            ┌──────────┐   解绑 amdgpu 触发 MODE2 reset
            │ vfio-pci │◄─────────────────────────────┐
            └──────────┘                              │
                 │  QEMU 打开                           │
                 ▼                                     │
            ┌──────────┐   VM 关机后：状态被弄脏 ────────┘
            │ 使用中    │   （不复位 → 下次启动 = 客机代码 43）
            └──────────┘
```

### 3.2 宿主核显姿态（`winbox host-gpu`）

驱动归属之上还有一层：**核显到底归谁用**。两种姿态各自是一组配置的集合，
`host-gpu` 负责在它们之间切换（持久化 + 当前会话两件事）：

```
passthrough（直通姿态，默认）                     host（宿主姿态）
  modprobe.d: options vfio-pci ids= + softdep      以上全部撤掉
              ← 这行才是"认领设备"，是整个机制的核心
  initramfs : amdgpu 不在模块表、vfio 三件套在      重建 initramfs
  当前会话  : 核显绑在 vfio-pci                     核显绑在 amdgpu
       │                                                │
       └──────────── winbox host-gpu host ──────────────┘
       ◄─────────── winbox host-gpu passthrough ────────┘

两个方向都可能"需要重启才完全生效"（modprobe.d 会被打进 initramfs）→ 以码 5 收尾。
判定只看持久化配置：有 ids= 即直通；"ids= 与开机模块表里的 amdgpu 并存"才算 mixed。
blacklist amdgpu 不参与判定（拦不住显式 modprobe，且设备已被认领）。
另外：**本工具不引入 systemd 服务**，只探测"别人写的开机绑定脚本"并在 host 姿态下把它当冲突报出
（它会在每次开机把核显抢回 vfio-pci，让 host 姿态失效）；`--takeover` 才停用归档。
```

为什么需要它：调试"到底是哪一层在挡"（把 amdgpu 还回去看核显本身是否正常）、
或临时把核显拿回宿主做编码/多屏。它是**唯一的**直通配置所有者——`host-prep` 也调用同一组函数。

### 3.3 VM 生命周期与"该做什么"

```
 shut off ──start──▶ running ──ACPI shutdown──▶ shut off
    │                   │                          │
    │ 可改域定义          │ 只读自检（winbox status）   │ 可拍快照
    │ （redeploy）        │ 复位钩子在 start 之前执行     │ 可回滚
    │                   │ 不要 destroy（曾损坏 NTFS）   │
```

### 3.4 共享内存通道

```
kvmfr 未加载 ──lg-prepare──▶ /dev/kvmfr0 是字符设备 ──lg-shmem──▶ 域里有 ivshmem 参数
                                        │                                │
                                        │                    （QEMU 启动时打开该设备）
                                        ▼                                ▼
                        权限双闸未过 → 启动失败 EACCES/EPERM      客户端 LGMP 握手 → 出画
```

## 4. 模块划分（谁负责什么）

```
L1  入口      scripts/bin/winbox            只解析全局选项 + 转发（exec，退出码原样透传）
L2  命令      scripts/bin/<命令>            每条端到端链路的一个阶段
L3  函数库    scripts/lib/*.sh              原子能力，可单独 source（场景 4）
C   工具      src/romtool                   二进制结构处理（shell 不适合的部分）
```

| lib | 负责 | 关键约束 |
| --- | --- | --- |
| `log.sh` | 输出 + **唯一失败出口** `wb_fail` | 人类可读走 stderr，stdout 只留结果 |
| `conf.sh` | **唯一配置入口**（env > 文件 > 默认） | 业务代码不许直接读环境变量 |
| `sys.sh` | 前置条件守卫 | 前置不满足一律码 3 |
| `detect.sh` | 硬件探测（只读） | 启发式识别核显，不硬编码设备 ID |
| `pci.sh` | PCI 驱动归属操作 | 三个内核陷阱固化在此 |
| `gpu.sh` | 复位轮回、ROM 部署 | **内部不用 wb_fail**（钩子复用） |
| `xml.sh` | 模板渲染 + 重定义域 | 唯一写盘路径；严格校验渲染结果 |
| `lg.sh` | KVMFR、客户端、权限双闸、IDD 偏好 | 权限状态三态（ok/missing/unknown） |
| `guest.sh` | 客机 SSH 通道 | **没配通道不是故障** |
| `report.sh` | 报告与取证清单 | 文本与 JSON 同一份数据 |

**分层规则**：L2 之间**禁止互相调用**（共用逻辑一律下沉 L3），L3 只允许向下依赖。
这条规则是为了消除工作区里最初那批脚本"互相纠缠、顺序依赖"的问题。

## 5. 不能碰的约束（都有代价换来的理由）

1. **模板驱动，不做就地 XML 编辑** —— 否则需要 xmlstarlet/python，且渲染结果无法离线校验。
2. **所有系统改动经 `wb_run` / `wb_write`** —— 否则 `--dry-run` 是假的。
3. **钩子永不阻塞** —— 复位失败也必须让 VM 起来。
4. **只在 shell 不适合时才用 C** —— 目前仅 `romtool`；项目里没有 Python。
5. **不静默兜底** —— 探测不到就报错（码 3/4），不猜、不降级。
6. **不进仓库的资产**：ROM / ISO / 驱动包 / 日志（`.gitignore` + 提取脚本）。

## 6. 已知缺陷与规避（本架构不解决的问题）

| 缺陷 | 本质 | 规避 |
| --- | --- | --- |
| 物理屏网格状白方块 | AMD 驱动在 D3D12 直传路径上的缺陷（direct → GPU 挂起；indirect → 局部拷贝越界写） | 不接物理显示器（推荐）；或 `ForceIndirectCopy=1` 减轻 |
| 复位 bug | 核显关 VM 后状态被弄脏 | 复位轮回钩子；极端情况冷启动宿主 |
| 客机代码 43 | 核显在 UEFI 下缺合适 ROM / 被当作 POST 设备驱动 | ROM 对 + 专属 root port + `lg` 模式（非启动显示适配器） |

详见 `docs/zh/01`、`docs/zh/03`、`docs/zh/05`。
