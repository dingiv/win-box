# 02 Looking Glass 部署与架构

> 目标形态：**宿主一个窗口里使用 Windows**，画面走共享内存（零拷贝、无编码），
> 键鼠直接从窗口进入客机，**核显 HDMI 不需要接显示器**。

## 1. 为什么要 Looking Glass（而不是 SPICE/VNC）

> **关于本文**：这是当时的**实录**（含走过的弯路与证据），不是使用说明。
> 命令已规整为本仓库的形式（`winbox …`）；接口以 `docs/interfaces/` 为准。

传统 SPICE/VNC 依赖 QEMU 侧的虚拟显卡（QXL/virtio-vga）来产生画面。对我们的场景有两条硬伤：

1. **虚拟显卡会和直通的核显抢 legacy VGA 资源**（`0x3b0-0x3df`、`0xa0000-0xbffff`）。
   实测（QXL + `x-vga=on`）：mtree 里两套区域互相抢占，核显驱动直接 43、物理屏停在固件画面。
   这也是 Proxmox 文档写「Primary GPU 必须 `vga: none`」的原因。
2. **没有视频通道时 SPICE 的鼠标失效**：spice-gtk 的鼠标模式（绝对/相对）要从显示通道推断，
   `video=none` 时报 `update_mouse_mode: code should not be reached`，键盘能用、鼠标不动。

Looking Glass 走的是另一条路：**让客机里的程序自己把帧写进共享内存，宿主再读出来显示**，
完全不经过 QEMU 的显示栈，所以不需要虚拟显卡、键鼠也不依赖 SPICE 显示通道。

## 2. 组件与版本（必须同版本）

| 组件 | 版本 | 位置 |
|---|---|---|
| LG 客户端 | `B7-829-cdba29f2`（bleeding，源码编译） | `~/.local/bin/looking-glass-client` |
| LG IDD（客机） | `B7-829-cdba29f2` | `guest/looking-glass-idd-setup.exe` |
| KVMFR 内核模块 | 0.0.12（DKMS） | `static_size_mb=128` |
| IVSHMEM | libvirt `qemu:commandline` 裸参数 | `sudo winbox lg-shmem` |

> 三个组件（客户端 / IDD / OBS 插件）**共享内存协议随版本变化，必须同一 release**。
> 我们用官网 `looking-glass.io/artifact/bleeding/{source,idd,host}` 同一批产物。

## 3. 数据通路

```
┌──────────── Windows 客机 ────────────┐      ┌──────── Linux 宿主 ─────────┐
│ DWM 渲染到 IDD 注册的虚拟显示器       │      │                             │
│        │                             │      │                             │
│ LGIdd.sys ──GPU 拷贝──► 传输内存      │      │                             │
│        │        （IVSHMEM 128MB）     │      │                             │
│        └──LGMP 帧队列发布─────────────┼─────►│ 客户端取最新帧               │
│                                      │      │   ├─ KVMFR DMA-BUF 导入 ──► NVIDIA 纹理（零拷贝）
│ 键鼠：宿主→LGMP 输入队列→IDD 输入驱动 │◄─────┼───┘  EGL 渲染到窗口           │
└──────────────────────────────────────┘      │                             │
   SPICE（可选）：音频 / 剪贴板 / 兜底         └─────────────────────────────┘
```

## 4. 共享内存方案：KVMFR（推荐）而不是 /dev/shm

LG 文档给了两种：`/dev/shm/looking-glass`（普通文件）与 **KVMFR 内核模块**。
选 KVMFR 的原因：它能把帧缓冲导出成 **DMA-BUF**，宿主 GPU 直接导入（零拷贝）。
普通文件方式客户端必须再拷一遍（CPU 占用和延迟都更高）。

```bash
# 宿主准备（sudo winbox lg-prepare）
apt install linux-headers-$(uname -r) dkms
cd third_party/LookingGlass/module && dkms install .
echo "options kvmfr static_size_mb=128" > /etc/modprobe.d/kvmfr.conf
echo "kvmfr" > /etc/modules-load.d/kvmfr.conf
cat > /etc/udev/rules.d/70-kvmfr.rules <<'EOF'
SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="uaccess"
EOF
modprobe kvmfr && ls -l /dev/kvmfr0     # 必须是字符设备 c 开头
```

**尺寸公式**（官方）：
`(宽按 256B 对齐 ×4B × 高) × 3（三缓冲） + 4MiB`，向上取 2 的幂。
常用：1080p=32MB、1440p=64MB、4K=128MB。**超配不提升性能，只白占宿主内存。**

**致命陷阱**：若 VM 先启动而模块未加载，QEMU 会把 `/dev/kvmfr0` 创建成**普通文件**，
之后模块再也建不出字符设备 → 必须先 `modprobe kvmfr`（已配置开机自动加载）。

## 5. VM 侧接线（libvirt）

官方文档用 `qemu:commandline` 传裸 QEMU 参数：

```xml
<qemu:commandline>
  <qemu:arg value="-device"/>
  <qemu:arg value="{'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}"/>
  <qemu:arg value="-object"/>
  <qemu:arg value="{'qom-type':'memory-backend-file','id':'looking-glass',
                     'mem-path':'/dev/kvmfr0','size':134217728,'share':true}"/>
</qemu:commandline>
```

配套（`sudo winbox lg-shmem` 幂等注入）。

## 6. 两个权限陷阱（都踩过，见 07 篇）

1. **AppArmor**：`abstractions/libvirt-qemu` 的白名单里有 `/dev/kvm`、`/dev/vfio/vfio`，
   但**没有 `/dev/kvmfr0`** → QEMU 打不开，报 `can't open backing store /dev/kvmfr0: Permission denied`
   （EACCES）。修：往 `/etc/apparmor.d/local/abstractions/libvirt-qemu` 追加 `/dev/kvmfr0 rw,`。
2. **cgroup v2 设备白名单**：libvirt 用 eBPF 按设备过滤，白名单来自 `qemu.conf` 的
   `cgroup_device_acl` + XML 中登记过的设备。我们用裸参数增加的 IVSHMEM，libvirt 不知情
   → 需要显式写入（`sudo winbox lg-shmem`）。

## 7. 客机侧：LG IDD（间接显示驱动）

```bash
# 静默安装（含 IVSHMEM 驱动）
looking-glass-idd-setup.exe /S /ivshmem
```

IDD 的作用：
1. **凭空造出一个显示器**（"Looking Glass"）→ 不需要物理显示器，也不需要 EDID 诱骗插头；
2. 通过 `IddCx` 拿到 DWM 的 swapchain → 拷进共享内存；
3. 安装包同时装**输入驱动**：LGMP 输入队列 → 直接注入 Windows（绝对定位/捕获模式）；
4. 附带托盘 helper（配置窗口分辨率、偏好、日志入口）。

**关键日志位置**（排障必备）：

```
C:\ProgramData\Looking Glass (IDD)\looking-glass-idd.txt           ← 渲染适配器/帧图/拷贝模式/IVSHMEM
C:\ProgramData\Looking Glass (IDD)\looking-glass-idd-service.txt   ← 服务与驱动控制
C:\ProgramData\Looking Glass (IDD)\looking-glass-input.txt         ← 键鼠直连
C:\ProgramData\Looking Glass (IDD)\looking-glass-idd-helper.txt    ← 配置/拓扑/通知
+ .1~.4 轮转副本
```

## 8. 宿主侧：客户端编译与运行

```bash
# 依赖（Debian/Ubuntu；官方清单漏了 libfuse3-dev，CMakeLists 里是 REQUIRED）
sudo apt install cmake libgmp-dev libspice-protocol-dev nettle-dev libdw-dev libunwind-dev \
  libxss-dev libxpresent-dev libpipewire-0.3-dev libpulse-dev libsamplerate0-dev \
  libusbredirparser-dev libfuse3-dev

# 构建（官方步骤：源码顶层没有 CMakeLists.txt，要在 client/ 下构建）
cd third_party/LookingGlass && mkdir -p client/build && cd client/build
cmake -DCMAKE_INSTALL_PREFIX="$HOME/.local" ../
make -j$(nproc) && make install
```

运行（`winbox lg` 封装；首次会生成 `~/.config/looking-glass/client.ini`）：

```ini
[app]
transport=lgmp
[lgmp]
shmDevice=/dev/kvmfr0     ; 必须写具体路径！留空会让 lgmp_deviceValidator 段错误
allowDMA=yes
[win]
autoResize=no             ; 与 setGuestRes 互斥（LG 不允许同时开）
keepAspect=yes
setGuestRes=yes           ; 窗口大小变化时请求客机跟随
[input]
captureOnFocus=yes        ; 多显示器场景必需（见 05/07 篇）
mouseRedraw=no
grabKeyboard=yes
```

成功启动的日志特征：

```
Using Transport : lgmp
Using Video     : LGMP
Using DMA buffer support                    ← KVMFR→DMA-BUF 零拷贝成功
Format: FRAME_TYPE_BGRA 1600x900 …          ← 收到帧
Using Input     : LGMP                      ← IDD 直连输入
Using Clipboard : LGMP
```

## 9. IDD 的必改偏好（`winbox lg --idd-prefs`）

注册表 `HKLM\SOFTWARE\LookingGlass\IDD`：

| 值 | 默认 | 设为 | 原因 |
|---|---|---|---|
| `ExclusiveMonitor` | 1 | **0** | 默认策略会**主动关掉其它显示器**（物理屏），导致"不能共存" |
| `ForceIndirectCopy` | 0 | **1** | direct 路径会让 AMD 驱动 **GPU 挂起**（见 05 篇），必需 |
| `ForceFullDirectCopy` | 0 | 0 | 开启后每帧写全量 → 白方块更严重 |

改了偏好后需要**重载 IDD 设备**才生效：`Disable-PnpDevice` / `Enable-PnpDevice`（或用 helper 里的 Save & reload driver）。
