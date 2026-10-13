# 链 05：自检与取证

## 5.1 `winbox status [--host|--guest|--lg] [--json]`

```
winbox status()
    wb_report_section(宿主: 核显归属)
        for BDF in {WB_GPU_BDF, WB_AUDIO_BDF}:
            drv = wb_pci_driver(BDF)
            if drv == vfio-pci: item(ok)
            else:               item(bad, "应绑 vfio-pci", 提示 sudo ./winbox host-gpu passthrough)
        if [lsmod | grep ^amdgpu]:
            item(warn, "amdgpu 已加载于宿主", "若核显在 vfio-pci 上属正常残留")
    wb_report_section(宿主: 内核与固件)
        IOMMU 分组是否独占（共享 → warn，附同组设备）
        ROM 指纹: wb_gpu_rom_fingerprint(WB_VBIOS_DIR/*)   # 期望与配置记录一致
    wb_report_section(宿主: KVMFR / LG)
        kvmfr 模块加载 → /dev/kvmfr0 是字符设备
        客户端二进制存在且可执行
        客户端进程是否在运行（pgrep，用于"窗口是否开着"）
    wb_report_section(libvirt)
        domain 状态；XML 关键项回读（rom file / x-vga / ivshmem 参数 / video=none）
        amdgpu 模块是否可用（vm start 的复位前提：modinfo -n amdgpu）
    wb_report_section(客机)
        if ! wb_guest_ready(): item(warn, "无 SSH 通道，跳过客机检查")
        else:
            gpu = wb_guest_gpu_status() → Status=OK/? ; ErrCode=0/?
            idd = wb_guest_idd_status() → 版本 + 工作模式(hw/sw)
    wb_report_result()                       # 返回值 0 / 6 / 7
    终止(码 = 结论: 0 全绿 / 6 有警告 / 7 有故障)
```

**判定规则**：任一 `bad` → BROKEN(7)；只有 `warn` → DEGRADED(6)；全 `ok` → OK(0)。

**注意**：`status` 是**唯一**用退出码承载结论的命令（用户已定案）。因此文档与 README 必须提示：在 `set -e` 脚本里串联时显式处理，或用 `--json` 自行判断。

## 5.2 `winbox evidence [--out DIR] [--after]`

```
winbox evidence()
    DIR ← 参数 或 logs/evidence-<stamp>/
    mkdir -p DIR → 不可写则码 1

    if 非 root: item(warn, "缺 root，dmesg/部分 sysfs 项跳过")   ★ 不失败

    采集（每项独立子文件，任一项失败不影响其它）:
        01-lspci.txt            lspci -nnk / -vvv（核显两功能）
        02-driver-binding.txt   driver_override / driver / modalias
        03-iommu.txt            IOMMU 分组、同组设备
        04-rom.txt              ROM 文件指纹 + romtool info 输出
        05-libvirt.xml          virsh dumpxml
        06-qemu-argv.txt        domxml-to-native qemu-argv | grep 关键参数
        07-kvmfr.txt            dmesg kvmfr / 设备类型 / 尺寸
        08-dmesg-gpu.txt        dmesg | grep -iE 'amdgpu|vfio|reset'
        09-reset.log            /var/log/winbox-reset.log 尾部（vm start 每次启动前写入）
        10-guest.txt            wb_guest_* 报告（无 SSH 则写说明）
        11-versions.txt         内核 / QEMU / libvirt / LG 客户端版本
    if --after: 追加"关机后"快照（与运行中对比最能看出复位问题的差异）
    wb_evidence_manifest(DIR) → manifest.txt（文件清单 + sha256）
    终止(码 0)
```

**为什么保留"运行中"与"关闭后"两份**：复位 bug 的特征恰恰是**关机后设备状态被弄脏**——两份对比是唯一能直接看到这一点的证据。
