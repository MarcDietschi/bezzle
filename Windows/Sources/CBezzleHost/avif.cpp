// AVIF files on Windows, as Image I/O reads and writes them on the Mac (Export/Exporter.swift writes
// "public.avif"; Canvas/Assets.swift reads pictures turned upright): libavif with libaom, built by
// Windows/avif.ps1 into Windows/Packages/avif. Without them (BEZZLE_AVIF undefined) Bezzle neither
// reads nor writes AVIF, as a Mac whose Image I/O cannot write it leaves the format out.
//
// What the Mac writes, read from its files' boxes on macOS 27: 8-bit 4:2:0, full range, the BT.601
// matrix, colours as sRGB (its nclx says "unspecified", which reads as sRGB; here it says sRGB),
// see-through parts as an auxiliary alpha picture, not premultiplied, none when all is opaque, no
// ICC profile, no resolution; an odd size padded to even and cropped back (clean aperture), which
// libavif needs not do. Pictures past AV1's largest level (6.3) go as a grid of cells, as Apple's
// do from about a megapixel on (512-pixel cells), but only then: one piece is a little smaller.
// Files written here read back on the Mac as sRGB with alpha, as its own do; the same pixels give
// the same bytes here as with libavif built on the Mac.

#include "avif-files.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>

#ifdef BEZZLE_AVIF
#include "avif/avif.h"
#endif

namespace avif {

bool sniff(const void *data, size_t count) {
    // ISO base media: a 'ftyp' box first, naming 'avif' (a picture) or 'avis' (a sequence) as its
    // major brand or among those it is compatible with.
    const auto *b = static_cast<const uint8_t *>(data);
    if (!b || count < 16 || std::memcmp(b + 4, "ftyp", 4) != 0) return false;
    const size_t box = std::min<size_t>(count, (size_t(b[0]) << 24) | (size_t(b[1]) << 16) | (size_t(b[2]) << 8) | b[3]);
    auto brand = [&](size_t at) { return at + 4 <= box && (std::memcmp(b + at, "avif", 4) == 0 || std::memcmp(b + at, "avis", 4) == 0); };
    if (brand(8)) return true;
    for (size_t at = 16; at + 4 <= box; at += 4) {
        if (brand(at)) return true;
    }
    return false;
}

// Bezzle's quality as libavif's, so that a file keeps as much of the picture as the Mac's does at
// the same quality (the same PSNR), measured against Image I/O on macOS 27 writing the same
// pixels: a photo, a cut-out photo with see-through parts and a screen of an app's windows. Image
// I/O writes nothing at 1, so Bezzle asks it for 0.99 at the top, which it writes as all of the
// 4:2:0 picture (libavif's 100, within 1% of its size); its see-through parts it keeps at one
// quality, whatever the picture's (an alpha PSNR of 57.6 dB on the cut-out; libavif's 88 gives
// 57.5). At 0.9 the files came out 93 to 104% of the Mac's size, within 0.2 dB.
const int alphaQuality = 88;

int qualityFor(double quality) {
    static const double mac[] = {0, 0.3, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99};
    static const double libavif[] = {0, 32, 52, 61, 69, 78, 90, 96, 100};
    const double q = std::clamp(quality, 0.0, 0.99);
    size_t k = 1;
    while (k < std::size(mac) - 1 && q > mac[k]) k++;
    const double t = (q - mac[k - 1]) / (mac[k] - mac[k - 1]);
    return std::clamp(int(std::lround(libavif[k - 1] + t * (libavif[k] - libavif[k - 1]))), 0, 100);
}

#ifdef BEZZLE_AVIF

namespace {

int threads() { return std::max(1, int(std::thread::hardware_concurrency())); }

/// A decoder over the file's bytes, its first picture's properties read; null if it is none.
avifDecoder *opened(const void *data, size_t count) {
    if (!sniff(data, count)) return nullptr;
    avifDecoder *decoder = avifDecoderCreate();
    if (!decoder) return nullptr;
    // One thread for libaom: with more it took three times the memory for a large picture (3.9 GB
    // for 35 megapixels in one piece), and hardly less time; the colours are turned in parallel.
    decoder->maxThreads = 1;
    decoder->ignoreExif = AVIF_TRUE;
    decoder->ignoreXMP = AVIF_TRUE;
    // As forgiving as Image I/O: files from older writers lack some of what the standard asks.
    decoder->strictFlags = AVIF_STRICT_DISABLED;
    if (avifDecoderSetIOMemory(decoder, static_cast<const uint8_t *>(data), count) != AVIF_RESULT_OK ||
        avifDecoderParse(decoder) != AVIF_RESULT_OK) {
        avifDecoderDestroy(decoder);
        return nullptr;
    }
    return decoder;
}

/// The part of the coded picture its clean aperture keeps: all of it when it has none.
avifCropRect kept(const avifImage *image) {
    avifCropRect rect = {0, 0, image->width, image->height};
    if (image->transformFlags & AVIF_TRANSFORM_CLAP) {
        avifCropRect clap;
        avifDiagnostics diag;
        if (avifCropRectFromCleanApertureBox(&clap, &image->clap, image->width, image->height, &diag) && clap.width > 0 && clap.height > 0) rect = clap;
    }
    return rect;
}

/// Turned a quarter or more (anticlockwise, as 'irot' counts) and mirrored ('imir': 0 exchanges top
/// and bottom, 1 left and right), in the order the standard applies them: clean aperture, then
/// rotation, then mirror.
int quarters(const avifImage *image) { return (image->transformFlags & AVIF_TRANSFORM_IROT) ? image->irot.angle & 3 : 0; }
int mirror(const avifImage *image) { return (image->transformFlags & AVIF_TRANSFORM_IMIR) ? image->imir.axis : -1; }

/// Pixels of `bytes` each, `w` by `h`, turned and mirrored as `upright` would show them.
std::vector<uint8_t> turned(const std::vector<uint8_t> &from, int w, int h, int bytes, int quarter, int axis, int &outW, int &outH) {
    outW = (quarter & 1) ? h : w;
    outH = (quarter & 1) ? w : h;
    std::vector<uint8_t> to(from.size());
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int tx = x, ty = y;
            switch (quarter) {
                case 1: tx = y; ty = w - 1 - x; break;          // a quarter anticlockwise
                case 2: tx = w - 1 - x; ty = h - 1 - y; break;
                case 3: tx = h - 1 - y; ty = x; break;          // three quarters: a quarter clockwise
                default: break;
            }
            if (axis == 0) ty = outH - 1 - ty;
            if (axis == 1) tx = outW - 1 - tx;
            std::memcpy(&to[(size_t(ty) * outW + tx) * bytes], &from[(size_t(y) * w + x) * bytes], size_t(bytes));
        }
    }
    return to;
}

}  // namespace

bool available() { return true; }

bool size(const void *data, size_t count, bool upright, int *width, int *height) {
    avifDecoder *decoder = opened(data, count);
    if (!decoder) return false;
    const avifCropRect rect = kept(decoder->image);
    const bool sideways = upright && (quarters(decoder->image) & 1);
    *width = int(sideways ? rect.height : rect.width);
    *height = int(sideways ? rect.width : rect.height);
    avifDecoderDestroy(decoder);
    return *width > 0 && *height > 0;
}

bool read(const void *data, size_t count, bool upright, Picture &picture) {
    avifDecoder *decoder = opened(data, count);
    if (!decoder) return false;
    bool done = false;
    if (avifDecoderNextImage(decoder) == AVIF_RESULT_OK) {
        const avifImage *image = decoder->image;
        avifRGBImage rgb;
        avifRGBImageSetDefaults(&rgb, image);
        rgb.format = AVIF_RGB_FORMAT_RGBA;
        rgb.depth = image->depth > 8 ? 16 : 8;
        rgb.alphaPremultiplied = AVIF_TRUE;
        rgb.maxThreads = threads();
        if (avifRGBImageAllocatePixels(&rgb) == AVIF_RESULT_OK) {
            if (avifImageYUVToRGB(image, &rgb) == AVIF_RESULT_OK) {
                const int bytes = rgb.depth > 8 ? 8 : 4;
                const avifCropRect rect = kept(image);
                std::vector<uint8_t> pixels(size_t(rect.width) * rect.height * bytes);
                for (uint32_t y = 0; y < rect.height; y++) {
                    std::memcpy(&pixels[size_t(y) * rect.width * bytes], rgb.pixels + size_t(rect.y + y) * rgb.rowBytes + size_t(rect.x) * bytes,
                                size_t(rect.width) * bytes);
                }
                int w = int(rect.width), h = int(rect.height);
                if (upright && (quarters(image) || mirror(image) >= 0)) {
                    int tw = 0, th = 0;
                    pixels = turned(pixels, w, h, bytes, quarters(image), mirror(image), tw, th);
                    w = tw;
                    h = th;
                }
                picture.width = w;
                picture.height = h;
                picture.sixteen = bytes == 8;
                picture.opaque = image->alphaPlane == nullptr;
                picture.pixels = std::move(pixels);
                picture.icc.assign(image->icc.data, image->icc.data + image->icc.size);
                picture.primaries = int(image->colorPrimaries);
                picture.transfer = int(image->transferCharacteristics);
                avifColorPrimariesGetValues(image->colorPrimaries, picture.chromaticities);
                done = true;
            }
            avifRGBImageFreePixels(&rgb);
        }
    }
    avifDecoderDestroy(decoder);
    return done;
}

bool write(int width, int height, const uint8_t *pixels, int avifQuality, int alphaQuality, int speed, std::vector<uint8_t> &out) {
    if (width <= 0 || height <= 0 || !pixels) return false;
    avifImage *image = avifImageCreate(uint32_t(width), uint32_t(height), 8, AVIF_PIXEL_FORMAT_YUV420);
    if (!image) return false;
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;
    image->yuvRange = AVIF_RANGE_FULL;

    bool opaque = true;
    for (size_t k = 3, n = size_t(width) * height * 4; k < n && opaque; k += 4) opaque = pixels[k] == 255;
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.depth = 8;
    rgb.alphaPremultiplied = AVIF_TRUE;
    // Wholly opaque, it has no alpha at all, as the Mac's has none then.
    rgb.ignoreAlpha = opaque ? AVIF_TRUE : AVIF_FALSE;
    rgb.pixels = const_cast<uint8_t *>(pixels);
    rgb.rowBytes = uint32_t(width) * 4;

    avifEncoder *encoder = nullptr;
    avifRWData output = AVIF_DATA_EMPTY;
    bool done = avifImageRGBToYUV(image, &rgb) == AVIF_RESULT_OK && (encoder = avifEncoderCreate()) != nullptr;
    if (done) {
        encoder->maxThreads = threads();
        encoder->speed = speed;
        encoder->quality = std::clamp(avifQuality, 0, 100);
        encoder->qualityAlpha = std::clamp(alphaQuality, 0, 100);
        encoder->autoTiling = AVIF_TRUE;
        // AV1's largest level, 6.3, takes at most 35 651 584 pixels, 16 384 wide and 8 704 high;
        // past that, the picture goes as a grid of cells, which every reader puts together.
        const bool large = int64_t(width) * height > 35651584 || width > 16384 || height > 8704;
        if (large && width % 2 == 0 && height % 2 == 0) {
            const int cell = 2048;
            const int cols = (width + cell - 1) / cell, rows = (height + cell - 1) / cell;
            std::vector<avifImage *> cells;
            for (int r = 0; r < rows && done; r++) {
                for (int c = 0; c < cols && done; c++) {
                    avifImage *view = avifImageCreateEmpty();
                    const avifCropRect rect = {uint32_t(c * cell), uint32_t(r * cell), uint32_t(std::min(cell, width - c * cell)),
                                               uint32_t(std::min(cell, height - r * cell))};
                    done = view && avifImageSetViewRect(view, image, &rect) == AVIF_RESULT_OK;
                    if (view) cells.push_back(view);
                }
            }
            done = done && avifEncoderAddImageGrid(encoder, uint32_t(cols), uint32_t(rows), cells.data(), AVIF_ADD_IMAGE_FLAG_SINGLE) == AVIF_RESULT_OK &&
                   avifEncoderFinish(encoder, &output) == AVIF_RESULT_OK;
            for (avifImage *view : cells) avifImageDestroy(view);
        } else {
            done = avifEncoderWrite(encoder, image, &output) == AVIF_RESULT_OK;
        }
    }
    if (done) out.assign(output.data, output.data + output.size);
    avifRWDataFree(&output);
    if (encoder) avifEncoderDestroy(encoder);
    avifImageDestroy(image);
    return done && !out.empty();
}

#else

bool available() { return false; }
bool size(const void *, size_t, bool, int *, int *) { return false; }
bool read(const void *, size_t, bool, Picture &) { return false; }
bool write(int, int, const uint8_t *, int, int, int, std::vector<uint8_t> &) { return false; }

#endif

bool write(int width, int height, const uint8_t *pixels, double quality, std::vector<uint8_t> &out) {
    return write(width, height, pixels, qualityFor(quality), alphaQuality, 6, out);
}

}  // namespace avif
