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
- **输出**：人类可读结构报告——PCI ROM 头（签名 `55AA`、镜像大小、code type）、**遍历所有 PCIR 结构**（vendor:device、class code、image length、indicator）、ATI/AMD 扩展签名（`ATOM`）与 ATOM 版本、两者的 SHA256
- **失败**：码 1 = 文件不可读；码 2 = 不是合法 ROM（缺 `55AA` 签名）——**不猜**
- **生命周期**：纯只读

### `romtool verify FILE`

- **输入**：同上
- **输出**：逐镜像报告：长度字段一致、`~0` 校验和正确、PCIR 链完整（最后一枚的 indicator 位）、ROM 总大小是 512 的整数倍；结论行 `VERIFY: OK|FAILED`
- **失败**：码 1 = 存在结构/校验问题（**退出码即结论**，便于脚本判据）——注意与「文件读不了」（码 3）区分：码 1 是"能读但不合格"
- **生命周期**：纯只读；`make test` 用它验证合成 ROM 与破坏样本

### `romtool patch --vendor HHHH --device HHHH [--class HHHH] IN OUT`

- **输入**：目标 ID 与输入输出文件（`OUT` 可与 `IN` 同）；`--class` 仅在需要时改
- **输出**：写入 `OUT`，**自动重算被改镜像的校验和**，打印改动前后对照
- **失败**：码 1 = 找不到 PCIR 结构；码 3 = 输出不可写
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
