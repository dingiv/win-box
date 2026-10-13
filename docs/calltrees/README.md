# 端到端调用链（calltree）

> 立项时期产物（code-master Bootstrap 第 4 步）。
> 每条链从**对外接口**出发，标出触发点、主链路、关键分支、终止条件。
> 细节用 `...` 留白——本层不写实现。

## 语法约定

```
触发点()                    # = 对外接口被调用
    L3函数()                # 小写/下划线 = 函数库调用（lib/*.sh）
    ["命令"]                # 方括号 = 子进程 / 外部命令
    if 条件:                # 关键分支必写条件
    ★ 注记                  # 来自实战的硬约束（踩过的坑）
    终止()                  # 成功 / 失败 / 需人工 的出口
```

## 链路清单

| 链 | 对应接口 | 文件 |
| --- | --- | --- |
| 探测与宿主准备 | `winbox detect` / `host-prep` | [01-detect-and-host-prep.md](01-detect-and-host-prep.md) |
| 建机与直通挂载 | `winbox vm-create` / `gpu-attach` | [02-create-and-attach.md](02-create-and-attach.md) |
| 启动与复位轮回 | `vmctl start`（经 libvirt 钩子） | [03-vm-start-and-reset-hook.md](03-vm-start-and-reset-hook.md) |
| Looking Glass 全链 | `winbox lg-prepare` / `lg-shmem` / `lg` | [04-lg-chain.md](04-lg-chain.md) |
| 自检与取证 | `winbox status` / `evidence` | [05-status-and-evidence.md](05-status-and-evidence.md) |
| ROM 处理（C） | `winbox rom …` → `romtool` | [06-romtool.md](06-romtool.md) |

## 贯穿全局的三条约束（在每条链里都能看到）

1. **状态先于动作**：每个 mutating 步骤前必有一次只读探测（`wb_pci_driver` / `wb_xml_require_stopped` / `wb_kvmfr_check`），幂等由此而来。
2. **失败带出口**：任何 `wb_fail` 必须给出「原因 + 文档锚点」，不允许只报"失败"。
3. **钩子永不阻塞**：凡被 libvirt 钩子复用的函数（`wb_gpu_reset_cycle`），内部失败一律降级为日志，绝不向上抛错。
