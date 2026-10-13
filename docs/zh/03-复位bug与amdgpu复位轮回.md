# 03 AMD 复位 bug 与 amdgpu 复位轮回

> 结论：核显直通后，**VM 每次启动前让宿主 `amdgpu` 短暂绑定再解绑一次**，
> 内核会执行 `MODE2 reset`，把 GPU 恢复到干净状态，客户机驱动才能正常初始化。
> 现在是 **`winbox vm start` 的前置步骤**（不用钩子、不装服务）：启动前自动做一次真复位，
> 从此不必每次冷启动宿主。

## 1. 症状

> **关于本文**：这是当时的**实录**（含走过的弯路与证据），不是使用说明。
> 命令已规整为本仓库的形式（`winbox …`）；接口以 `docs/interfaces/` 为准。

AMD 核显（以及很多 AMD GPU）在虚拟机直通场景有著名的"**复位 bug**"：

- 宿主冷启动后**第一次**启动 VM 通常正常；
- VM 关机后再启动 → 客机里核显代码 43，或设备根本起不来；
- 社区里的经验说法：*"only once per boot of the host"*（一次冷启动只够跑一次）。

根因方向：Windows 侧驱动在关机时**无法真正复位 GPU**（它期待一次硬件级电源循环，
而虚拟化环境下这不会发生），于是 GPU 停留在脏状态。

## 2. 关键线索（来自社区实测）

isc30 仓库 issue #135 里 2026-09 的一条评论（Raphael 7950X3D `1002:164e`）：

> "What fixed it on this machine was a **temporary host-driver cycle** immediately before QEMU starts:
> `vfio-pci -> amdgpu (wait for initialization) -> vfio-pci -> QEMU`"
>
> 并且给出内核侧证据：
> ```
> amdgpu 0000:17:00.0: finishing device.
> amdgpu 0000:17:00.0: MODE2 reset
> ```
> "…installed it as a libvirt `prepare begin` hook… All three shutdown/start cycles had correct
> physical output and zero `IO_PAGE_FAULT`."

要点：**`amdgpu` 解绑（remove）时会做一次真正的 GPU 复位**。
我们这台机器此前一直在"禁止宿主 amdgpu 触碰核显"（拉黑 + 不进 initramfs），
核显因此永远停留在"主板固件 POST 完但从未被 OS 驱动接管"的状态 —— 这既不干净也不常规。

## 3. 实现时的三个内核坑（每个都卡过一轮）

`scripts/lib/gpu.sh` 的 `wb_gpu_reset_cycle` 里对应三条：

### 坑 1：`ids=` 让 vfio-pci 在解绑瞬间抢回设备

`/etc/modprobe.d/vfio.conf` 里有 `options vfio-pci ids=1002:13c0,1002:1640`，
vfio-pci 注册了动态 ID → 设备一被 unbind，**内核立刻又匹配回 vfio-pci**，
amdgpu 永远没机会绑定。现象：脚本打印 `解绑 0000:0d:00.0 -> vfio-pci`（没变）。

**修法**：解绑前先把 `driver_override` 指向**目标驱动**：

```bash
echo amdgpu > /sys/bus/pci/devices/0000:0d:00.0/driver_override
echo 0000:0d:00.0 > /sys/bus/pci/devices/0000:0d:00.0/driver/unbind
```

### 坑 2：unbind 之后内核**不会自动重新匹配驱动**

设备变成"无驱动"就停在那里。**修法**：显式触发 probe：

```bash
echo 0000:0d:00.0 > /sys/bus/pci/drivers_probe
```

（这是 `driver_override` 工作流的经典要求，漏了就会看到设备一直 `(无驱动)`、
日志里连一条 probe 记录都没有。）

### 坑 3：unbind 文件里要写**设备名**，不是驱动名

```bash
echo 0000:0d:00.0 > /sys/bus/pci/devices/0000:0d:00.0/driver/unbind   # ✓
echo amdgpu        > …/driver/unbind                                   # ✗ → "No such device"
```

## 4. 成功后的证据

```
$ sudo bash -c 'source scripts/lib/gpu.sh; wb_conf_load; wb_gpu_reset_cycle' 2>&1 | tee /tmp/reset-cycle.log
=== [2/4] 等 amdgpu 完成初始化（最多 30s）===
  ✓ amdgpu 已绑定（1s）
  --- dmesg: amdgpu 相关尾部 ---
    amdgpu 0000:0d:00.0: ring gfx_0.1.0 uses VM inv eng 1 on hub 0
    amdgpu 0000:0d:00.0: ring sdma0 uses VM inv eng 13 on hub 0
    amdgpu 0000:0d:00.0: [drm] Initialized amdgpu 3.64.0 for 0000:0d:00.0 on minor 1
    amdgpu 0000:0d:00.0: [drm] fb1: amdgpudrmfb frame buffer device
=== [3/4] 解绑 amdgpu（触发 MODE2 reset）===
  ✓ 已解绑（复位已发生）
    amdgpu 0000:0d:00.0: finishing device.
    amdgpu 0000:0d:00.0: MODE2 reset        ← ★ 真复位
=== [4/4] 交回 vfio-pci ===
  0000:0d:00.0 -> vfio-pci (override=vfio-pci)
```

顺带一个重要结论：**amdgpu 能把核显完整跑起来**（rings/SDMA/VCN/显示引擎/fb 全 OK）
→ 证明硬件与固件没问题，客机侧的问题一定是"环境/状态"层面的。

## 5. 自动化（免冷启动）

**不用钩子、也不装服务**：复位是 `winbox vm start` 里的前置步骤（脚本位置：
`scripts/bin/vmctl` 的 `start` 分支；实现：`scripts/lib/gpu.sh` 的 `wb_gpu_reset_cycle`）。

```bash
sudo ./winbox vm start        # 直通姿态下会先复位（多等 20–30 秒是故意的）
```

设计要点：
- **必须自己 `modprobe amdgpu`**：宿主不会自动加载它（设备被 vfio-pci 认领；黑名单也拦不住显式 modprobe），
  若钩子只写 `driver_override` + `drivers_probe`，冷启动后的第一次启动会因为"驱动不存在"
  直接跳过复位（实测踩过：日志出现 `WARN: amdgpu 未绑定（当前 (none)），本次跳过复位`）。
  好在冷启动后第一次启动本来就干净，真正需要复位的是**后续每次启动**；
- 在 `prepare begin` 阶段执行（此时域尚未真的跑起来，设备仍归宿主）；
- **永远 `exit 0`** —— 钩子失败绝不能阻止 VM 启动；
- 日志写 `/var/log/lg-igpu-reset.log`；
- 代价：每次启动 VM 多等约 10-30 秒（复位耗时）—— 这是刻意的。

## 6. 备注：被排除的替代方案

| 方案 | 为什么不用 |
|---|---|
| `vendor-reset` 内核模块 | 官方与社区实测均指出已过时；支持的设备列表老旧（新核显不在内） |
| `RadeonResetBugFix`（Windows 服务） | 需要 VM 里存在虚拟显卡（与 `video=none` 冲突）；且社区认为当前版本场景下无必要 |
| 自己 `echo 1 > …/reset` | 核显不支持 FLR，会得到 `Inappropriate ioctl for device` |

（`scripts/lib/gpu.sh` 里还留了一个"PCI remove + rescan"的尽力而为版本，
但**可靠的只有 `MODE2 reset` 那条路**：要么手动跑 22 号脚本，要么用 25 号钩子。）
