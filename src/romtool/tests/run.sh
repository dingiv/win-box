#!/bin/sh
# code-master:title win-box · romtool · 离线测试
#
# 契约：docs/interfaces/03-romtool.md ／ 链路：docs/calltrees/06-romtool.md
#
# 全部用合成 ROM（由 tests/mkrom 生成），不需要硬件、不需要 root，
# 仓库里也不含任何 AMD 二进制。密码学部分额外与系统 sha256sum 对拍。
set -u

BIN=./romtool
MK=./tests/mkrom
TMP=./tests/tmp
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

expect_rc() {
  _desc=$1; _want=$2; shift 2
  _out=$("$@" 2>&1); _rc=$?
  if [ "$_rc" = "$_want" ]; then
    ok "$_desc"
  else
    bad "$_desc（期望退出码 $_want，实得 $_rc）"
    printf '%s\n' "$_out" | sed 's/^/      /'
  fi
}

expect_has() {
  _desc=$1; _text=$2; _needle=$3
  case "$_text" in
    *"$_needle"*) ok "$_desc" ;;
    *) bad "$_desc（未找到: $_needle）" ;;
  esac
}

expect_lacks() {
  _desc=$1; _text=$2; _needle=$3
  case "$_text" in
    *"$_needle"*) bad "$_desc（不应出现: $_needle）" ;;
    *) ok "$_desc" ;;
  esac
}

rm -rf "$TMP"
mkdir -p "$TMP"

printf '\n== 1. 生成合成 ROM ==\n'
for k in legacy-valid efi-valid legacy-badcsum efi-bad-ids two-images bad-signature truncated bios-image; do
  if "$MK" "$k" "$TMP/$k.rom" >/dev/null 2>&1; then ok "mkrom $k"; else bad "mkrom $k"; fi
done

printf '\n== 2. info（结构报告）==\n'
out=$("$BIN" info "$TMP/legacy-valid.rom" 2>&1)
expect_has 'info 打印 ID' "$out" '1002:13c0'
expect_has 'info 打印 codeType 名称' "$out" 'legacy(x86)'
expect_has 'info 打印映像长度' "$out" '4096'
out=$("$BIN" info "$TMP/two-images.rom" 2>&1)
expect_has 'info 认出两个映像' "$out" '映像数          : 2'
expect_has 'info 标出最后映像' "$out" '(最后)'
out=$("$BIN" info "$TMP/efi-valid.rom" --json 2>&1)
expect_has 'info --json 输出 JSON' "$out" '"code_type": 3'
expect_has 'info --json 含 sha256' "$out" '"sha256":'

printf '\n== 3. SHA-256 与系统工具对拍 ==\n'
mine=$(printf '%s\n' "$("$BIN" info "$TMP/two-images.rom" --json)" | sed -n 's/.*"sha256": "\([0-9a-f]*\)".*/\1/p')
theirs=$(sha256sum "$TMP/two-images.rom" | cut -d' ' -f1)
if [ "$mine" = "$theirs" ]; then ok "内建 SHA-256 与 sha256sum 一致"; else bad "SHA-256 不一致（$mine vs $theirs）"; fi

printf '\n== 4. verify（结构致命 / 校验和默认宽容）==\n'
expect_rc '合格 ROM 通过' 0 "$BIN" verify "$TMP/legacy-valid.rom"
out=$("$BIN" verify "$TMP/legacy-badcsum.rom" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok '校验和不合格但结构无误 → 默认通过（真实世界 EFI 镜像如此）'; else bad "默认应通过（实得 $rc）"; fi
expect_has '默认通过时明确提示校验和问题' "$out" '校验和'
expect_rc '--strict 时校验和不合格算失败' 1 "$BIN" verify --strict "$TMP/legacy-badcsum.rom"
expect_rc '缺签名 → 失败' 1 "$BIN" verify "$TMP/bad-signature.rom"
expect_rc '长度字段越界 → 失败' 1 "$BIN" verify "$TMP/truncated.rom"
expect_rc '双映像链正常 → 通过' 0 "$BIN" verify "$TMP/two-images.rom"
out=$("$BIN" verify --strict "$TMP/two-images.rom" 2>&1)
expect_has '双映像校验和均合格' "$out" 'VERIFY: OK'

printf '\n== 5. patch（改 ID；默认不动校验和）==\n'
expect_rc 'patch 模拟社区 GOP 的 ID' 0 "$BIN" patch --vendor 1002 --device 13c0 \
  "$TMP/efi-bad-ids.rom" "$TMP/patched.rom"
out=$("$BIN" info "$TMP/patched.rom" 2>&1)
expect_has 'patch 后 ID 已改' "$out" '1002:13c0'
# 原镜像不合格 → 默认不"修好"它（否则产物与社区验证过的盖章流程不一致）
expect_rc '默认不修校验和（--strict 仍失败即为证）' 1 "$BIN" verify --strict "$TMP/patched.rom"
expect_rc 'patch --fix-checksum 会修成合格' 0 "$BIN" patch --vendor 1002 --device 13c0 --fix-checksum \
  "$TMP/efi-bad-ids.rom" "$TMP/patched2.rom"
expect_rc '修过的 ROM --strict 也通过' 0 "$BIN" verify --strict "$TMP/patched2.rom"
expect_rc 'patch 原就合格的镜像仍保持合格' 0 "$BIN" patch --device 13c1 \
  "$TMP/legacy-valid.rom" "$TMP/patched3.rom"
expect_rc '（上一步产物 --strict 通过）' 0 "$BIN" verify --strict "$TMP/patched3.rom"
expect_rc 'patch --dry-run 不写文件' 0 "$BIN" patch --vendor 1002 --dry-run \
  "$TMP/legacy-valid.rom" "$TMP/should-not-exist.rom"
if [ -e "$TMP/should-not-exist.rom" ]; then bad '--dry-run 竟然写了文件'; else ok '--dry-run 确实没写文件'; fi

printf '\n== 6. merge（GOP 追加到 VBIOS 之后）==\n'
expect_rc 'merge legacy + efi' 0 "$BIN" merge --vbios "$TMP/legacy-valid.rom" \
  --gop "$TMP/efi-valid.rom" "$TMP/merged.rom"
expect_rc '合并结果结构校验通过' 0 "$BIN" verify "$TMP/merged.rom"
out=$("$BIN" info "$TMP/merged.rom" 2>&1)
expect_has '合并结果有两个映像' "$out" '映像数          : 2'
expect_has '合并结果头部大小已更新' "$out" '（与实际一致）'
expect_has '第一个映像不再是最后映像' "$out" 'indicator 0x00'
expect_has '第二个映像是最后映像' "$out" 'indicator 0x80(最后)'
expect_rc '不给 --gop 时只是规范化头部' 0 "$BIN" merge --vbios "$TMP/legacy-valid.rom" "$TMP/renorm.rom"
expect_rc '规范化结果仍合格' 0 "$BIN" verify "$TMP/renorm.rom"

printf '\n== 7. extract（从 BIOS 镜像里扫 ROM）==\n'
expect_rc '列出候选' 0 "$BIN" extract --from "$TMP/bios-image.rom" --list
out=$("$BIN" extract --from "$TMP/bios-image.rom" --list 2>&1)
expect_has '找到嵌在 0x600 的候选' "$out" '0x600'
expect_rc '导出唯一候选' 0 "$BIN" extract --from "$TMP/bios-image.rom" "$TMP/extracted.rom"
expect_rc '导出的 ROM 校验通过' 0 "$BIN" verify "$TMP/extracted.rom"
out=$("$BIN" extract --from "$TMP/legacy-valid.rom" --list 2>&1)
expect_has '在非 BIOS 镜像里也能扫到候选' "$out" 'legacy(x86)'

printf '\n== 8. 退出码与用法 ==\n'
expect_rc '文件不存在 → 3' 3 "$BIN" info "$TMP/does-not-exist.rom"
expect_rc '无参数 → 2' 2 "$BIN"
expect_rc '未知子命令 → 2' 2 "$BIN" frobnicate
expect_rc 'patch 缺参数 → 2' 2 "$BIN" patch "$TMP/legacy-valid.rom" "$TMP/x.rom"
expect_rc 'patch 少给输出路径 → 2' 2 "$BIN" patch --vendor 1002 "$TMP/legacy-valid.rom"
expect_rc 'verify 非 ROM 文件 → 1' 1 "$BIN" verify "$MK"

printf '\n────────────────────────────\n'
printf '通过: %d   失败: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
