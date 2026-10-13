# 链 06：ROM 处理（C · romtool）

> 存在理由：把「解析二进制结构 + 校验 + 合并」交给 shell 是自找麻烦。此链是**唯一**的 C 代码，其余全是 bash。

## 6.0 公共前置（所有子命令）

```
romtool <cmd>()
    解析参数（用法错 → 码 2）
    读文件（不可读 → 码 1）→ mmap/read 到内存
    parse_rom(buf, len):
        断言前两字节 == 55 AA                    → 否则码 2 ★ 不猜、不"尽量解析"
        首个 PCIR 结构定位（偏移 0x18 指向的指针链）
    失败时输出"已扫描范围 + 期望签名"，便于人工判断文件是否被截断
```

## 6.1 `romtool info FILE [--json]`

```
romtool info()
    公共前置
    print ROM 头: 镜像大小字段 / code type / 是否 last image
    walk_pcir_chain():
        for each image:
            vendor:device / class code / image length / indicator
            if 有 ATOM 签名: 打印 ATOM 版本与偏移
    输出两个 SHA256（整个文件 / 各镜像）
    终止(码 0)
```

## 6.2 `romtool verify FILE`

```
romtool verify()
    公共前置
    for each image in walk_pcir_chain():
        check 长度字段 == 实际镜像长度              → FAIL
        check sum(bytes) & 0xFF == 0（~0 校验和）    → FAIL（打印期望值与实际值）
        check PCIR 链终止条件（最后一枚 indicator.last_image 置位）
    check 文件总长 % 512 == 0                      → FAIL
    打印逐项结果 + "VERIFY: OK|FAILED"
    终止(码 0 / 1)        ★ 退出码即结论——被 lib/*.sh 与 make test 直接使用
```

**用途**：被 `winbox gpu-attach` 在部署 ROM 前调用（不合格就拒绝挂载，避免"改完 XML 才发现 ROM 是坏的"）。

## 6.3 `romtool patch --vendor HHHH --device HHHH [--class HHHH] IN OUT`

```
romtool patch()
    公共前置（IN）
    verify(IN) 失败 → 警告但继续（允许修一个坏 ROM）
    定位匹配的 PCIR（多处匹配时全部列出并让用户确认；仅一处则直接改）
    改 vendor/device（可选 class）
    重算该镜像校验和 + 更新长度字段（若长度需变）
    写 OUT：temp + rename          ★ 原子性；IN == OUT 时也安全
    打印改动前后对照表（含新指纹）
    终止(码 0 / 1 / 2)
```

**恢复的历史能力**：原 `patch-rom-ids.py`（给提取的 GOP ROM 盖上本机核显 ID）的唯一用途。

## 6.4 `romtool merge --vbios A [--gop B] OUT`

```
romtool merge()
    verify(A) 必须 OK；B 提供时必须 OK               → 不满足则码 1
    if A 已有 last_image 置位:
        清除该位（后面要追加镜像）
    追加 B 的内容（按 512 对齐）
    更新 A 的头长度字段与 indicator（最后一枚置 last_image）
    重算校验和
    写 OUT（temp+rename）
    print 结果结构报告（等同 info）
    ★ 不做任何"发明"式改写：不合成结构、不猜字段
    终止(码 0 / 1 / 2)
```

**边界声明**：本命令解决"核显在 UEFI 下需要 GOP、而提取到的 ROM 只有 legacy 部分"这类**机械拼装**问题；它不解决签名、不解决 ID 语义——那属于 `patch`。

## 6.5 `romtool dump --bdf DDDD:BB:DD.F OUT [--vendor HHHH --device HHHH]`

```
romtool dump()
    if 非 root → 码 3（需写 rom 的 enable 位）
    BDF ← 参数，或由 --vendor/--device 自动定位（在 /sys/bus/pci/devices/* 中扫描）
    读取:
        echo 1 > .../rom            （开启解码）
        read .../rom → buf
        echo 0 > .../rom            （★ 失败路径也要恢复：atexit/信号处理里做）
    断言 buf 是合法 ROM 头
    写 OUT（temp+rename，root 拥有 + 0644）
    print 指纹
    终止(码 0 / 3 / 4)
```

**注意**：在部分平台（如 APU 的 VFCT 路径）读出的 ROM 与真实 VBIOS 不完全一致——`info` 输出必须如实展示结构，让使用者自己判断，而不是宣称"这就是正确 ROM"。

## 6.6 `romtool extract --from BIOS.IMG [--list] OUT`

```
romtool extract()
    扫描 BIOS.IMG（如 ASUS .CAP）中的所有 ROM 候选:
        for offset where buf[i]=='U' && buf[i+1]==0xAA:
            尝试 parse_rom → 收集 候选（偏移 / 大小 / ID / ATI 或 GOP）
    --list: 只列出候选表（含偏移与 ID），不导出
    否则: 按索引/唯一候选导出到 OUT（temp+rename）
    未找到候选 → 码 1（打印已扫描范围）
    终止(码 0 / 1)
```

## 6.7 测试（`make test`）

```
make test()
    build 一个合成 A 镜像: 55AA 头 + PCIR(vendor=1002 device=fffe) + 正确校验和
    build 一个合成 B 镜像（GOP 风格）
    build 一个损坏样本: 校验和错（翻转一字节）
    断言: verify(A)==0; verify(坏)==1; info(A) 含期望字段
           patch(A) → verify(OUT)==0 且 ID 已变
           merge(A,B) → verify(OUT)==0 且镜像数 +1
    ★ 全部样本由源码生成（tools/mkrom.c 或内联），仓库内不留任何 AMD 二进制
```
