#include "include/BezzleWebP.h"
#include "src/webp/encode.h"

size_t BezzleWebPEncodeRGBA(const uint8_t *rgba, int width, int height, int stride,
                            float quality, int lossless, uint8_t **out) {
  *out = NULL;
  WebPConfig config;
  if (lossless) {
    // A little slower than cwebp's own default, for files a little smaller: an export is made once.
    if (!WebPConfigInit(&config) || !WebPConfigLosslessPreset(&config, 7)) return 0;
  } else {
    if (!WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality)) return 0;
    config.method = 5;
    // Sharper colour edges, as on lettering and flat shapes, for a little more time.
    config.use_sharp_yuv = 1;
    config.alpha_quality = 100;
  }
  config.thread_level = 1;
  if (!WebPValidateConfig(&config)) return 0;

  WebPPicture picture;
  if (!WebPPictureInit(&picture)) return 0;
  picture.width = width;
  picture.height = height;
  // Kept as RGBA until the encoder turns it into what it needs, sharply when lossy.
  picture.use_argb = 1;
  if (!WebPPictureImportRGBA(&picture, rgba, stride)) {
    WebPPictureFree(&picture);
    return 0;
  }
  WebPMemoryWriter writer;
  WebPMemoryWriterInit(&writer);
  picture.writer = WebPMemoryWrite;
  picture.custom_ptr = &writer;
  int ok = WebPEncode(&config, &picture);
  WebPPictureFree(&picture);
  if (!ok) {
    WebPMemoryWriterClear(&writer);
    return 0;
  }
  *out = writer.mem;
  return writer.size;
}

void BezzleWebPFree(void *bytes) { WebPFree(bytes); }
