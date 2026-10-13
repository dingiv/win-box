# 接口全景

> 立项时期产物（code-master Bootstrap 第 3 步）。
> 本目录定义 win-box 的**对外契约**：调用方看到的外观、输入输出、失败语义、生命周期。不含实现细节。

## 三层结构

```
L1  winbox <command>            用户唯一入口（dispatcher）。也允许直接调 L2。
L2  bin/<task>                  长流程封装：一条完整链路，可独立执行、可中断、支持 --dry-run
L3  lib/*.sh                    函数库：原子操作，可 source，可单独调用（场景 4）
    （C）src/romtool             shell 不适合的二进制/设备操作，以 CLI 暴露
```

**调用方向单向向下**：`L1 → L2 → L3`；`romtool` 由 L2/L3 以子进程调用（`lib/rom.sh` 是它的唯一包装层）。
`L2` 之间**不互相调用**——需要复用的一律下沉为 `L3` 函数。这条约束防止长流程脚本互相纠缠。

## 场景 → 接口映射

| 需求文档场景 | 主接口 | 依赖的 L2/L3 |
| --- | --- | --- |
| 场景 1 新机器复刻 | `winbox detect` → `host-prep` → `vm-create` → `gpu-attach` → `lg-prepare` → `lg-build` → `lg-run` | 全部 |
| 场景 2 故障排查 | `winbox status` / `winbox evidence` | `lib/pci.sh` `lib/lg.sh` `lib/guest.sh` `lib/report.sh` |
| 场景 3 日常运维 | `winbox vm …` / `winbox lg` | `lib/virsh.sh` `lib/lg.sh` |
| 场景 4 单点重放 | `source lib/*.sh` + 单函数调用 | `lib/*` |
| （辅助）ROM 处理 | `winbox rom …` | `src/romtool`（C） |

## 通用约定（所有接口共同遵守）

**退出码**——统一语义，便于脚本串联与人工判断：

| 码 | 含义 | 调用方应做什么 |
| --- | --- | --- |
| 0 | 成功 | 继续 |
| 1 | 执行失败（命令报错、文件不可写……） | 看错误行 |
| 2 | 用法错误（参数缺失/非法） | 看 `--help` |
| 3 | **前置条件不满足**（缺依赖、kvmfr 未加载、VM 正在运行……） | 按错误提示补前置 |
| 4 | **硬件/环境不匹配**（找不到 AMD 核显、无 IOMMU……） | 换机器或手工适配 |
| 5 | **需要人工介入**（需重启、需在客机内操作、需物理判据） | 按提示做完再来 |
| 6 | **检查发现降级**（仅 `status`） | 有 ⚠ 项，可继续，值得看一眼 |
| 7 | **检查发现故障**（仅 `status`） | 有 ✗ 项，按报告逐条处理 |

**错误输出格式**（单行，机器可解析）：
```
✗ <stage>: <什么没满足> → <去哪看>
例：✗ gpu-attach: 未找到 AMD 核显（vendor 1002 且 class 0x030000） → docs/zh/06-最终配置清单与复现步骤.md
```

**三条纪律**：

1. **幂等**：所有 mutating 命令重复执行结果一致（内部先探测再改，而非盲目追加）。
2. **可干跑**：所有 mutating 命令支持 `--dry-run`，打印将要执行的系统改动，不落盘。
3. **不静默兜底**：能自动探测的自动探测；探测不到一律报错（码 3/4），不猜、不降级、不"尽力而为"。

**sudo 策略**：只有真正写 `/etc`、`/sys`、加载模块的命令需要 root（`host-prep` / `gpu-attach` / `lg-prepare` / `host-gpu`；以及**直通姿态下的 `vm start`**——它要先做核显复位）；`detect` / `status` / `evidence` / 其它 `vmctl` 子命令 / `lg-run` / `rom info|verify|patch` 不需要。命令在缺 root 时报码 3 并直接给出 `sudo` 命令。

**配置**：唯一入口 `config/win-box.conf`（由 `winbox detect` 生成、`winbox conf` 检视）。所有 BDF、ID、路径、IP、VM 名从这里读；环境变量可覆盖同名键（`WB_*`），优先级：命令行 > 环境变量 > 配置文件 > 内置默认。

## 本目录文件

| 文件 | 内容 |
| --- | --- |
| `00-overview.md` | 本文：三层结构、场景映射、通用约定 |
| `01-winbox-cli.md` | 主入口 `winbox` 的完整命令契约 |
| `02-vmctl.md` | 虚拟机日常运维接口 |
| `03-romtool.md` | C 工具 `romtool` 的 CLI 契约 |
| `04-lib-api.md` | 函数库 API 契约（场景 4 的对外接口） |
