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

> **机制（本项目最重要的架构决策）**：VM 定义由 `config/templates/domain.xml.in` **渲染**而来，
> 不做就地 XML 编辑。所以 `gpu-attach` / `lg-shmem` / `vm mode` 都不需要 XML 工具，
> 且本质上是同一个动作：**改配置键 → 渲染 → 备份 → `virsh define` → 回读校验 → 打印 diff**。
> 模板与片段的细节见 `docs/interfaces/04-lib-api.md` 的 `lib/xml.sh` 一节。

```
winbox gpu-attach()
    wb_conf_require(WB_VM_NAME, WB_GPU_BDF)
    wb_xml_require_stopped()                        → 码 3 ★ 必须先 ACPI 关机

    wb_step 1/5 前置检查
        VM 存在且 shut off；未满足 → 码 3（“先关机，别用 destroy”）

    wb_step 2/5 硬件复核（防止配置写的是另一台机器）
        wb_detect_igpu(WB_GPU_BDF) → 命中则打印 BDF/class/BAR
        同槽 HDMI 音频功能存在与否 → 打印（无则只挂 VGA）

    wb_step 3/5 ROM 准备
        ROM ← --rom 或 WB_VBIOS_DIR/WB_VBIOS_GPU
        不存在 → 码 3（提示 winbox rom dump）
        若 ROM 不在部署目录：
            非 root → 码 3（给出带 sudo 的完整命令）
            有 romtool → romtool verify（不合格仅警告）
            wb_gpu_deploy_rom()：install -o libvirt-qemu -g kvm -m 644 + sha256 比对 + 打印指纹

    wb_step 4/5 写键 + 重定义（= wb_vm_redeploy）
        wb_conf_set WB_VBIOS_DIR/WB_VBIOS_GPU/WB_VBIOS_AUDIO/WB_GPU_ATTACHED
        （--mode 时另写 WB_VIDEO_MODE）
        ↓ 渲染器按开关选片段：
            WB_GPU_ATTACHED=1        → igpu 片段（专属 root port + 双功能 hostdev + ROM 对）
            WB_VIDEO_MODE=test/both  → xvga-on 片段（核显=Primary；物理显示器为判据）
            WB_VIDEO_MODE=lg/inspect → 无 x-vga（核显=非启动显示适配器，避开 0xC01E0438）

    wb_step 5/5 结果
        wb_vm_redeploy 内部：快照警告/确认 → 备份 dumpxml → 渲染 → define →
                            回读 diff（改坏了怎么回去写在提示里）→ wb_vm_verify_xml
    终止(码 0, 提示：启动前用 winbox status --host 确认核显已归 vfio-pci)
```

**三种显示模式的存在理由**（写进 `--help`，否则使用者会以为 `lg` 才是“正确”的）：

| 模式 | 用途 | 判据 |
| --- | --- | --- |
| `test` | 判定代码 43 是否修好 | 物理显示器出画 |
| `inspect` | 看客机内部状态（设备管理器、事件查看器） | SPICE 窗口 |
| `lg` | 日常使用 | Looking Glass 窗口 |

**关键约束**：`lg` 模式下**没有**虚拟显卡也**不是** Primary GPU——这是让 AMD 驱动愿意加载的前提（绕过「非 POST 设备驱动」检查）；也正因如此，`lg` 模式不能用 SPICE 窗口判断成败。
