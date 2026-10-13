# 接口契约：`romtool`（C 工具）

> 形式：CLI，C99 + make，无第三方依赖。
> 存在的理由：**shell 不适合做二进制结构解析**——用 `dd`/`od` 拼 ROM 的校验和、遍历 PCI Data Structure 链、合并 legacy VBIOS 与 GOP 镜像，既不可读也不可靠。

## 签名

```
romtool <子命令> [选项] [文件…]
```

全局：`--json`（机器可读输出）、`-q`（静默，只有错误）、`--help`、`--version`。

## 子命令契约

### `romtool info FILE [--json]`

- **输入**：一个 PCI/ATI ROM 镜像文件
- **输出**：人类可读结构报告——PCI ROM 头（签名 `55AA`、镜像大小）、**遍历所有 PCIR 结构**
  （vendor:device、class code、image length、indicator）、每映像校验和、ATOM 签名与偏移、
  `ATOMBIOSBK...` 横幅（识别 VBIOS 来源最有用）、整个文件的 SHA256；`--json` 输出同构 JSON
- **失败**：码 3 = 文件不可读；码 1 = 不是合法 ROM（缺 `55AA` 签名或链损坏）——**不猜**
- **生命周期**：纯只读

### `romtool verify [--strict] FILE`

- **输入**：同上
- **输出**：逐项检查（头部声明大小一致 / 文件大小为 512 倍数 / 各映像校验和 / 映像长度覆盖全文件 /
  PCIR 链以"最后映像"标志正确终止）；结论行 `VERIFY: OK` 或 `VERIFY: FAILED`
- **失败**：码 1 = 结构问题（**退出码即结论**）；校验和问题默认只警告，`--strict` 时也返回码 1
- **生命周期**：纯只读；`make test` 用它验证合成 ROM 与破坏样本

### `romtool patch --vendor HHHH --device HHHH [--class HHHHHH] [--fix-checksum] [--dry-run] IN OUT`

- **输入**：目标 ID 与输入输出文件（`OUT` 可与 `IN` 同）
- **输出**：写入 `OUT`，并逐映像打印改动前后对照；**默认不动校验和**（见下文"实测真相"），
  需要规范合格加 `--fix-checksum`；`--dry-run` 只打印不落盘
- **失败**：码 1 = 找不到 PCIR 结构；码 3 = 输入不可读；码 5 = 输出不可写
- **生命周期**：单文件转换；`OUT` 写入采用 temp+rename（不留半成品）
- **说明**：这是「给自己机器提取的 GOP ROM 盖真实 ID」的正规化版本（原为 `patch-rom-ids.py`）

### `romtool merge --vbios A [--gop B] OUT`

- **输入**：legacy VBIOS 镜像 + 可选 GOP 镜像
- **输出**：合并后的单文件 ROM（GOP 镜像追加在 VBIOS 之后，长度字段与 indicator 位按规范更新），并打印结果结构报告
- **失败**：码 1 = 输入结构不兼容（列出不兼容原因）；码 2 = 参数缺失
- **生命周期**：单文件转换，temp+rename
- **范围**：只做**机械合并 + 规范一致性修正**，不做"发明"式改写；合并后必须 `romtool verify` 通过

### `romtool dump --bdf DDDD:BB:DD.F OUT [--vendor HHHH --device HHHH]`

- **输入**：PCI 地址（或 `--vendor/--device` 让工具自行定位）；`OUT` 输出文件
- **输出**：从 `/sys/bus/pci/devices/<BDF>/rom` 提取 VBIOS（自动 `enable` → 读 → 恢复）
- **失败**：码 3 = 非 root（读取需要写 `rom` 的 enable 位）；码 4 = 设备不存在/无 ROM
- **生命周期**：**有副作用**（临时开启设备的 ROM 解码并恢复）；失败路径也要尝试恢复
- **说明**：这是「提取本机核显 VBIOS」的正规化版本（原为外部 `vbios-dumper`）

### `romtool extract --from BIOS.IMG OUT`

- **输入**：主板/显卡 BIOS 镜像（如 ASUS `.CAP`）
- **输出**：从镜像中按签名扫描出候选 ROM 列表（偏移 + 类型 + ID），用户选定后导出到 `OUT`
- **失败**：码 1 = 未找到任何候选（打印已扫描范围）
- **生命周期**：纯只读扫描 + 单文件导出

## 通用语义

1. **绝不修改输入文件**（`IN == OUT` 时走 temp+rename 保证原子性）。
2. **绝不静默接受不合规输入**：解析出问题就报错，不用"容错"掩盖。
3. **所有子命令都可离线运行**，不访问网络。
4. `make` / `make test` / `make install PREFIX=…`（安装到 `~/.local/bin`）。
5. **测试用合成 ROM**：`make test` 用仓库内自造的、结构合法的小 ROM 与损坏样本，**不含任何 AMD 二进制**。

## 退出码（全命令统一，实测后定稿）

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | **能读但不合格**（`verify` 的结论；`info` 遇到非 ROM 文件也算） |
| 2 | 用法错误 |
| 3 | 文件不可读 / 不存在 |
| 4 | 设备不存在或无 ROM（`dump`） |
| 5 | 写文件失败 |

## 两个「spec 直觉 vs 实测真相」的决定（很重要）

在真实 ROM 上验证后定下的语义，照着 spec 想当然会写错：

**① `verify` 默认宽容校验和，`--strict` 才当失败。**
实测：参考 VBIOS（44544 字节）校验和为 0（规范），但所有 EFI/GOP 镜像（4096–87040 字节不等）
校验和分别是 48 / 60 / 103 / 127 / 186 —— **不合格却照常工作**，QEMU/libvirt 也不校验。
若把校验和当硬失败，工具会对着能用的 ROM 报错。

**② `patch` 默认不改校验和，`--fix-checksum` 才改。**
社区的 GOP 盖章流程只改 PCIR 里的 ID、不动校验和，其产物是**验证过能用**的；
我们若"顺手修好"就会产出一个与验证过的镜像逐字节不同的文件。
规则：**原镜像合格则保持合格，原就不合格则保持原样**（`merge` 同理）。

> 另：改头部 size 字节（0x02，它属于**第一个映像**）会让该映像校验和失效 —— 合成测试里
> 踩过这个坑，`merge` 的重算逻辑就是为它写的。
