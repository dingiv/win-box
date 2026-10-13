/*
 * code-master:title win-box · romtool · ROM 解析与变换
 *
 * 契约：docs/interfaces/03-romtool.md
 * 链路：docs/calltrees/06-romtool.md
 *
 * 这是整个项目里唯一"用 shell 会写得很糟"的部分：二进制结构解析、校验和、
 * 映像链、合并。所有假设都在真实 ROM 上验证过（见下面注释里的实测结论）。
 *
 * 实测得到的两个与直觉不同的点（照 spec 想当然会写错）：
 *   1. **GOP-only ROM（code type 3）的校验和普遍不为 0** —— 它们照样能用，
 *      QEMU/libvirt 也不校验。所以 verify 默认把校验和不当失败，只有 --strict 才当失败。
 *      legacy VBIOS（code type 0）的校验和则是规范的 0。
 *   2. ATOM 签名不在 0x48 指向的偏移处：0x48 的 u16 指向一个小结构，
 *      "ATOM" 在其 +4 处；而 "ATOMBIOSBK" 横幅字符串又是另一处。可靠做法是扫描签名。
 */
#ifndef WINBOX_ROM_H
#define WINBOX_ROM_H

#include <stddef.h>
#include <stdint.h>

#define ROM_MAX_IMAGES 16

typedef struct {
  size_t   offset;       /* 映像在文件中的偏移 */
  size_t   length;       /* 由 PCIR 给出的映像长度（字节） */
  size_t   pcir_offset;  /* PCIR 结构偏移（相对文件） */
  uint16_t vendor;
  uint16_t device;
  uint32_t class_code;   /* 24 位 */
  uint8_t  code_type;    /* 0 = x86 legacy, 3 = EFI ... */
  uint8_t  indicator;    /* bit7 = 最后一个映像 */
  int      is_last;
  unsigned checksum;     /* 该映像所有字节之和 & 0xFF（0 = 规范合格） */
} rom_image;

typedef struct {
  uint8_t   *data;
  size_t     size;
  size_t     declared_size;   /* 头里 0x02 字节 * 512（0 = 头里没写） */
  rom_image  images[ROM_MAX_IMAGES];
  size_t     image_count;
  long       atom_offset;     /* 首个 "ATOM" 签名的偏移，-1 = 没有 */
  char       atom_banner[64]; /* "ATOMBIOSBK..." 那串可读信息（可能为空） */
} rom;

/* 解析；失败返回 -1 并写 errbuf（结构问题都从这里出） */
int  rom_parse(uint8_t *data, size_t size, rom *out, char *errbuf, size_t errlen);
void rom_free(rom *r);

/* 人类可读报告 */
void rom_print_info(const rom *r, int as_json);
/* 校验：返回 0 = 通过；1 = 有结构问题；2 = 仅有校验和问题且 strict=1 */
int  rom_verify(const rom *r, int strict);

/* 改名：把匹配的 PCIR 的 vendor/device（可选 class）改掉并重算校验和
 * 返回改动个数；-1 = 参数问题 */
int  rom_patch_ids(rom *r, int want_vendor, uint16_t vendor,
                   int want_device, uint16_t device,
                   int want_class, uint32_t class_code);

/* 合并：把 gop 追加到 vbios 之后（gop 可为 NULL/0 表示只做规范化）
 * 成功时把新缓冲区写到 *out（调用方 free），返回 0 */
int rom_merge(const rom *vbios, const rom *gop, uint8_t **out, size_t *outlen,
              char *errbuf, size_t errlen);

/* 计算某个映像的校验和并修正（把最后一个字节调成让整段和为 0） */
void rom_fix_image_checksum(uint8_t *img, size_t len);

/* 在 BIOS 镜像里扫描 ROM 候选；cb 每找到一个就回调（返回非 0 表示停止） */
typedef int (*rom_scan_cb)(size_t offset, const rom *r, void *user);
int rom_scan(const uint8_t *data, size_t size, rom_scan_cb cb, void *user);

/* 原子写文件（temp + rename，同目录；不留半成品） */
int rom_write_atomic(const char *path, const uint8_t *data, size_t len,
                     char *errbuf, size_t errlen);

#endif /* WINBOX_ROM_H */
