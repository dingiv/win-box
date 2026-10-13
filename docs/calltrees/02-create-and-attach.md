# 链 02：建机与直通挂载

## 2.1 `winbox vm-create [--name … --memory … --vcpus … --disk … --iso …]`

```
winbox vm-create()
    wb_conf_load()
    参数默认值 ← wb_conf_get_default（名字/内存/vCPU/磁盘/ISO 路径）
    wb_require_cmd(virt-install)                    → 码 3
    wb_have_cmd(qemu-img) 与 ISO 存在性               → 码 3

    if [virsh dominfo $VM] 成功:
        终止(码 2, "VM 名已存在")                    ★ 拒绝覆盖，绝不"删除重建"

    wb_run virt-install:
        --machine q35 --features smm=on
        --boot uefi,firmware.feature0/1 = secure-boot / tpm
        --tpm backend.type=emulator
        --disk path=…,bus=sata                  ★ SATA + e1000e = Windows 免驱
        --network model=e1000e
        --os-variant win11
        --graphics spice                          # 初始为取证模式，gpu-attach 会改
    wb_xml_dump()                                   # 备份初始定义
    验证: virsh dumpxml | 断言 firmware/tpm/smm 三件都在
    终止(码 5, "需人工在图形控制台安装 Windows", 打印 vmctl eject 提示)
```

**为什么用 SATA/e1000e 而不是 virtio**：先拿到一个「零驱动依赖」的可安装环境，virtio 是后续优化（`docs/zh/08-性能与调优待办.md`）。

## 2.2 `winbox gpu-attach [--rom FILE] [--audio-rom FILE] [--mode test|inspect|lg]`

```
winbox gpu-attach()
    wb_conf_require(VB_VM_NAME, WB_GPU_BDF, WB_VBIOS_DIR)
    wb_xml_require_stopped()                        → 码 3 ★ 必须先 ACPI 关机

    wb_step 1/5 硬件复核（防止配置写的是另一台机器）
        wb_detect_igpu() → 断言 WB_GPU_BDF 仍在           → 码 4
        if AUDIO_BDF 存在: 断言其与 GPU_BDF 同槽

    wb_step 2/5 ROM 检查与部署
        for rom in {GPU_ROM, AUDIO_ROM}:
            wb_run romtool verify rom ?                 ★ 不合格 → 码 1（不进后续）
        wb_gpu_deploy_rom(SRC, WB_VBIOS_DIR/NAME)
            install -o libvirt-qemu -g kvm -m 644
            sha256 比对（拷贝前后一致才继续）
            打印指纹（前 16 位 + 大小）

    wb_step 3/5 备份 + 挂载
        wb_xml_dump(logs/<stamp>-before-gpu-attach.xml)
        wb_vm_detach_igpu()                             # 幂等: 先清旧的
        wb_vm_attach_igpu(GPU_ROM, AUDIO_ROM):
            注入专属 pcie-root-port（不与其它设备共用）
            hostdev 1: VGA 功能, 00:00.0, multifunction=on, rom file=GPU_ROM, rom bar=on
            hostdev 2: 音频功能, 00:00.1, rom file=AUDIO_ROM
            video = none                                # 与 x-vga 配合见下
    wb_step 4/5 显示模式（决定 x-vga）
        case mode:
            test:    video=none + x-vga=on    # 核显是唯一 Primary，物理显示器为判据
            inspect: QXL + x-vga=off          # 能在 SPICE 里看设备管理器
            lg:      video=none + x-vga=off   # ★ 与 LG IDD 搭配的正确形态：
                                              #   核显作为"非启动显示适配器"，
                                              #   避开 STATUS_GRAPHICS_NOT_POST_DEVICE_DRIVER
    wb_step 5/5 回读验证
        wb_vm_verify_xml() → domxml-to-native qemu-argv | grep rom/x-vga/ivshmem
    终止(码 0, 提示: 启动 VM 前需核显归 vfio-pci；第二次启动失败见 docs/zh/03)
```

**三种模式的存在理由**（写进 `--help`，否则使用者会以为 `lg` 才是"正确"的）：

| 模式 | 用途 | 判据 |
| --- | --- | --- |
| `test` | 判定代码 43 是否修好 | 物理显示器出画 |
| `inspect` | 看客机内部状态（设备管理器、事件查看器） | SPICE 窗口 |
| `lg` | 日常使用 | Looking Glass 窗口 |

**关键约束**：`lg` 模式下**没有**虚拟显卡也**不是** Primary GPU——这是让 AMD 驱动愿意加载的前提（绕过「非 POST 设备驱动」检查）；也正因如此，`lg` 模式不能用 SPICE 窗口判断成败。
