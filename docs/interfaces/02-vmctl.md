# 接口契约：`vmctl`（虚拟机日常运维）

> 形式：CLI。来源：工作区既有 `vmctl.sh` 的去本地化版本。可独立执行，也可经 `winbox vm <子命令>` 调用。

## 签名

```
vmctl <command> [args]            # VM 名省略时用配置里的默认值
vmctl <command> <vm> [args]
```

全局：`--help`（从脚本头部注释自动生成）。**除 `rm` 外都不需要 root**（走 libvirt 组权限）。

## 命令契约

| 命令 | 输入 | 输出 | 失败语义 |
| --- | --- | --- | --- |
| `list` | — | 所有 domain 的名字 + 状态 | 码 1 = libvirt 不可连（提示 `systemctl start libvirtd`） |
| `start [vm]` | — | domain 启动；若配置了复位钩子，启动前会等待复位完成 | 码 5 = 复位钩子日志显示 amdgpu 未绑定（提示冷启动）；码 3 = 已在运行 |
| `shutdown [vm]` | — | 发 ACPI 关机请求，**等待**直到 `shut off`（默认超时 180s） | 码 1 = 超时（提示可用 `destroy`，并警告 NTFS 风险） |
| `destroy [vm]` | — | 强制断电 | 命令本身总成功；但**输出警告**：强制断电曾损坏 NTFS，仅在假死时使用 |
| `reboot [vm]` | — | 重启 | 同上 |
| `status [vm]` | — | 状态 + vCPU/内存占用 + IP（经 DHCP lease 或客机上报） | 码 0（信息性） |
| `console [vm]` / `viewer [vm]` | — | 打开 virt-manager / virt-viewer | 码 3 = 两者都未安装 |
| `eject [vm]` | — | 弹出光驱（安装 ISO） | 码 0 = 无光驱也算成功（幂等） |
| `snapshot-save [vm] NAME` | 快照名 | 磁盘外部快照（`--disk-only --atomic`）；**先 ACPI 关机再拍** | 码 3 = VM 未关机；码 2 = 快照名已存在 |
| `snapshot-list [vm]` | — | 快照列表 + 磁盘链 | 码 0 |
| `snapshot-restore [vm] NAME` | 快照名 | 回滚到该快照 | 码 3 = VM 未关机；码 2 = 快照不存在 |
| `rm [vm]` | — | 删除 domain + 磁盘 + NVRAM（二次确认，除非 `--yes`） | 码 2 = 未确认；码 3 = VM 运行中 |

### 模板驱动的域定义（本项目特有）

| 子命令 | 输入 | 输出 | 失败语义 |
| --- | --- | --- | --- |
| `render` | — | stdout = 按模板渲染出的完整域 XML（不落盘、不生效） | 码 2/3 = 配置/模板有问题 |
| `redeploy [REASON]` | 可选原因标签（用于日志文件名） | 备份 → 渲染 → `virsh define` → 回读 → 打印前后 diff | 码 1 = define 被拒；码 3 = VM 运行中；码 5 = 有快照时用户取消 |
| `verify` | — | 回读 `domxml-to-native qemu-argv`，检查 vfio 设备数 / `x-vga=on` / `vga=none` / ivshmem | 码 3 |
| `mode <test\|inspect\|both\|lg>` | 显示模式 | 写 `WB_VIDEO_MODE` + 重定义；无参数时打印当前模式 | 码 2 |
| `template-path` | — | stdout = 当前使用的模板路径 | — |

**为何单独列出**：这四个子命令是所有“改 VM 结构”的统一出口。手工 `virsh edit` 的改动会在下一次
`redeploy` 时被模板覆盖——要改结构就改模板（`config/templates/domain.xml.in`，或复制为
`config/domain.local.xml` 后改）。

## 关键语义

1. **绝不用 `destroy` 达成 `shutdown` 的目的**：`snapshot-save` 与 `shutdown` 内部一律走 ACPI；`destroy` 只能由用户显式调用。
2. **快照 = 磁盘外部快照**：`snapshot-save --disk-only --atomic` 保留可用状态为独立 qcow2；回滚后 VM 的磁盘链恢复。
3. **回滚后的第一次启动**可能需要复位钩子或冷启动（见 `docs/zh/03-复位bug与amdgpu复位轮回.md`）——`snapshot-restore` 成功后主动打印这条提示。
4. **VM 名解析顺序**：命令行参数 > `WB_VM_NAME` 环境变量 > 配置文件 > 内置默认 `win11`。
5. **`status` 的 IP 获取**：优先读 libvirt DHCP lease；失败则尝试客机 SSH（配置存在时）；都失败显示 `(未知)` 而非报错。

## 与 `winbox` 的关系

`winbox vm start` ≡ `vmctl start`。两者是同一个可执行文件的两个入口（`winbox` 内部 exec 转发，不复制逻辑）。
