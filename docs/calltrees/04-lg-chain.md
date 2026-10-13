# 链 04：Looking Glass 全链

从"宿主还没准备"到"窗口里能用键鼠"，跨宿主与客机两侧。

## 4.1 `winbox lg-prepare [--size MB]`

```
winbox lg-prepare()
    wb_require_root()
    wb_xml_require_stopped()  → 码 3
    ★ 理由：kvmfr 必须先把 /dev/kvmfr0 建出来；如果 QEMU 先启动，它会把该路径
      创造成普通文件，之后模块再也建不出字符设备（LG 官方文档明确警告）

    wb_step 1/3 构建依赖
        dpkg -s 逐包检查 → 装 cmake / libgmp-dev / nettle-dev / libdw-dev
        / libunwind-dev / libxss-dev / libxpresent-dev / libpipewire-0.3-dev
        / libpulse-dev / libsamplerate0-dev / libusbredirparser-dev / libfuse3-dev
    wb_step 2/3 KVMFR 模块
        wb_kvmfr_install(SIZE_MB):
            if /dev/kvmfr0 存在但不是字符设备 → rm -f 后重新 modprobe（自愈）
            ["dkms install third_party/LookingGlass/module"]
            写 /etc/modprobe.d/kvmfr.conf        options kvmfr static_size_mb=N
            写 /etc/modules-load.d/kvmfr.conf    kvmfr
            写 /etc/udev/rules.d/70-kvmfr.rules  GROUP="kvm" MODE="0660"
            udevadm control --reload-rules
            modprobe kvmfr → 断言 /dev/kvmfr0 是字符设备
    wb_step 3/3 构建客户端
        wb_lg_build(WB_LG_SRC) → 产物 WB_LG_CLIENT(~/.local/bin/looking-glass-client)
        ★ 客户端与宿主的 AppArmor/cgroup 无关（那是 QEMU 侧的限制）
    终止(码 0, "下一步: winbox lg-shmem")
```

## 4.2 `winbox lg-shmem [--size MB] [--remove]`

```
winbox lg-shmem()
    wb_kvmfr_check()                     # /dev/kvmfr0 存在且为字符设备 → 否则码 3
    wb_xml_require_stopped()             → 码 3

    wb_vm_detach_shmem()                 ★ 幂等：先清同类 qemu:arg（保留其它 arg）
    wb_vm_attach_shmem(SIZE_MB):
        qemu:commandline 注入两条：
          -device {'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}
          -object {'qom-type':'memory-backend-file','id':'looking-glass',
                   'mem-path':'/dev/kvmfr0','size':SIZE_MB*1MiB,'share':true}

    ★ 权限双闸（漏一个就是 EACCES/EPERM）：
        AppArmor: /etc/apparmor.d/local/abstractions/libvirt-qemu 加 /dev/kvmfr0 rw
        cgroup:   /etc/libvirt/qemu.conf 的 cgroup_device_acl 加 /dev/kvmfr0
        （判据：EACCES → AppArmor/DAC；EPERM → cgroup eBPF 白名单）
    wb_vm_verify_xml()   # domxml-to-native 回读 ivshmem 参数
    终止(码 0, "下一步: 启动 VM 并在客机装 IDD")
```

## 4.3 `winbox lg [--] [客户端参数…]`

```
winbox lg()
    wb_require_file(WB_LG_CLIENT)         → 码 3（提示 lg-prepare）
    wb_kvmfr_check()                      → 码 3
    if client.ini 不存在: wb_lg_client_ini_write()
        传输 lgmp / shmDevice=/dev/kvmfr0（不能留空，空值会段错误）
        allowDMA=yes
        autoResize=no + setGuestRes=yes   ★ 二者语义冲突，只能选一
        [input] captureOnFocus=yes        ★ 多显示器下必须抓取模式：
                                          # 绝对定位走 SetCursorPos(桌面坐标)，
                                          # 有第二块屏时指针会跳到别的屏
                grabKeyboard / mouseRedraw=no
    ["looking-glass-client" 参数…]  （前台，Ctrl+C 结束）

    ── 客机侧（一次性，经 wb_guest_* 或人工） ──
    安装 IDD:  looking-glass-idd-setup.exe /S /ivshmem
    wb_idd_prefs_apply():
        ExclusiveMonitor   = 0     ★ 否则 IDD 会主动关掉其它显示器
        ForceIndirectCopy  = 1     ★ 走 D3D12 直传路径会让 AMD 驱动 Device Removed
        ForceFullDirectCopy= 0     ★ =1 会加重物理屏白方块
        重载 IDD 驱动
    wb_guest_gpu_status() → 期望 Status=OK / ConfigManagerErrorCode=0
    终止(窗口出画 + 键鼠可用)
```

## 4.4 失败分支速查（每条都对应一个 `wb_report_item` 检查项）

```
窗口黑 + DMA 报错      → 权限双闸（AppArmor / cgroup）
窗口黑 + 无 LGMP       → KVMFR 尺寸与 ivshmem size 不一致 / 客机 IDD 未运行
窗口出画但键鼠不能用   → 客机 IDD 的输入通道未起 / 需在窗口内点一下
指针跳到别的屏         → captureOnFocus / 抓取模式未开（多显示器）
物理屏出现白方块       → AMD 驱动缺陷（direct 路径）→ 已用 ForceIndirectCopy=1 减轻
"""
```

**两条设计约束**：

- **客户端配置写入是"首次生成，不覆盖"**：使用者手改过的 `client.ini` 不得被脚本重置（`--force` 才覆盖）。
- **客机侧动作全部可选**：没配 SSH 通道时，`lg` 链只做宿主侧，客机侧打印人工指引（不失败）。
