/*
 * code-master:title win-box · romtool · SHA-256（不依赖任何第三方库）
 *
 * 契约：docs/interfaces/03-romtool.md
 * 为什么自己实现：本项目坚持「shell + C，无第三方依赖」——ROM 指纹是排障时的关键凭据
 * （对比"社区 ROM vs 自己 dump 的 ROM"靠的就是它），所以必须能内建计算。
 */
#ifndef WINBOX_SHA256_H
#define WINBOX_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint32_t state[8];
  uint64_t bitlen;
  uint8_t  buffer[64];
  size_t   buflen;
} sha256_ctx;

void sha256_init(sha256_ctx *ctx);
void sha256_update(sha256_ctx *ctx, const void *data, size_t len);
void sha256_final(sha256_ctx *ctx, uint8_t out[32]);

/* 便捷函数：一次算完 */
void sha256_buf(const void *data, size_t len, uint8_t out[32]);

/* 输出小写十六进制（out 至少 65 字节） */
void sha256_hex(const uint8_t digest[32], char *out);

#endif /* WINBOX_SHA256_H */
