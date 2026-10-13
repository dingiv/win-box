/*
 * code-master:title win-box · romtool · 命令行入口
 *
 * 契约：docs/interfaces/03-romtool.md
 *
 * 退出码（全命令统一）：
 *   0 成功
 *   1 能读但不合格（verify 的结论；info 遇到非 ROM 文件也算）
 *   2 用法错误
 *   3 文件不可读 / 不存在
 *   4 设备不存在或无 ROM（dump）
 *   5 写文件失败
 */
#include "rom.h"
#include "sha256.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EX_OK        0
#define EX_INVALID   1
#define EX_USAGE     2
#define EX_NOFILE    3
#define EX_NODEV     4
#define EX_WRITE     5

static const char *g_prog = "romtool";

static void usage(FILE *to)
{
  fprintf(to,
    "romtool —— AMD PCI ROM 的结构解析 / 校验 / 改 ID / 合并 / 提取\n"
    "（win-box 的 C 辅助工具：这些事用 shell + od 做既不可读也不可靠）\n"
    "\n"
    "用法:\n"
    "  romtool info FILE [--json]\n"
    "      结构报告：头、每个映像的 PCIR（ID/class/codeType/indicator/校验和）、\n"
    "      ATOM 签名与 VBIOS 横幅、SHA256\n"
    "  romtool verify [--strict] FILE\n"
    "      结构校验（致命）+ 校验和（默认仅警告，--strict 视为失败）\n"
    "      为什么默认宽容：真实世界的 EFI/GOP 镜像普遍校验和非 0，但照常可用\n"
    "  romtool patch [--vendor HHHH] [--device HHHH] [--class HHHHHH]\n"
    "                [--fix-checksum] [--dry-run] IN OUT\n"
    "      改 PCIR 里的 ID（给提取到的 GOP 镜像盖本机核显 ID 就是这一步）。\n"
    "      默认**不动校验和**：原镜像合格则保持合格，原就不合格则保持原样\n"
    "      —— 这样产物与社区验证过的盖章流程逐字节一致；要强制合格加 --fix-checksum\n"
    "  romtool merge --vbios A [--gop B] OUT\n"
    "      把 GOP 镜像追加到 legacy VBIOS 之后（清掉 A 的“最后映像”标志、\n"
    "      更新头部 size、保持校验和一致性），合并结果必须仍能解析\n"
    "  romtool dump --bdf DDDD:BB:DD.F OUT [--vendor HHHH --device HHHH]\n"
    "      从 /sys/.../rom 提取本机设备 ROM（自动 enable/restore）\n"
    "  romtool extract --from BIOS.IMG [--list] [--index N] OUT\n"
    "      在主板/显卡 BIOS 镜像里扫描 ROM 候选\n"
    "\n"
    "退出码: 0 成功  1 能读但不合格  2 用法错误  3 文件不可读  4 设备无 ROM  5 写失败\n");
}

static void die_usage(const char *msg)
{
  if (msg) fprintf(stderr, "%s: %s\n", g_prog, msg);
  fprintf(stderr, "\n用 %s --help 看用法。\n", g_prog);
  exit(EX_USAGE);
}

static void die(const char *stage, const char *msg, int code)
{
  fprintf(stderr, "✗ %s: %s\n", stage, msg);
  exit(code);
}

/* ── 文件读写 ───────────────────────────────────────────────────────────── */

static uint8_t *read_file(const char *path, size_t *len, char *err, size_t errlen)
{
  FILE *f = fopen(path, "rb");
  uint8_t *buf = NULL;
  size_t cap = 1u << 20, used = 0;

  if (!f) {
    snprintf(err, errlen, "打不开 %s: %s", path, strerror(errno));
    return NULL;
  }
  buf = (uint8_t *)malloc(cap);
  if (!buf) {
    fclose(f);
    snprintf(err, errlen, "内存不足");
    return NULL;
  }
  for (;;) {
    size_t n;
    if (used == cap) {
      uint8_t *nb;
      cap *= 2;
      nb = (uint8_t *)realloc(buf, cap);
      if (!nb) {
        free(buf);
        fclose(f);
        snprintf(err, errlen, "内存不足（> %zu 字节）", cap);
        return NULL;
      }
      buf = nb;
    }
    n = fread(buf + used, 1, cap - used, f);
    used += n;
    if (n == 0) {
      if (ferror(f)) {
        snprintf(err, errlen, "读 %s 失败: %s", path, strerror(errno));
        free(buf);
        fclose(f);
        return NULL;
      }
      break;
    }
  }
  fclose(f);
  *len = used;
  return buf;
}

static int parse_or_fail(const char *stage, uint8_t *data, size_t len, rom *r, int failcode)
{
  char err[256];
  if (rom_parse(data, len, r, err, sizeof(err)) != 0) {
    fprintf(stderr, "✗ %s: %s\n", stage, err);
    return failcode;
  }
  return 0;
}

/* ── info ───────────────────────────────────────────────────────────────── */

static int cmd_info(int argc, char **argv)
{
  const char *path = NULL;
  int json = 0, i;
  uint8_t *data;
  size_t len;
  char err[256];

  for (i = 0; i < argc; i++) {
    if (strcmp(argv[i], "--json") == 0) json = 1;
    else if (argv[i][0] == '-') die_usage("info: 未知选项");
    else if (!path) path = argv[i];
    else die_usage("info: 参数太多");
  }
  if (!path) die_usage("info: 需要文件参数");

  data = read_file(path, &len, err, sizeof(err));
  if (!data) die("info", err, EX_NOFILE);

  {
    rom r;
    int rc = parse_or_fail("info", data, len, &r, EX_INVALID);
    if (rc != 0) {
      free(data);
      return rc;
    }
    if (!json) printf("文件            : %s\n", path);
    rom_print_info(&r, json);
    free(data);
  }
  return EX_OK;
}

/* ── verify ─────────────────────────────────────────────────────────────── */

static int cmd_verify(int argc, char **argv)
{
  const char *path = NULL;
  int strict = 0, i;
  uint8_t *data;
  size_t len;
  char err[256];
  int rc;

  for (i = 0; i < argc; i++) {
    if (strcmp(argv[i], "--strict") == 0) strict = 1;
    else if (argv[i][0] == '-') die_usage("verify: 未知选项");
    else if (!path) path = argv[i];
    else die_usage("verify: 参数太多");
  }
  if (!path) die_usage("verify: 需要文件参数");

  data = read_file(path, &len, err, sizeof(err));
  if (!data) die("verify", err, EX_NOFILE);

  {
    rom r;
    rc = parse_or_fail("verify", data, len, &r, EX_INVALID);
    if (rc != 0) {
      free(data);
      return rc;
    }
    printf("文件: %s\n", path);
    rc = rom_verify(&r, strict);
    free(data);
  }
  return rc;
}

/* ── patch ──────────────────────────────────────────────────────────────── */

static int parse_hex_arg(const char *s, unsigned long *out)
{
  char *end = NULL;
  unsigned long v = strtoul(s, &end, 16);
  if (!end || *end != '\0' || end == s || v > 0xfffffful) return -1;
  *out = v;
  return 0;
}

static int cmd_patch(int argc, char **argv)
{
  const char *in = NULL, *out = NULL;
  int want_vendor = 0, want_device = 0, want_class = 0, fix_csum = 0, dry = 0;
  unsigned long vendor = 0, device = 0, class_code = 0;
  int i, changed, rc;
  uint8_t *data;
  size_t len;
  char err[256];

  for (i = 0; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--vendor") == 0 && i + 1 < argc) {
      if (parse_hex_arg(argv[++i], &vendor) != 0) die_usage("patch: --vendor 需要 4 位十六进制");
      want_vendor = 1;
    } else if (strcmp(a, "--device") == 0 && i + 1 < argc) {
      if (parse_hex_arg(argv[++i], &device) != 0) die_usage("patch: --device 需要 4 位十六进制");
      want_device = 1;
    } else if (strcmp(a, "--class") == 0 && i + 1 < argc) {
      if (parse_hex_arg(argv[++i], &class_code) != 0) die_usage("patch: --class 需要 6 位十六进制");
      want_class = 1;
    } else if (strcmp(a, "--fix-checksum") == 0) {
      fix_csum = 1;
    } else if (strcmp(a, "--dry-run") == 0) {
      dry = 1;
    } else if (a[0] == '-') {
      die_usage("patch: 未知选项");
    } else if (!in) {
      in = a;
    } else if (!out) {
      out = a;
    } else {
      die_usage("patch: 参数太多");
    }
  }
  if (!in || !out) die_usage("patch: 需要 IN OUT 两个路径");
  if (!want_vendor && !want_device && !want_class)
    die_usage("patch: 至少要给 --vendor / --device / --class 之一");

  data = read_file(in, &len, err, sizeof(err));
  if (!data) die("patch", err, EX_NOFILE);

  {
    rom r;
    rc = parse_or_fail("patch", data, len, &r, EX_INVALID);
    if (rc != 0) {
      free(data);
      return rc;
    }
    printf("改 ID: %s → %s%s\n", in, out, dry ? "（--dry-run，不写出）" : "");
    changed = rom_patch_ids(&r, want_vendor, (uint16_t)vendor, want_device, (uint16_t)device,
                            want_class, (uint32_t)class_code);
    if (changed == 0) {
      printf("  没有需要改动的地方（值已经相同？）\n");
      free(data);
      return EX_OK;
    }
    if (fix_csum) {
      /* --fix-checksum：把所有被改映像的校验和都算到合格 */
      size_t k;
      for (k = 0; k < r.image_count; k++) {
        rom_image *im = &r.images[k];
        rom_fix_image_checksum(data + im->offset, im->length);
      }
      printf("  已按 --fix-checksum 把全部映像校验和修正为合格\n");
    }
    if (!dry) {
      if (rom_write_atomic(out, data, len, err, sizeof(err)) != 0) {
        free(data);
        die("patch", err, EX_WRITE);
      }
      printf("  已写入 %s（%zu 字节）\n", out, len);
    }
  }
  free(data);
  return EX_OK;
}

/* ── merge ──────────────────────────────────────────────────────────────── */

static int cmd_merge(int argc, char **argv)
{
  const char *vbios_path = NULL, *gop_path = NULL, *out = NULL;
  uint8_t *vbios_data = NULL, *gop_data = NULL, *merged = NULL;
  size_t vbios_len = 0, gop_len = 0, merged_len = 0;
  char err[256];
  int i, rc;

  for (i = 0; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--vbios") == 0 && i + 1 < argc) vbios_path = argv[++i];
    else if (strcmp(a, "--gop") == 0 && i + 1 < argc) gop_path = argv[++i];
    else if (a[0] == '-') die_usage("merge: 未知选项");
    else if (!out) out = a;
    else die_usage("merge: 参数太多");
  }
  if (!vbios_path || !out) die_usage("merge: 需要 --vbios A 与 OUT");

  vbios_data = read_file(vbios_path, &vbios_len, err, sizeof(err));
  if (!vbios_data) die("merge", err, EX_NOFILE);
  if (gop_path) {
    gop_data = read_file(gop_path, &gop_len, err, sizeof(err));
    if (!gop_data) {
      free(vbios_data);
      die("merge", err, EX_NOFILE);
    }
  }

  {
    rom a, b;
    rc = parse_or_fail("merge", vbios_data, vbios_len, &a, EX_INVALID);
    if (rc != 0) goto done;
    if (gop_data) {
      rc = parse_or_fail("merge", gop_data, gop_len, &b, EX_INVALID);
      if (rc != 0) goto done;
    }
    printf("合并: %s%s%s\n", vbios_path, gop_path ? " + " : "", gop_path ? gop_path : "");
    if (rom_merge(&a, gop_data ? &b : NULL, &merged, &merged_len, err, sizeof(err)) != 0) {
      fprintf(stderr, "✗ merge: %s\n", err);
      rc = EX_INVALID;
      goto done;
    }
    if (rom_write_atomic(out, merged, merged_len, err, sizeof(err)) != 0) {
      rc = EX_WRITE;
      goto done;
    }
    printf("  已写入 %s（%zu 字节）\n", out, merged_len);

    /* 合并结果自检：必须仍能解析且链正确终止 */
    {
      rom m;
      if (rom_parse(merged, merged_len, &m, err, sizeof(err)) != 0) {
        fprintf(stderr, "✗ merge: 合并结果无法解析（%s）\n", err);
        rc = EX_INVALID;
        goto done;
      }
      printf("  合并结果自检: %zu 个映像，最后映像标志 %s\n", m.image_count,
             m.images[m.image_count - 1].is_last ? "已置位" : "**未置位**");
    }
    rc = EX_OK;
  }

done:
  free(vbios_data);
  free(gop_data);
  free(merged);
  return rc;
}

/* ── dump（从 /sys 读设备 ROM）────────────────────────────────────────── */

static int sysfs_write(const char *path, const char *val)
{
  int fd = open(path, O_WRONLY);
  ssize_t n;
  if (fd < 0) return -1;
  n = write(fd, val, 1);
  close(fd);
  return (n == 1) ? 0 : -1;
}

static int find_bdf_by_ids(unsigned long vendor, unsigned long device, char *out, size_t outlen)
{
  /* 在 /sys/bus/pci/devices 下按 vendor:device 找设备 */
  FILE *p;
  char line[512];

  (void)vendor;
  (void)device;
  /* 用 shell 反而更简单：这里直接遍历目录 */
  {
    char cmd[256];
    snprintf(cmd, sizeof(cmd),
             "grep -l -i '^0x%04lx' /sys/bus/pci/devices/*/vendor 2>/dev/null | while read -r v; do "
             "d=$(dirname \"$v\"); [ \"$(cat \"$d/device\")\" = \"0x%04lx\" ] && basename \"$d\"; done | head -1",
             vendor, device);
    p = popen(cmd, "r");
    if (!p) return -1;
    if (fgets(line, sizeof(line), p)) {
      size_t n = strlen(line);
      while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
      snprintf(out, outlen, "%s", line);
      pclose(p);
      return n ? 0 : -1;
    }
    pclose(p);
  }
  return -1;
}

static int cmd_dump(int argc, char **argv)
{
  char bdf[64] = "";
  const char *out = NULL;
  unsigned long vendor = 0, device = 0;
  int have_vendor = 0, have_device = 0, i;
  char syspath[PATH_MAX], err[256];
  uint8_t *buf = NULL;
  size_t cap = 4u << 20, len = 0;
  int fd, rc = EX_OK;

  for (i = 0; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--bdf") == 0 && i + 1 < argc) snprintf(bdf, sizeof(bdf), "%s", argv[++i]);
    else if (strcmp(a, "--vendor") == 0 && i + 1 < argc) {
      if (parse_hex_arg(argv[++i], &vendor) != 0) die_usage("dump: --vendor 需要十六进制");
      have_vendor = 1;
    } else if (strcmp(a, "--device") == 0 && i + 1 < argc) {
      if (parse_hex_arg(argv[++i], &device) != 0) die_usage("dump: --device 需要十六进制");
      have_device = 1;
    } else if (a[0] == '-') die_usage("dump: 未知选项");
    else if (!out) out = a;
    else die_usage("dump: 参数太多");
  }
  if (!out) die_usage("dump: 需要输出路径");

  if (!bdf[0]) {
    if (!have_vendor || !have_device)
      die_usage("dump: 需要 --bdf，或者同时给 --vendor 与 --device");
    if (find_bdf_by_ids(vendor, device, bdf, sizeof(bdf)) != 0)
      die("dump", "没有找到匹配该 vendor:device 的 PCI 设备", EX_NODEV);
    printf("按 ID 定位到设备: %s\n", bdf);
  }

  snprintf(syspath, sizeof(syspath), "/sys/bus/pci/devices/%s/rom", bdf);

  if (sysfs_write(syspath, "1") != 0)
    die("dump", "无法开启 ROM 解码（需要 root；设备可能已归 vfio-pci 占用）", EX_NODEV);

  buf = (uint8_t *)malloc(cap);
  if (!buf) {
    sysfs_write(syspath, "0");
    die("dump", "内存不足", EX_NODEV);
  }
  fd = open(syspath, O_RDONLY);
  if (fd < 0) {
    snprintf(err, sizeof(err), "打不开设备 %s 的 ROM 属性: %s", bdf, strerror(errno));
    sysfs_write(syspath, "0");
    free(buf);
    die("dump", err, EX_NODEV);
  }
  while (len < cap) {
    ssize_t n = read(fd, buf + len, cap - len);
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (n == 0) break;
    len += (size_t)n;
  }
  close(fd);
  sysfs_write(syspath, "0");

  if (len == 0) {
    free(buf);
    die("dump", "读不到 ROM（设备没有 ROM，或 ROM 被其它驱动占用）", EX_NODEV);
  }

  /* 按头部声明裁掉多余字节（sysfs 读到的常常是 4 MiB 的窗口） */
  if (len >= 3 && buf[0] == 0x55 && buf[1] == 0xAA && buf[2] > 0) {
    size_t want = (size_t)buf[2] * 512u;
    if (want >= 512 && want <= len) {
      if (want != len) printf("按头部声明裁剪: %zu → %zu 字节\n", len, want);
      len = want;
    }
  }
  if (buf[0] != 0x55 || buf[1] != 0xAA)
    fprintf(stderr, "⚠ dump: 读到的数据没有 55 AA 签名（设备可能没有合法 ROM）\n");

  if (rom_write_atomic(out, buf, len, err, sizeof(err)) != 0) {
    fprintf(stderr, "✗ dump: %s\n", err);
    rc = EX_WRITE;
  } else {
    uint8_t digest[32];
    char hex[65];
    sha256_buf(buf, len, digest);
    sha256_hex(digest, hex);
    printf("已写入 %s（%zu 字节）\n  设备: %s\n  sha256: %s\n", out, len, bdf, hex);
  }
  free(buf);
  return rc;
}

/* ── extract（在 BIOS 镜像里扫描 ROM）──────────────────────────────────── */

struct scan_ctx {
  int list_only;
  long want_index;
  long index;
  size_t pick_offset;
  size_t pick_length;
  const uint8_t *base;
};

static size_t rom_extent(const rom *r)
{
  size_t covered = 0, i;
  for (i = 0; i < r->image_count; i++) covered += r->images[i].length;
  if (r->declared_size >= covered && r->declared_size <= r->size) return r->declared_size;
  return covered;
}

static int scan_cb(size_t offset, const rom *r, void *user)
{
  struct scan_ctx *ctx = (struct scan_ctx *)user;
  uint8_t digest[32];
  char hex[65];
  size_t extent = rom_extent(r);

  sha256_buf(r->data, extent, digest);
  sha256_hex(digest, hex);
  printf("  [%ld] 偏移 0x%-8zx 大小 %-8zu  %04x:%-4x  %-13s  %zu 个映像  sha256 %s\n",
         ctx->index, offset, extent, r->images[0].vendor, r->images[0].device,
         r->images[0].code_type == 0 ? "legacy(x86)" :
         r->images[0].code_type == 3 ? "EFI" : "其他", r->image_count, hex);

  if (!ctx->list_only && ctx->index == ctx->want_index) {
    ctx->pick_offset = offset;
    ctx->pick_length = extent;
  }
  ctx->index++;
  return 0;
}

static int cmd_extract(int argc, char **argv)
{
  const char *from = NULL, *out = NULL;
  int list_only = 0, i;
  long want_index = -1;
  uint8_t *data;
  size_t len;
  char err[256];
  struct scan_ctx ctx;

  for (i = 0; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--from") == 0 && i + 1 < argc) from = argv[++i];
    else if (strcmp(a, "--list") == 0) list_only = 1;
    else if (strcmp(a, "--index") == 0 && i + 1 < argc) {
      char *end = NULL;
      want_index = strtol(argv[++i], &end, 10);
      if (!end || *end != '\0' || want_index < 0) die_usage("extract: --index 需要非负整数");
    } else if (a[0] == '-') die_usage("extract: 未知选项");
    else if (!out) out = a;
    else die_usage("extract: 参数太多");
  }
  if (!from) die_usage("extract: 需要 --from BIOS.IMG");
  if (!list_only && !out) die_usage("extract: 需要输出路径（或者用 --list 只列出）");

  data = read_file(from, &len, err, sizeof(err));
  if (!data) die("extract", err, EX_NOFILE);

  printf("在 %s（%zu 字节）中扫描 ROM 候选:\n", from, len);
  memset(&ctx, 0, sizeof(ctx));
  ctx.list_only = list_only;
  ctx.want_index = want_index;
  ctx.index = 0;
  ctx.pick_length = 0;
  rom_scan(data, len, scan_cb, &ctx);

  if (ctx.index == 0) {
    printf("  未找到任何 ROM 候选（已扫描 %zu 字节；查过 55 AA 签名）\n", len);
    free(data);
    return EX_INVALID;
  }
  if (list_only) {
    printf("共 %ld 个候选；用 --index N 导出其中一个\n", ctx.index);
    free(data);
    return EX_OK;
  }
  if (want_index < 0) {
    if (ctx.index != 1) {
      fprintf(stderr, "✗ extract: 有 %ld 个候选，请用 --index N 指定要导出哪个\n", ctx.index);
      free(data);
      return EX_USAGE;
    }
    /* 只有一个候选：直接导出 */
    memset(&ctx, 0, sizeof(ctx));
    ctx.want_index = 0;
    ctx.index = 0;
    rom_scan(data, len, scan_cb, &ctx);
  }
  if (ctx.pick_length == 0) {
    fprintf(stderr, "✗ extract: 序号 %ld 超出候选范围\n", want_index);
    free(data);
    return EX_USAGE;
  }
  if (rom_write_atomic(out, data + ctx.pick_offset, ctx.pick_length, err, sizeof(err)) != 0) {
    fprintf(stderr, "✗ extract: %s\n", err);
    free(data);
    return EX_WRITE;
  }
  printf("已导出 %zu 字节 → %s\n", ctx.pick_length, out);
  free(data);
  return EX_OK;
}

/* ── 入口 ───────────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
  const char *cmd;

  if (argc < 2) {
    usage(stderr);
    return EX_USAGE;
  }
  cmd = argv[1];
  if (strcmp(cmd, "--help") == 0 || strcmp(cmd, "-h") == 0 || strcmp(cmd, "help") == 0) {
    usage(stdout);
    return EX_OK;
  }
  if (strcmp(cmd, "--version") == 0 || strcmp(cmd, "version") == 0) {
    printf("romtool (win-box) 0.1.0\n");
    return EX_OK;
  }

  if (strcmp(cmd, "info") == 0) return cmd_info(argc - 2, argv + 2);
  if (strcmp(cmd, "verify") == 0) return cmd_verify(argc - 2, argv + 2);
  if (strcmp(cmd, "patch") == 0) return cmd_patch(argc - 2, argv + 2);
  if (strcmp(cmd, "merge") == 0) return cmd_merge(argc - 2, argv + 2);
  if (strcmp(cmd, "dump") == 0) return cmd_dump(argc - 2, argv + 2);
  if (strcmp(cmd, "extract") == 0) return cmd_extract(argc - 2, argv + 2);

  fprintf(stderr, "%s: 未知子命令 '%s'\n", g_prog, cmd);
  usage(stderr);
  return EX_USAGE;
}
