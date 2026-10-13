/*
 * code-master:title win-box · romtool · ROM 解析与变换实现
 *
 * 契约：docs/interfaces/03-romtool.md ／ 链路：docs/calltrees/06-romtool.md
 *
 * 所有结构假设都在真实 ROM 上验证过（见注释里的实测结论），不照抄 spec 想当然：
 *
 *  PCIR 结构（相对映像起始，偏移由映像 +0x18 处的 u16 给出）：
 *    0x00 "PCIR"  0x04 vendor  0x06 device  0x08 VPD  0x0A 结构长度
 *    0x0C 版本    0x0D class(3) 0x10 映像长度(512 单位)  0x12 修订
 *    0x14 code type（0=legacy, 3=EFI）  0x15 indicator（bit7 = 最后一个映像）
 *
 *  实测结论：
 *   * legacy VBIOS 的校验和字节是**映像的最后一个字节**，且和为 0（已验证：44544 字节的
 *     参考 VBIOS 末字节 0xff 恰好满足）。
 *   * GOP-only ROM（code type 3）普遍**不合格**（和为 48/60/127/186 各不相同），
 *     但它们在真机上照常工作 —— 所以 verify 默认不把它当失败，patch 默认也不去"修"它。
 *     这一点很重要：社区的 GOP 盖章流程只改 ID、不动校验和，产物是验证过能用的；
 *     我们若"顺手修好"就会产出一个与验证过的镜像逐字节不同的文件。
 */
#include "rom.h"

#include "sha256.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t rd24(const uint8_t *p)
{
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
}
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v & 0xff); p[1] = (uint8_t)(v >> 8); }

static const char *code_type_name(uint8_t t)
{
  switch (t) {
    case 0: return "legacy(x86)";
    case 1: return "OpenFirmware";
    case 2: return "PA-RISC";
    case 3: return "EFI";
    default: return "unknown";
  }
}

/* ── 解析 ───────────────────────────────────────────────────────────────── */

static long find_signature(const uint8_t *d, size_t n, const char *sig, size_t siglen)
{
  size_t i;
  if (n < siglen) return -1;
  for (i = 0; i + siglen <= n; i++) {
    if (memcmp(d + i, sig, siglen) == 0) return (long)i;
  }
  return -1;
}

/* 提取 "ATOMBIOSBK..." 这类可读横幅（识别 VBIOS 来源时最有用） */
static void extract_banner(const uint8_t *d, size_t n, char *out, size_t outlen)
{
  long at = find_signature(d, n, "ATOMBIOSBK", 10);
  size_t i = 0;
  out[0] = '\0';
  if (at < 0) return;
  while (i + 1 < outlen && (size_t)at + i < n) {
    unsigned char c = d[(size_t)at + i];
    if (c < 0x20 || c > 0x7e) break;
    out[i] = (char)c;
    i++;
  }
  out[i] = '\0';
}

int rom_parse(uint8_t *data, size_t size, rom *out, char *errbuf, size_t errlen)
{
  size_t off = 0;

  memset(out, 0, sizeof(*out));
  out->data = data;
  out->size = size;
  out->atom_offset = -1;

  if (size < 512) {
    snprintf(errbuf, errlen, "文件太小（%zu 字节），不可能是 PCI ROM", size);
    return -1;
  }
  if (data[0] != 0x55 || data[1] != 0xAA) {
    snprintf(errbuf, errlen, "缺少 55 AA 签名 —— 这不是一块 PCI ROM");
    return -1;
  }
  out->declared_size = (size_t)data[2] * 512u;

  while (out->image_count < ROM_MAX_IMAGES) {
    rom_image *im;
    size_t pcir;
    uint16_t pptr, units;
    unsigned sum;
    size_t i;

    if (off + 0x20 > size) {
      snprintf(errbuf, errlen, "映像 %zu 起始偏移 0x%zx 已越界（文件只有 %zu 字节）",
               out->image_count, off, size);
      return -1;
    }
    pptr = rd16(data + off + 0x18);
    pcir = off + pptr;
    if (pcir + 0x18 > size || memcmp(data + pcir, "PCIR", 4) != 0) {
      snprintf(errbuf, errlen,
               "映像 %zu 的 PCIR 指针（偏移 0x%zx 处的 u16 = 0x%04x）指向无效结构",
               out->image_count, off + 0x18, pptr);
      return -1;
    }

    im = &out->images[out->image_count];
    im->offset = off;
    im->pcir_offset = pcir;
    im->vendor = rd16(data + pcir + 4);
    im->device = rd16(data + pcir + 6);
    im->class_code = rd24(data + pcir + 0x0d);
    units = rd16(data + pcir + 0x10);
    im->code_type = data[pcir + 0x14];
    im->indicator = data[pcir + 0x15];
    im->is_last = (im->indicator & 0x80) ? 1 : 0;
    im->length = (size_t)units * 512u;

    if (im->length == 0) {
      snprintf(errbuf, errlen, "映像 %zu 的 PCIR 长度字段为 0", out->image_count);
      return -1;
    }
    if (off + im->length > size) {
      snprintf(errbuf, errlen, "映像 %zu 声称长度 %zu 字节，超出文件剩余 %zu 字节",
               out->image_count, im->length, size - off);
      return -1;
    }

    sum = 0;
    for (i = 0; i < im->length; i++) sum += data[off + i];
    im->checksum = sum & 0xFFu;

    out->image_count++;
    if (im->is_last) break;
    off += im->length;
  }

  if (out->image_count == ROM_MAX_IMAGES && !out->images[out->image_count - 1].is_last) {
    snprintf(errbuf, errlen, "映像链超过 %d 个仍未出现“最后一个映像”标志", ROM_MAX_IMAGES);
    return -1;
  }

  out->atom_offset = find_signature(data, size, "ATOM", 4);
  extract_banner(data, size, out->atom_banner, sizeof(out->atom_banner));
  return 0;
}

void rom_free(rom *r)
{
  if (r) {
    free(r->data);
    r->data = NULL;
    r->size = 0;
  }
}

/* ── 报告 ───────────────────────────────────────────────────────────────── */

void rom_print_info(const rom *r, int as_json)
{
  uint8_t digest[32];
  char hex[65];
  size_t i, covered = 0;

  sha256_buf(r->data, r->size, digest);
  sha256_hex(digest, hex);

  if (as_json) {
    printf("{\n");
    printf("  \"size\": %zu,\n", r->size);
    printf("  \"declared_size\": %zu,\n", r->declared_size);
    printf("  \"sha256\": \"%s\",\n", hex);
    printf("  \"atom_offset\": %ld,\n", r->atom_offset);
    printf("  \"atom_banner\": \"%s\",\n", r->atom_banner);
    printf("  \"images\": [");
    for (i = 0; i < r->image_count; i++) {
      const rom_image *im = &r->images[i];
      printf("%s\n    {\"index\": %zu, \"offset\": %zu, \"length\": %zu, \"pcir_offset\": %zu,"
             " \"vendor\": \"%04x\", \"device\": \"%04x\", \"class\": \"%06x\","
             " \"code_type\": %u, \"code_type_name\": \"%s\", \"indicator\": %u,"
             " \"last\": %s, \"checksum\": %u}",
             i ? "," : "", i, im->offset, im->length, im->pcir_offset,
             im->vendor, im->device, im->class_code, im->code_type,
             code_type_name(im->code_type), im->indicator,
             im->is_last ? "true" : "false", im->checksum);
      covered += im->length;
    }
    printf("\n  ]\n}\n");
    return;
  }

  printf("大小            : %zu 字节", r->size);
  if (r->size % 512 == 0) printf("（512 的 %zu 倍）", r->size / 512);
  printf("\n");
  if (r->declared_size)
    printf("头部声明大小    : %zu 字节%s\n", r->declared_size,
           r->declared_size == r->size ? "（与实际一致）" : "（**与实际不一致**）");
  else
    printf("头部声明大小    : 未声明（0x02 为 0）\n");
  printf("映像数          : %zu\n", r->image_count);
  for (i = 0; i < r->image_count; i++) {
    const rom_image *im = &r->images[i];
    printf("  #%zu  偏移 0x%-6zx 长度 %-8zu  %04x:%-4x class %06x  %-13s indicator 0x%02x%s  校验和 %s%u\n",
           i, im->offset, im->length, im->vendor, im->device, im->class_code,
           code_type_name(im->code_type), im->indicator, im->is_last ? "(最后)" : "",
           im->checksum == 0 ? "合格 " : "不合格 ", im->checksum);
  }
  printf("ATOM 签名       : %s\n",
         r->atom_offset >= 0 ? "找到" : "未找到（纯 GOP 镜像很常见）");
  if (r->atom_offset >= 0) printf("                 偏移 0x%lx\n", r->atom_offset);
  if (r->atom_banner[0]) printf("VBIOS 横幅      : %s\n", r->atom_banner);
  printf("SHA256          : %s\n", hex);
}

/* ── 校验 ───────────────────────────────────────────────────────────────── */

int rom_verify(const rom *r, int strict)
{
  size_t i, covered = 0;
  int structural = 0, csum_bad = 0;
  char hex[65];
  uint8_t digest[32];

  if (r->declared_size == 0) {
    printf("  ⚠ 头部未声明大小（0x02 为 0）\n");
  } else if (r->declared_size != r->size) {
    printf("  ✗ 头部声明 %zu 字节，实际 %zu 字节\n", r->declared_size, r->size);
    structural = 1;
  } else {
    printf("  ✓ 头部声明大小与实际一致（%zu 字节）\n", r->size);
  }

  if (r->size % 512 != 0) {
    printf("  ✗ 文件大小 %zu 不是 512 的整数倍\n", r->size);
    structural = 1;
  } else {
    printf("  ✓ 文件大小是 512 的整数倍\n");
  }

  for (i = 0; i < r->image_count; i++) {
    const rom_image *im = &r->images[i];
    covered += im->length;
    if (im->checksum == 0) {
      printf("  ✓ 映像 #%zu 校验和合格（%04x:%04x，%s）\n", i, im->vendor, im->device,
             code_type_name(im->code_type));
    } else {
      printf("  %s 映像 #%zu 校验和 %u（应为 0）—— %s\n", strict ? "✗" : "⚠", i, im->checksum,
             im->code_type == 3
               ? (strict ? "EFI/GOP 镜像普遍如此，真机上照常可用（当前按 --strict 判定）"
                         : "EFI/GOP 镜像普遍如此，真机上照常可用；加 --strict 可视为失败")
               : "legacy 镜像通常是规范的 0，建议核对来源");
      csum_bad++;
    }
  }

  /* 映像长度合计是否覆盖整个文件 */
  if (covered != r->size) {
    /* 允许"最后一个映像之后还有填充"？不 —— 只提示，不当结构错误 */
    printf("  ⚠ 映像长度合计 %zu 与文件大小 %zu 不一致（尾部有 %zu 字节未纳入映像）\n",
           covered, r->size, r->size > covered ? r->size - covered : 0);
    if (covered > r->size) structural = 1;
  } else {
    printf("  ✓ 映像长度合计覆盖整个文件\n");
  }

  /* PCIR 链终止性 */
  if (!r->images[r->image_count - 1].is_last) {
    printf("  ✗ 最后一个映像没有置“最后映像”标志（bit7）\n");
    structural = 1;
  } else {
    printf("  ✓ 映像链以“最后映像”标志正确终止\n");
  }

  sha256_buf(r->data, r->size, digest);
  sha256_hex(digest, hex);

  if (structural) {
    printf("VERIFY: FAILED（结构问题）；sha256=%s\n", hex);
    return 1;
  }
  if (csum_bad && strict) {
    printf("VERIFY: FAILED（%d 个校验和不合格，--strict）；sha256=%s\n", csum_bad, hex);
    return 1;
  }
  if (csum_bad) {
    printf("VERIFY: OK（结构无误；%d 个校验和不合格，加 --strict 可视为失败）；sha256=%s\n",
           csum_bad, hex);
  } else {
    printf("VERIFY: OK；sha256=%s\n", hex);
  }
  return 0;
}

/* ── 变换 ───────────────────────────────────────────────────────────────── */

void rom_fix_image_checksum(uint8_t *img, size_t len)
{
  unsigned sum = 0;
  size_t i;
  if (len == 0) return;
  for (i = 0; i + 1 < len; i++) sum += img[i];
  img[len - 1] = (uint8_t)((0x100u - (sum & 0xFFu)) & 0xFFu);
}

int rom_patch_ids(rom *r, int want_vendor, uint16_t vendor, int want_device, uint16_t device,
                  int want_class, uint32_t class_code)
{
  int changed = 0;
  size_t i;

  if (!want_vendor && !want_device && !want_class) return 0;

  for (i = 0; i < r->image_count; i++) {
    rom_image *im = &r->images[i];
    uint8_t *pcir = r->data + im->pcir_offset;
    int was_valid = (im->checksum == 0);
    int touched = 0;

    if (want_vendor && rd16(pcir + 4) != vendor) {
      printf("  映像 #%zu vendor  %04x → %04x\n", i, rd16(pcir + 4), vendor);
      wr16(pcir + 4, vendor);
      touched = 1;
    }
    if (want_device && rd16(pcir + 6) != device) {
      printf("  映像 #%zu device  %04x → %04x\n", i, rd16(pcir + 6), device);
      wr16(pcir + 6, device);
      touched = 1;
    }
    if (want_class && rd24(pcir + 0x0d) != class_code) {
      printf("  映像 #%zu class   %06x → %06x\n", i, rd24(pcir + 0x0d), class_code);
      pcir[0x0d] = (uint8_t)(class_code & 0xff);
      pcir[0x0e] = (uint8_t)((class_code >> 8) & 0xff);
      pcir[0x0f] = (uint8_t)((class_code >> 16) & 0xff);
      touched = 1;
    }
    if (!touched) continue;
    changed++;

    /* 原镜像校验和合格 → 保持合格；原就不合格 → 保持原样（见文件头说明：
     * 社区的 GOP 盖章流程只改 ID、不动校验和，产物是验证过能用的） */
    if (was_valid) {
      rom_fix_image_checksum(r->data + im->offset, im->length);
      printf("        校验和已修正（原为合格，改动后保持合格）\n");
    } else {
      printf("        校验和未动（原就不合格；GOP 镜像通常如此，真机上不影响）\n");
    }
    im->vendor = rd16(pcir + 4);
    im->device = rd16(pcir + 6);
    im->class_code = rd24(pcir + 0x0d);
  }
  return changed;
}

int rom_merge(const rom *vbios, const rom *gop, uint8_t **out, size_t *outlen,
              char *errbuf, size_t errlen)
{
  size_t total, i, covered = 0;
  uint8_t *buf;
  rom merged;
  char tmp[256];

  for (i = 0; i < vbios->image_count; i++) covered += vbios->images[i].length;
  if (covered != vbios->size) {
    snprintf(errbuf, errlen, "被合并的 VBIOS 映像长度合计 %zu 与文件大小 %zu 不一致，拒绝合并",
             covered, vbios->size);
    return -1;
  }

  total = vbios->size + (gop ? gop->size : 0);
  buf = (uint8_t *)calloc(1, total);
  if (!buf) {
    snprintf(errbuf, errlen, "内存不足（需要 %zu 字节）", total);
    return -1;
  }
  memcpy(buf, vbios->data, vbios->size);
  if (gop) memcpy(buf + vbios->size, gop->data, gop->size);

  /* 1) 有 GOP 时：清掉 VBIOS 最后一个映像的 last 位（否则链在那里就结束了） */
  if (gop) {
    const rom_image *last = &vbios->images[vbios->image_count - 1];
    int was_valid = (last->checksum == 0);
    if (buf[last->pcir_offset + 0x15] & 0x80) {
      buf[last->pcir_offset + 0x15] &= 0x7F;
      printf("  清掉被合并 VBIOS 的“最后映像”标志（映像 #%zu，偏移 0x%zx）\n",
             vbios->image_count - 1, last->offset);
      if (was_valid) {
        rom_fix_image_checksum(buf + last->offset, last->length);
        printf("  该映像校验和已修正\n");
      }
    }
  }

  /* 2) 更新头部 size 字节（属于第一个映像） */
  if (total % 512 != 0) {
    snprintf(errbuf, errlen, "合并结果 %zu 字节不是 512 的整数倍", total);
    free(buf);
    return -1;
  }
  if (total / 512 <= 255) {
    if (buf[2] != (uint8_t)(total / 512)) {
      printf("  头部 size 字节 %u → %zu（512 单位）\n", buf[2], total / 512);
      buf[2] = (uint8_t)(total / 512);
      if (vbios->images[0].checksum == 0) {
        rom_fix_image_checksum(buf + vbios->images[0].offset, vbios->images[0].length);
        printf("  第一个映像校验和已修正\n");
      }
    }
  } else {
    printf("  ⚠ 合并结果 %zu 字节超出头部 8 位 size 字段能表示的范围（255*512），size 未更新\n",
           total);
  }

  /* 3) 合并结果必须仍是合法 ROM（否则宁可失败） */
  if (rom_parse(buf, total, &merged, tmp, sizeof(tmp)) != 0) {
    snprintf(errbuf, errlen, "合并结果无法解析（%s），已拒绝写出", tmp);
    free(buf);
    return -1;
  }
  if (!merged.images[merged.image_count - 1].is_last) {
    snprintf(errbuf, errlen, "合并结果的最后一个映像没有置“最后映像”标志，已拒绝写出");
    free(buf);
    return -1;
  }

  *out = buf;
  *outlen = total;
  return 0;
}

/* ── 扫描（从 BIOS 镜像里找 ROM 候选）──────────────────────────────────── */

int rom_scan(const uint8_t *data, size_t size, rom_scan_cb cb, void *user)
{
  size_t i;
  for (i = 0; i + 2 < size; i++) {
    rom r;
    char err[128];
    if (data[i] != 0x55 || data[i + 1] != 0xAA) continue;
    /* 只用可写指针做解析：解析阶段不修改数据 */
    if (rom_parse((uint8_t *)(uintptr_t)(data + i), size - i, &r, err, sizeof(err)) != 0)
      continue;
    if (cb(i, &r, user) != 0) return 0;
  }
  return 0;
}

/* ── 原子写 ─────────────────────────────────────────────────────────────── */

int rom_write_atomic(const char *path, const uint8_t *data, size_t len,
                     char *errbuf, size_t errlen)
{
  char *tmp;
  size_t tlen = strlen(path) + 8;
  int fd;
  ssize_t written;
  size_t off = 0;

  tmp = (char *)malloc(tlen);
  if (!tmp) {
    snprintf(errbuf, errlen, "内存不足");
    return -1;
  }
  snprintf(tmp, tlen, "%s.XXXXXX", path);
  fd = mkstemp(tmp);
  if (fd < 0) {
    snprintf(errbuf, errlen, "无法创建临时文件 %s: %s", tmp, strerror(errno));
    free(tmp);
    return -1;
  }
  while (off < len) {
    written = write(fd, data + off, len - off);
    if (written < 0) {
      if (errno == EINTR) continue;
      snprintf(errbuf, errlen, "写入 %s 失败: %s", tmp, strerror(errno));
      close(fd);
      unlink(tmp);
      free(tmp);
      return -1;
    }
    off += (size_t)written;
  }
  if (fsync(fd) != 0) { /* 非致命，但记录 */ }
  if (fchmod(fd, 0644) != 0) { /* 忽略 */ }
  close(fd);
  if (rename(tmp, path) != 0) {
    snprintf(errbuf, errlen, "替换 %s 失败: %s", path, strerror(errno));
    unlink(tmp);
    free(tmp);
    return -1;
  }
  free(tmp);
  return 0;
}
