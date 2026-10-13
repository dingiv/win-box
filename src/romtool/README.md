# romtool

AMD PCI ROM 的**结构解析 / 校验 / 改 ID / 合并 / 提取**。win-box 的 C 辅助工具。

> 为什么单独写一个 C 工具：这些事用 `shell + od` 做既不可读也不可靠
> （遍历 PCIR 链、算校验和、合并且保持头部字段自洽）。这是 win-box 里唯一用 C 的地方。

## 构建与测试

```bash
make            # 构建 romtool 与测试用生成器 tests/mkrom
make test       # 离线自测（52 条断言），不需要硬件、不需要 root
make install PREFIX=~/.local
```

`make test` 的样本**全部由 `tests/mkrom` 现场生成**（合成 ROM、损坏样本、双映像链），
仓库里不含任何 AMD 二进制 —— 这是能把工具放进公开仓库的前提。
密码学部分会与系统 `sha256sum` 对拍。

## 用法

```
romtool info    FILE [--json]              结构报告：头 / 每个映像的 PCIR / ATOM 签名与横幅 / SHA256
romtool verify  [--strict] FILE            结构校验（致命）+ 校验和（默认仅警告）
romtool patch   [--vendor HHHH] [--device HHHH] [--class HHHHHH]
                [--fix-checksum] [--dry-run] IN OUT
romtool merge   --vbios A [--gop B] OUT    把 GOP 镜像追加到 legacy VBIOS 之后
romtool dump    --bdf DDDD:BB:DD.F OUT [--vendor HHHH --device HHHH]
romtool extract --from BIOS.IMG [--list] [--index N] OUT
```

退出码：`0` 成功、`1` 能读但不合格、`2` 用法错误、`3` 文件不可读、
`4` 设备无 ROM、`5` 写失败。

在 win-box 里更常用的入口是包装命令（会按需自动构建，并支持裸文件名解析到
`WB_VBIOS_DIR`）：

```bash
winbox rom info  vbios_ref_9800x3d.bin
winbox rom verify --strict AMDGopDriver_9800x3d_plain.rom
sudo winbox rom dump --bdf 0000:0d:00.0 ~/igpu.rom
```

## 两个来自实测的语义（照 spec 想当然会写错）

**① `verify` 默认宽容校验和。** 实测：参考 VBIOS（44544 字节）校验和为 0（规范），
但所有 EFI/GOP 镜像分别是 48 / 60 / 103 / 127 / 186 —— **不合格却照常工作**，
QEMU/libvirt 也不校验。把校验和当硬失败，工具就会对着能用的 ROM 报错。

**② `patch` 默认不改校验和（`--fix-checksum` 才改）。** 社区的 GOP 盖章流程只改 PCIR 里的 ID、
不动校验和，其产物是验证过能用的；我们若"顺手修好"，就会产出一个与验证过的镜像
**逐字节不同**的文件。规则：原镜像合格则保持合格，原就不合格则保持原样（`merge` 同理）。

另有一条踩过的坑：头部 size 字节（0x02）**属于第一个映像**，改它会让该映像校验和失效 ——
`merge` 里的重算逻辑就是为它写的。

## 许可

GPL-2.0-or-later（与 win-box 一致）。纯 C99 + libc，无第三方依赖。
