#ifndef BEZZLE_WEBP_H
#define BEZZLE_WEBP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Encodes straight (not premultiplied) RGBA pixels, `stride` bytes to a row, as a WebP file.
/// `quality` is 0…100 and only counts when `lossless` is 0. Returns the file's size and puts its
/// bytes in `*out`, to be freed with BezzleWebPFree; returns 0 when it could not be encoded.
size_t BezzleWebPEncodeRGBA(const uint8_t *rgba, int width, int height, int stride,
                            float quality, int lossless, uint8_t **out);

void BezzleWebPFree(void *bytes);

#ifdef __cplusplus
}
#endif

#endif
