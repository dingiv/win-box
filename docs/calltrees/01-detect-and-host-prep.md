# 链 01：探测与宿主准备

## 1.1 `winbox detect [--write]`

```
winbox detect()
    wb_conf_load()                          # 有旧配置先读，用于保留用户手改的键
    if ! wb_detect_iommu():                 # /sys/kernel/iommu_groups 为空？
        终止(码 4, "IOMMU 未启用", 提示内核参数)        ★ 无 IOMMU 后面全无意义，早失败

    candidates = wb_detect_igpu()           # 扫 class 0x030000 + vendor 1002 的全部功能
    if candidates 为空:
        终止(码 4, "未找到 AMD 核显", 附 lspci 候选列表)  ★ 不猜、不降级

    VGA_BDF, AUDIO_BDF = 从 candidates 分类（VGA 功能 + 其同槽的 HDMI 音频）
    if AUDIO_BDF 缺失:
        ⚠ 警告（许多机器确实没有 HDMI 音频功能）→ 后续 gpu-attach 跳过音频

    IOMMU_GROUP = wb_detect_iommu_group(VGA_BDF)
    if IOMMU_GROUP 与其它设备共享:
        ⚠ 警告并列出同组设备（ACS 覆盖问题）  ★ 仅报告，不阻止——是否可用由人判断

    roms      = wb_detect_vbios_roms(VGA_BDF)         # 只在 WB_VBIOS_DIR 里找
    submods   = wb_detect_submodules()               # third_party/ 是否已 init
    tools     = wb_detect_libvirt_tools()            # virsh/virt-install/virt-viewer
    kvmfr     = wb_kvmfr_check()                     # 已装? 设备类型对不对?

    print 探测表（含每一项的来源与影响）
    if --write:
        for key, value in 探测结果: wb_conf_set(key, value)   # 原子写 + 备份
        ... (dry-run 时只打印)
    if submods == missing:
        ⚠ 提示: git submodule update --init --recursive
    终止(码 0, 并打印"建议下一步": host-prep 或 lg-prepare)
```

**为何探测结果要给人看而不是直接吞**：核显的 BDF、IOMMU 分组、ROM 现状是"这台机器能不能做直通"的全部判据，用户必须先看到它们再做决定。

## 1.2 `winbox host-prep`

```
winbox host-prep()
    wb_require_root()
    wb_require_cmd(apt-get, update-initramfs, modprobe)     # 不满足 → 码 3
    if ! 发行版在支持列表: 终止(码 3, "仅支持 Debian/Ubuntu 系")

    wb_step 1/6 依赖
        for pkg in qemu-system-x86 libvirt-daemon-system virtinst
                   ovmf swtpm swtpm-tools dkms build-essential \
                   cmake libgmp-dev ... :
            if ! dpkg -s pkg:                     ★ 逐包检查 = 幂等
                wb_run apt-get install -y pkg
    wb_step 2/6 服务
        systemctl enable --now libvirtd
        virsh net-start default / net-autostart default（若未启动）
        pool default 存在性
    wb_step 3/6 vfio 模块配置
        写 /etc/modprobe.d/vfio.conf:
            options vfio-pci ids=<GPU_ID>,<AUDIO_ID>
            softdep amdgpu pre: vfio-pci
            softdep snd_hda_intel pre: vfio-pci
        写 /etc/modules-load.d/vfio-pci.conf
        ★ softdep 的作用：让 vfio-pci 在 amdgpu 之前拿到设备（否则驱动抢占）
    wb_step 4/6 initramfs
        从 /etc/initramfs-tools/modules 删除 amdgpu 行
        ★ 关键：blacklist 只挡 alias 自动加载，挡不住这里写的显式 modprobe；
          真正让宿主拿不到核显的是 `options vfio-pci ids=` 的"抢先认领"（配合 vfio_pci 在此表里）
        ★ 顺带清理: 只保留真的需要的模块，减小 initramfs（便于观察是否生效）
        wb_run update-initramfs -u -k all
    wb_step 5/6 内核参数
        比对 /etc/default/grub 里的 GRUB_CMDLINE_LINUX_DEFAULT
        缺则加: amd_iommu=on iommu=pt initcall_blacklist=sysfb_init
                video=efifb:off video=vesafb:off
        wb_run update-grub
    wb_step 6/6 用户组
        usermod -aG kvm,libvirt <调用者>（通过 SUDO_USER 识别）

    if 检出任一"改动需重启才生效":
        终止(码 5, "请重启宿主后再继续", 打印重启后自检命令)
    终止(码 0, "下一步: winbox vm-create")
```

**校验点**（重启后由 `winbox status` 验证）：`lsmod | grep amdgpu` 为空、`lspci -nnk` 显示核显已归 vfio-pci。
