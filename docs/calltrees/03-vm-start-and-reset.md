# 链 03：启动与复位轮回（复位是 `vm start` 的前置步骤）

> 这是本项目的**核心机制**：把「AMD 核显复位 bug」从"每次都要冷启动宿主"降级为"每次启动多等 20–30 秒"。

## 3.1 `vmctl start [--no-reset]`

```
vmctl start win11()
    wb_conf_load(); VM ← 参数或配置
    if [virsh domstate $VM] != "shut off": 终止(码 3, "已在运行")

    ── 前置步骤：核显真复位（**不用钩子**，由本命令直接执行）───────────────
    姿态 = wb_host_gpu_detect()
    if --no-reset:            警告后跳过（客机可能出现代码 43）
    elif 姿态 == host:        跳过（核显归宿主，本就不需要复位）
    else:                     wb_require_root()   ← 非 root 直接拒绝启动（码 3）
                              wb_gpu_reset_cycle()
    ┌─────────────────────── wb_gpu_reset_cycle() ───────────────────────┐
    │ 1) 现状                                                            │
    │    wb_pci_driver(GPU) → drv                                        │
    │    if drv == amdgpu: 跳过第 2 步（说明上一次轮回没做完，无需重做） │
    │                                                                    │
    │ 2) 让 amdgpu 短暂接管（目的是"真复位"，不是为了用它）               │
    │    wb_pci_override(GPU, amdgpu)                                    │
    │    ★ 必须先写 driver_override：否则 vfio-pci 会凭 ids= 瞬间抢回     │
    │    if drv != (none): wb_pci_unbind(GPU)                            │
    │    ["modprobe amdgpu"]                                             │
    │    ★ 必须自己 modprobe：宿主不会自动加载它（设备被 vfio-pci 认领） │
    │      （黑名单只是补充，而且拦不住显式 modprobe —— 实测）              │
    │      —— 冷启动后的第一次启动最容易漏掉这一步（实测踩过）           │
    │    wb_pci_probe(GPU)                                               │
    │    ★ 必须显式写 drivers_probe：unbind 后内核不会自动重新探测        │
    │    wb_pci_wait_driver(GPU, amdgpu, 20s)                            │
    │    if 未等到: 记 WARN，进入第 3 步的"跳过"分支                      │
    │    sleep WB_REBOOT_WAIT(默认 30)   # 让 SMU/PSP/显示初始化跑完      │
    │                                                                    │
    │ 3) 解绑 amdgpu → 内核做 MODE2 reset                                 │
    │    wb_pci_override_clear(GPU)                                      │
    │    wb_pci_unbind(GPU)                                              │
    │    [dmesg | grep -E 'MODE2 reset|finishing device']  ← 复位证据      │
    │    if 未绑定 amdgpu: 记 WARN "本次跳过复位"                          │
    │                                                                    │
    │ 4) 两个功能交回 vfio-pci                                            │
    │    for BDF in {GPU, AUDIO}: wb_pci_bind(BDF, vfio-pci)             │
    │    记日志（含每一步前后驱动名 + 耗时）                              │
    │                                                                    │
    │ ★ 函数永远不抛错退出；所有异常降级为日志                            │
    └────────────────────────────────────────────────────────────────────┘

    QEMU 启动 → 客机加载 AMD 驱动
        └─ lg 模式下核显不是 Primary → 不触发 STATUS_GRAPHICS_NOT_POST_DEVICE_DRIVER
    wb_guest_ready() 轮询 SSH 可达（可选，用于自动验证）
    终止(码 0, "VM 已启动")
```

## 3.2 分支与失败出口

```
if 启动后客机仍显示代码 43:
    ├─ 再次 wb_gpu_reset_cycle 后重启 VM（有时第一次轮回不生效）
    ├─ 检查 /var/log/winbox-reset.log: 是否有 "本次跳过复位" → 说明 amdgpu 没绑定
    │      └─ 处理: 冷启动宿主（码 5 出口），或检查模块是否被其它原因挡住
    └─ 参照链 05 采集证据

if 启动耗时异常长:
    └─ 正常：复位轮回会等 WC_REBOOT_WAIT + 驱动初始化；--verbose 可看每步耗时

if 需要临时禁用轮回:
    └─ winbox vm start --no-reset   （显式跳过复位；仅在你确实知道 GPU 状态干净时用）
```

## 3.3 钩子为什么用「函数库」而不独立成脚本

钩子文件**必须是极薄的壳**（`source lib; wb_gpu_reset_cycle; exit 0`），因为：

1. 场景 4 要求同一条逻辑能被人**单独调用**（调试时手动跑一次看日志）；
2. libvirt 钩子在 VM 启动路径上，任何 bug 都会让 VM 起不来——薄壳 + 成熟函数更安全；
3. 函数内部可以自由重构（换等待策略、改日志），不必动 `/etc/` 里的文件。
