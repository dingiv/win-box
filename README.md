# win-box

在 Linux 桌面上用 KVM 跑一台 **Windows 11**，把 **AMD 核显直通**给它，并用
**[Looking Glass](https://looking-glass.io/)** 把它变成宿主上的一个窗口 —— 顺带把过程中
踩过的坑固化成可读、可改、可复用的 shell 函数库。

> 一句话定位：**这不是通用一键安装器。** 它把「在一台具体机器上被验证过的一组操作」
> 暴露成 shell 函数与少量长流程封装。换机器、换发行版不保证可用 —— 遇到硬件差异时，
> 它会明确报错并指向文档，而不是静默兜底。

## 项目状态

**命令全部实现**（`winbox --help` 里带 ★ 的即是）；剩「推送远程仓库」这类工程性事务。

```bash
scripts/bin/winbox detect        # 硬件探测（启发式识别核显，非硬编码 ID 表）
scripts/bin/winbox host-prep     # 宿主准备（依赖 / vfio / initramfs / 内核参数；幂等）
scripts/bin/winbox host-gpu      # 宿主核显姿态开关（直通 / 还给宿主；含冲突检查与 --takeover）
scripts/bin/winbox adopt         # 接管现有 VM：把身份信息提取到配置
scripts/bin/winbox vm-create     # 新建 VM（UEFI + TPM2，模板渲染）
scripts/bin/winbox conf          # 配置的唯一读写入口
scripts/bin/winbox vm render     # 按模板渲染域 XML（打印，不生效）
scripts/bin/winbox gpu-attach    # 挂核显：ROM 校验/部署 + 模板重定义
scripts/bin/winbox lg-prepare    # KVMFR 模块 + 构建 Looking Glass 客户端
scripts/bin/winbox lg-shmem      # 共享内存设备 + 权限双闸
scripts/bin/winbox lg            # 起窗口（--idd-prefs 应用客机 IDD 偏好）
scripts/bin/winbox reset-hook    # 复位轮回钩子（免每次冷启动宿主）
scripts/bin/winbox status        # 全链路自检（退出码即结论）
scripts/bin/winbox evidence      # 一键取证包（14 项 + sha256 清单）
scripts/bin/winbox rom           # ROM 工具（C：info/verify/patch/merge/dump/extract）

bash tests/smoke.sh              # 261 条断言，不需虚拟机/核显/root
make -C src/romtool test         # 52 条 C 断言，用合成 ROM，不需硬件
```

## 前置要求

| 项 | 要求 | 说明 |
| --- | --- | --- |
| 宿主系统 | Debian/Ubuntu 系 | 只按这一系的工具链设计，不做发行版适配层 |
| 硬件 | AMD APU/iGPU（如 Granite Ridge 核显） | 需要 IOMMU 可用；独显机器也能用核显做直通 |
| 虚拟化 | KVM + libvirt + QEMU + OVMF + swtpm | `winbox host-prep` 会装齐 |
| 内核 | 支持 `vfio-pci` 与 IOMMU | 内核参数由 `host-prep` 写入 |
| Windows | 自备合法授权的 Windows 11 ISO | 仓库不包含、也不分发镜像 |
| 显卡驱动 | AMD Adrenalin **离线**安装包 | 客机内离线安装（在线安装会因直通设备识别失败） |

**本仓库不包含、也不分发**：VBIOS/BIOS ROM、Windows 镜像、AMD 驱动、VirtIO 驱动、
Looking Glass 的 IDD 安装包。这些用脚本在你自己的机器上提取或从官方渠道获取
（原因见 `.gitignore` 与 `docs/interfaces/03-romtool.md`）。

## 快速开始

```bash
git clone --recurse-submodules <本仓库>
cd win-box

scripts/bin/winbox detect --write     # 1. 探测硬件与环境，生成 config/win-box.conf
sudo scripts/bin/winbox host-prep     # 2. 宿主准备（依赖 / vfio / initramfs / 内核参数）→ 可能要重启
#   已有虚拟机的人到这一步就够了：下面 3 换成 adopt
winbox adopt                          # 3a.（推荐）接管现有 VM：把身份信息提取到配置
#   或从零新建：
sudo winbox vm-create                 # 3b. 建机（UEFI + TPM2），然后手工装 Windows
sudo scripts/bin/winbox gpu-attach --rom <VBIOS> --audio-rom <GOP> --mode lg   # 4. 挂核显
sudo scripts/bin/winbox lg-prepare    # 5. KVMFR 模块 + 构建 Looking Glass 客户端
sudo scripts/bin/winbox lg-shmem      # 6. 共享内存设备 + 权限双闸
sudo scripts/bin/winbox reset-hook install   # 7. 复位轮回钩子（免每次冷启动宿主）
scripts/bin/winbox vm start && scripts/bin/winbox lg   # 8. 开机 + 开窗口
```

先干跑看清会改什么（所有 mutating 命令都支持 `--dry-run`，连模板渲染结果都会校验）：

```bash
winbox -n host-prep            # 六步只读检查（非 root 也能跑）
winbox -n vm-create --name test
```

装完系统后在客机内一次性完成：装 AMD 驱动（离线版）→ 装 Looking Glass IDD
（`/S /ivshmem`）→ 开 SSH 通道 → 应用 IDD 偏好。细节见 `docs/zh/`。

日常用：

```bash
scripts/bin/winbox status             # 全链路自检（退出码即结论：0 OK / 6 降级 / 7 故障）
scripts/bin/winbox vm start           # = vmctl start
scripts/bin/winbox lg                 # 起窗口
```

## 目录结构

```
win-box/
├── REQUIREMENTS.md          需求与范围（含"明确不做"的部分）
├── scripts/
│   ├── lib/*.sh             函数库（L3）：可 source、可单独调用，无副作用约定
│   └── bin/*                长流程封装（L1/L2）：可执行、可中断、支持 --dry-run
├── src/romtool/             C 工具（仅用于 shell 不适合的二进制/设备操作；make test 离线自测）
├── guest/                   Windows 侧脚本（建立 SSH 通道、客机体检）
├── config/
│   ├── win-box.conf.example 唯一配置入口的样板（真实配置被 gitignore）
│   └── templates/           域 XML 模板与形态片段（VM 定义的真相源）
├── docs/
│   ├── interfaces/          对外契约：命令、函数库 API、C 工具 CLI
│   ├── calltrees/           端到端链路：复位轮回、Looking Glass 全链、自检取证…
│   ├── zh/                  中文实录（排障过程、踩坑、证据）+ 索引
│   ├── en/                  英文概览
│   └── samples/             脱敏后的配置与证据样本
├── tests/smoke.sh           不依赖硬件与 root 的冒烟测试（248 条）
└── third_party/             上游源码（git submodule，钉 commit）
```

## 设计要点

**三层，单向向下**：`winbox`（入口）→ `scripts/bin/<命令>`（长流程）→ `scripts/lib/*.sh`
（函数库）。长流程之间**禁止互相调用** —— 需要复用的逻辑一律下沉到函数库，否则脚本会
像藤蔓一样互相纠缠（这正是本项目要解决的问题）。

**统一的失败语义**：

```
✗ <stage>: <原因> → <文档锚点>          # 唯一出口：lib/log.sh 的 wb_fail

0 成功   1 执行失败   2 用法错误   3 前置条件不满足
4 硬件/环境不匹配   5 需要人工介入   6 降级   7 故障（后两个仅 status 用）
```

**三条纪律**：幂等（先探测再改）、可干跑（`--dry-run`，所有系统改动都经 `wb_run`）、
不静默兜底（探测不到就报错，不猜不降级）。

**C 的准入门槛**：只有当 shell 不适合时才写 C —— 目前只有 ROM 结构解析/校验/合并
（`src/romtool/`，`make test` 用**合成 ROM** 离线自测，仓库内不含任何 AMD 二进制）。
项目里没有 Python。

**域定义的真相源是模板**：`config/templates/domain.xml.in` + 片段。所有“改 VM 结构”的命令
（`gpu-attach` / `lg-shmem` / `vm mode`）都是同一个动作：改配置键 → 渲染 → 备份 → `virsh define`
→ 回读 → 打印 diff。所以不需要 XML 编辑工具，而且渲染结果能用 libvirt 自己的 schema 离线校验。
代价写在明处：**手工 `virsh edit` 的改动会被下一次渲染覆盖** —— 改结构请改模板。

## 文档地图

| 想了解 | 看 |
| --- | --- |
| 这个项目要解决什么、不做什么 | [`REQUIREMENTS.md`](REQUIREMENTS.md) |
| 数据怎么流、状态怎么变、模块怎么分 | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| 命令与函数长得什么样（契约） | [`docs/interfaces/`](docs/interfaces/) |
| 一条操作链具体怎么走 | [`docs/calltrees/`](docs/calltrees/) |
| 为什么这么设计、踩过什么坑（实录） | [`docs/zh/`](docs/zh/)（[索引与旧命令对照](docs/zh/README.md)） |
| 英文概览 | [`docs/en/`](docs/en/) |

## 已知限制

- **物理屏白方块**：AMD 核显驱动在 Looking Glass 的 D3D12 直传路径上有缺陷，物理显示器
  可能出现网格状白块。配置层无法根治，只能用间接拷贝路径减轻或干脆不接物理显示器。
- **复位 bug**：AMD 核显直通后设备状态会被弄脏，需要"真复位"（本项目的钩子）或冷启动宿主。
- **安全启动**：宿主 Secure Boot 需关闭（未签名的 KVMFR 模块要加载）。

## 许可

GPL-2.0-or-later（见 `LICENSE`）。选择它的原因：C 工具需要复用 Looking Glass 生态的
LGMP/KVMFR 定义，而后者是 GPL-2.0。

`third_party/` 下为上游源码的 submodule，各自遵循其原始许可：

- [gnif/LookingGlass](https://github.com/gnif/LookingGlass) — GPL-2.0
- [isc30/ryzen-gpu-passthrough-proxmox](https://github.com/isc30/ryzen-gpu-passthrough-proxmox) — 参考配方
- [D800/VBIOS-Dumper-amd-Raphael-iGPU](https://github.com/D800/VBIOS-Dumper-amd-Raphael-iGPU) — ROM 提取参考
