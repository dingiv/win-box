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

## 6.3 `romtool patch --vendor HHHH --device HHHH [--class HHHHHH] [--fix-checksum] [--dry-run] IN OUT`

```
romtool patch()
    公共前置（IN）
    verify(IN) 有结构问题 → 警告但继续（允许修一个坏 ROM）
    逐映像比对 PCIR 里的 ID，不一致就改（打印每个改动点）
    校验和策略（实测决定，不是 spec 直觉）：
        原映像合格（和为 0）→ 改完重算回合格
        原映像就不合格（GOP 常见）→ 保持原样
        --fix-checksum → 不论原状，全部重算成合格
    写 OUT：temp + rename          ★ 原子性；IN == OUT 时也安全
    打印改动前后对照
    --dry-run → 只打印不落盘
    终止(码 0 / 1 / 2 / 3 / 5)
```

**为何默认不修校验和**：社区的 GOP 盖章流程只改 ID、不动校验和，产物是验证过能用的；
"顺手修好"会得到与验证过的镜像逐字节不同的文件。这条写进了 03-romtool.md 的契约。

**恢复的历史能力**：原 `patch-rom-ids.py`（给提取的 GOP ROM 盖上本机核显 ID）的唯一用途。

## 6.4 `romtool merge --vbios A [--gop B] OUT`

```
romtool merge()
    要求 A（以及 B）能解析，且 A 的各映像长度合计 == A 文件大小
    拷贝 A，再追加 B
    若给了 B：清掉 A 最后一个映像的 “最后映像” 标志（并按其原来的合规状态决定是否重算校验和）
    头部 size 字节（0x02）× 512 → 合并后总大小
        ★ 这个字节属于**第一个映像**，改完需要重算第一个映像的校验和（踩过的坑）
        超过 255*512 则保留原值并警告
    重解析合并结果：不合法、或最后映像标志未置位 → 拒绝写出
    打印结构报告（等同 info）
    终止(码 0 / 1 / 2 / 3 / 5)
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
