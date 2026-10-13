# win-box 需求文档

> 立项时期产物（code-master Bootstrap 第 2 步）。
> 日期：2026-10-13 ｜ 状态：待用户确认

## 项目目的

把一次真实的攻坚过程——「Ubuntu 桌面 + Windows 11 虚拟机 + AMD 核显直通 + Looking Glass」——沉淀成**可复用、可分享的工具工程**，而不是一篇一次性博文或一堆本机专用脚本。

工程的形态是：

- **主体是 shell 函数库**：把难写、易错、依赖经验判断的原子操作（vfio 绑定、复位轮回、ROM 部署、共享内存附加、客机指令投递）封装成**小、正交、可 source、可单独调用**的函数。
- **其上提供少量长流程封装**：建机、直通准备、Looking Glass 起停、状态自检——每个封装是一条完整可中断的链路，而非"一键魔法"。
- **C 只用在 shell 不适合的地方**：内存映射设备、二进制 ROM 结构解析与校验。不为使用 C 而使用 C。
- **配套诚实的文档**：中文实录（踩过的坑、失败路线、证据）+ 英文门面（这是什么、要什么前置、怎么开始）。

**定位声明（重要）**：本项目**不是跨环境的一键安装器**。它是把「在一台具体机器上被验证过的一组操作」暴露为可读、可改、可复用的函数与封装。换一台机器、换一个发行版，**不保证能直接工作**——遇到硬件差异时宁可明确报错并指向文档，也不做静默兜底。

## 目标用户

- **复刻者（作者本人 / 同类玩家）**：新机器上要从零搭同样一条链路，需要正确的操作顺序、函数骨架和"哪一步容易错"的提示。硬件差异自己处理。
- **排障者**：已经卡在某个症状上（代码 43 / LG 黑屏 / 复位失败 / 物理屏白方块 / 指针错位），需要按症状定位的诊断命令与证据收集工具。
- **学习者**：想知道 iGPU 直通与 Looking Glass 数据流的原理，读文档，不需要跑脚本。

## 核心场景

### 场景 1：新机器复刻（半自动，人工判断为主）

- **触发**：`winbox detect` 或直接阅读 `docs/zh/09-从零一口气配置-精简版.md`
- **输入**：一台 Ubuntu/Debian 系机器 + AMD 核显（是否另有独显皆可）+ Windows 11 安装镜像
- **输出**：`config/win-box.conf`（硬件探测结果）+ 按阶段执行的命令序列
- **终止**：Looking Glass 窗口出现画面，且客机内 `Status=OK / ConfigManagerErrorCode=0`
- **失败**：任一步必须给出「哪个前置条件没满足 + 去文档哪一节」的明确报错

### 场景 2：故障排查（按症状 → 证据 → 结论）

- **触发**：`winbox status`（全链路自检）或 `winbox evidence`（取证包）
- **输入**：症状描述（代码 43 / LG 无画面 / DMA 报错 / 白方块 / 指针错位）
- **输出**：链路各环节的健康报告（IOMMU 分组 / 驱动归属 / ROM 指纹 / KVMFR / ivshmem / 客机可达性 / 客机显卡状态）
- **终止**：定位到具体环节，或明确"证据不足，需补采 X"
- **说明**：不做自动修复；修复动作由使用者按文档执行

### 场景 3：日常运维

- **触发**：`vmctl start|stop|snapshot`、`winbox lg`（起 Looking Glass）
- **输入**：虚拟机名、快照名
- **输出**：可用的窗口 / 已保存或已恢复的快照
- **终止**：窗口可交互，或快照操作返回成功

### 场景 4：单点重放（函数级复用）

- **触发**：直接 `source scripts/lib/*.sh` 后调用单个函数（例：`rom_verify`、`gpu_reset_cycle`、`lg_attach_shmem`）
- **输入**：函数参数
- **输出**：单一副作用 + 明确返回值
- **终止**：函数返回；**不依赖其他脚本的执行状态**

## 完成标准

- [ ] 陌生人 clone（含 submodule）后，**不读源码**即可从 README 判断：这是干什么的、需要什么前置、第一步敲什么
- [ ] 每个函数有目录式说明（用途 / 入参 / 出参 / 失败语义），`docs/interfaces/` 与实现一致
- [ ] 脚本中不存在本机专属**硬编码**：设备 BDF、vendor:device、绝对路径、IP、VM 名全部来自 `win-box.conf`（默认值可指向本机实例，但必须可覆盖）
- [ ] `shellcheck` 全绿（可豁免项在文件内注明理由）
- [ ] C 工具可独立 `make` + `make test`，测试使用仓库内自造的**合成 ROM**（不含 AMD 二进制）
- [ ] 至少 3 条端到端链路有 calltree 文档，ARCHITECTURE.md 有拓扑图与状态机图（复位轮回 / LG 数据流）
- [ ] `docs/zh/01..10` 全部修订：路径指向新结构、标题去本机化但不删实录证据
- [ ] 仓库内不含 ROM / ISO / 驱动安装包 / 日志（`.gitignore` 生效，`git ls-files` 可人工核验）
- [ ] 3 个第三方仓库以 **submodule** 钉住 commit，clone 说明写在 README

## 约束条件

| 维度 | 约束 |
| --- | --- |
| 技术栈 | **bash ≥ 5.1** 为唯一运行依赖；**C99 + make**（无第三方库）用于辅助工具；**无 Python**（旧 python 工具全部删除，能力由 romtool / wb_guest_* 取代）；不引入 ansible / 复杂框架 |
| 脚本形态 | `scripts/lib/*.sh` = 无副作用的函数库（source 用）；`scripts/bin/*` = 长流程封装（可执行、可中断、给 `--dry-run`）；配置只有 `config/win-box.conf` 一个入口 |
| 环境假设 | Ubuntu/Debian 系 + libvirt/KVM + OVMF/swtpm；AMD 核显直通；Looking Glass 作为主显示通道 |
| 可移植性 | **不承诺**跨发行版/跨硬件可用；不写发行版探测分支；差异用"明确报错 + 指向文档"暴露 |
| 依赖 | `third_party/`：`gnif/LookingGlass`、`isc30/ryzen-gpu-passthrough-proxmox`、`D800/VBIOS-Dumper-amd-Raphael-iGPU` 以 submodule 钉 commit |
| 入库边界 | 只入脚本 / 文档 / 工具源码；ROM、BIOS dump、ISO、驱动包、虚拟机日志一律 `.gitignore`，只保留 hash 与获取方式 |
| 安全 | 文档与示例中不含个人标识（用户名、主机名、密钥、内网 IP 之外的私人信息）；SSH 示例用占位符 |
| 许可 | **GPL-2.0-or-later**（已定：C 工具复用 LGMP/KVMFR 定义需 GPL 兼容，与 LG 生态一致） |
| 时间/团队 | 单人 + AI；无截止期；优先可读性而非功能覆盖 |

## 范围外（明确不做）

- 不做跨发行版适配层、不写包管理器抽象
- 不做 GUI / TUI 安装向导
- 不特化 NVIDIA 或 AMD **独显**直通（只保留可复用的通用函数）
- 不打包、不分发 Looking Glass 客户端二进制 / IDD 安装包 / AMD 驱动 / VirtIO 驱动
- 不承诺修复 AMD 驱动的物理屏白方块问题（只记录证据与规避手段）
- 不承诺复位 bug 被"根治"（只提供规避 hook 与冷启动建议）
- 不提供 Windows 镜像（用户自备合法授权镜像）

## 实现状态（2026-10-13 收尾）

15 条完成标准中，除「推送远程仓库」这类工程性事务外均已达成：

- ✅ 命令全部实现（detect / host-prep / **host-gpu** / vm-create / conf / vm / gpu-attach /
  lg-prepare / lg-shmem / lg / reset-hook / status / evidence / rom）
- ✅ shellcheck 全绿；`tests/smoke.sh` 261 条断言（不需虚拟机/核显/root）
- ✅ C 工具 `src/romtool`：`make test` 52 条断言，用合成 ROM（仓库内不含 AMD 二进制），
  并在真实 ROM 上验证过解析与 SHA256
- ✅ 完整链路文档：docs/interfaces（契约）+ docs/calltrees（链路）+ ARCHITECTURE.md +
  docs/zh（实录）+ docs/en（英文门面）；内部链接全部校验通过
- ✅ 三个第三方仓库以 submodule 钉 commit；上游许可与来源在 `.gitmodules` 与 README 注明
- ⬜ 推送远程仓库（待用户提供远端）

## 已确认决策（2026-10-13）

| 事项 | 决策 |
| --- | --- |
| 许可证 | **GPL-2.0-or-later** |
| 原工作区处置 | **归档**：原 `/mnt/docs/vm/{scripts,docs,tools,guest-tools,...}` 整体归档，**与 win-box 无关**——win-box 不引用、不依赖、不软链旧路径 |
| C 工具优先级 | **先 `romtool`**（可用合成 ROM 做 `make test`，不依赖硬件，陌生人可验证）；`kvmfr-probe` 二期 |
| 项目定位 | 全栈配方，但**形态偏 shell 函数工具库** + 少量长流程封装；**不保证**在其他环境上工作 |
| 第三方整合 | `third_party/` 用 **git submodule 钉 commit** |
| 域定义方式 | **模板渲染，不做就地 XML 编辑**（`config/templates/domain.xml.in` + 片段）；因此不需要 xmlstarlet / python，且渲染结果可离线用 libvirt 自身 RNG schema 校验。代价：手工 `virsh edit` 的改动会被下一次渲染覆盖——改结构要改模板 |
| 入库边界 | 只入脚本/文档/工具源码；ROM、BIOS dump、ISO、驱动包、日志 `gitignore` |
