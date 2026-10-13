/*
 * code-master:title win-box · romtool · 合成 ROM 生成器（测试用）
 *
 * **仓库里不放任何 AMD 二进制**：测试样本全部由本程序按格式生成，
 * 这样任何人都能 clone 后 make test 验证工具本身。
 *
 * 用法: mkrom <kind> <输出文件>
 *
 * kind:
 *   legacy-valid     4 KiB 单映像，codeType 0（legacy），校验和合格，ID 1002:13c0
 *   efi-valid        6 KiB 单映像，codeType 3（EFI），校验和合格，ID 1002:13c0
 *   legacy-badcsum   同 legacy-valid 但不修校验和
 *   efi-bad-ids      4 KiB，ID 03ea:0668 且校验和不合格
 *                    （模拟社区 GOP 镜像：ID 是错的、校验和也不规范，但真机可用）
 *   two-images       4 KiB legacy + 2 KiB EFI，链正确（第一个 last=0、第二个 last=1）
 *   bad-signature    没有 55 AA
 *   truncated        PCIR 声称长度大于文件
 *   bios-image       8 KiB 的“BIOS 镜像”，在偏移 0x600 处嵌一个 legacy-valid
 */
#include "../rom.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void put_image(uint8_t *buf, size_t offset, size_t image_bytes, uint16_t vendor,
                      uint16_t device, uint32_t class_code, uint8_t code_type, int last,
                      int fix_csum)
{
  uint8_t *p;

  memset(buf + offset, 0x90, image_bytes);
  buf[offset + 0] = 0x55;
  buf[offset + 1] = 0xAA;
  buf[offset + 2] = (uint8_t)(image_bytes / 512);
  buf[offset + 0x18] = 0x1C;   /* PCIR 指针（相对映像起始） */
  buf[offset + 0x19] = 0x00;

  p = buf + offset + 0x1C;
  memcpy(p, "PCIR", 4);
  p[4] = (uint8_t)(vendor & 0xff);
  p[5] = (uint8_t)(vendor >> 8);
  p[6] = (uint8_t)(device & 0xff);
  p[7] = (uint8_t)(device >> 8);
  p[0x0a] = 0x1c;
  p[0x0b] = 0x00;
  p[0x0c] = 0x03;              /* PCIR 结构版本 */
  p[0x0d] = (uint8_t)(class_code & 0xff);
  p[0x0e] = (uint8_t)((class_code >> 8) & 0xff);
  p[0x0f] = (uint8_t)((class_code >> 16) & 0xff);
  p[0x10] = (uint8_t)((image_bytes / 512) & 0xff);
  p[0x11] = (uint8_t)((image_bytes / 512) >> 8);
  p[0x12] = 0x00;
  p[0x13] = 0x00;
  p[0x14] = code_type;
  p[0x15] = last ? 0x80 : 0x00;

  if (fix_csum) rom_fix_image_checksum(buf + offset, image_bytes);
}

static int write_all(const char *path, const uint8_t *buf, size_t len)
{
  FILE *f = fopen(path, "wb");
  if (!f) {
    perror(path);
    return -1;
  }
  if (fwrite(buf, 1, len, f) != len) {
    perror("fwrite");
    fclose(f);
    return -1;
  }
  fclose(f);
  printf("生成 %s（%zu 字节）\n", path, len);
  return 0;
}

int main(int argc, char **argv)
{
  const char *kind, *out;
  uint8_t *buf;
  size_t len;

  if (argc != 3) {
    fprintf(stderr, "用法: mkrom <kind> <输出文件>\n");
    return 2;
  }
  kind = argv[1];
  out = argv[2];

  if (strcmp(kind, "legacy-valid") == 0) {
    len = 4096;
    buf = (uint8_t *)calloc(1, len);
    put_image(buf, 0, len, 0x1002, 0x13c0, 0x030000, 0, 1, 1);
  } else if (strcmp(kind, "efi-valid") == 0) {
    len = 6144;
    buf = (uint8_t *)calloc(1, len);
    put_image(buf, 0, len, 0x1002, 0x13c0, 0x030000, 3, 1, 1);
  } else if (strcmp(kind, "legacy-badcsum") == 0) {
    len = 4096;
    buf = (uint8_t *)calloc(1, len);
    put_image(buf, 0, len, 0x1002, 0x13c0, 0x030000, 0, 1, 0);
  } else if (strcmp(kind, "efi-bad-ids") == 0) {
    len = 4096;
    buf = (uint8_t *)calloc(1, len);
    put_image(buf, 0, len, 0x03ea, 0x0668, 0x000000, 3, 1, 0);
  } else if (strcmp(kind, "two-images") == 0) {
    len = 4096 + 2048;
    buf = (uint8_t *)calloc(1, len);
    put_image(buf, 0, 4096, 0x1002, 0x13c0, 0x030000, 0, 0, 1);
    put_image(buf, 4096, 2048, 0x1002, 0x13c0, 0x030000, 3, 1, 1);
    /* 头部 size 字节**属于第一个映像**：改完必须重算它的校验和（真实世界同理） */
    buf[2] = (uint8_t)(len / 512);
    rom_fix_image_checksum(buf, 4096);
  } else if (strcmp(kind, "bad-signature") == 0) {
    len = 4096;
    buf = (uint8_t *)calloc(1, len);
    memset(buf, 0xAA, len);
  } else if (strcmp(kind, "truncated") == 0) {
    len = 4096;
    buf = (uint8_t *)calloc(1, len);
    put_image(buf, 0, len, 0x1002, 0x13c0, 0x030000, 0, 1, 1);
    /* PCIR 声称 32 KiB，远超文件 */
    buf[0x1C + 0x10] = 0x40;
    buf[0x1C + 0x11] = 0x00;
    rom_fix_image_checksum(buf, len);
  } else if (strcmp(kind, "bios-image") == 0) {
    len = 8192;
    buf = (uint8_t *)calloc(1, len);
    memset(buf, 0xFF, len);
    put_image(buf, 0x600, 4096, 0x1002, 0x13c0, 0x030000, 0, 1, 1);
  } else {
    fprintf(stderr, "未知类型: %s\n", kind);
    return 2;
  }

  if (write_all(out, buf, len) != 0) {
    free(buf);
    return 1;
  }
  free(buf);
  return 0;
}
