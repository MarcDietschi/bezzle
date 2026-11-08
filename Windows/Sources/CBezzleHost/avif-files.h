// AVIF files, read and written with libavif and libaom (avif.cpp; Windows/avif.ps1 builds them into
// Windows/Packages/avif). Apart from host.cpp and without Skia, so the same code can be tried on
// any machine; host.cpp makes Skia's pictures of what it reads.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vector>

namespace avif {

/// Whether this build reads and writes AVIF (it was linked with libavif).
bool available();

/// Whether `data` is an AVIF file, by the brands its first box names.
bool sniff(const void *data, size_t count);

/// A picture read from an AVIF file: premultiplied RGBA, 8 bits a channel, or 16 when the file
/// keeps more than 8, rows top first; and what its colours mean.
struct Picture {
    int width = 0, height = 0;
    bool sixteen = false;
    bool opaque = true;
    std::vector<uint8_t> pixels;
    /// Its ICC profile when it has one; otherwise its colours by the numbers of ITU-T H.273
    /// (primaries, transfer), 2 for unspecified, which reads as sRGB.
    std::vector<uint8_t> icc;
    int primaries = 2, transfer = 2;
    /// The eight numbers of its primaries and white point (x, y each), as libavif knows them.
    float chromaticities[8] = {};
    /// How bright an HDR picture says it gets, in nits, 0 where it does not say: its content light
    /// level ('clli' MaxCLL) and its mastering display's peak ('mdcv').
    double maxCLL = 0, mastering = 0;
};

/// How big the picture is: cropped to its clean aperture, and turned by its rotation and mirror
/// when `upright` (as Image I/O makes a picture with kCGImageSourceCreateThumbnailWithTransform);
/// otherwise as kept (as Image I/O counts PixelWidth and PixelHeight).
bool size(const void *data, size_t count, bool upright, int *width, int *height);

/// Reads the picture, as `size` measures it.
bool read(const void *data, size_t count, bool upright, Picture &picture);

/// Writes premultiplied sRGB RGBA pixels (8 bits, rows top first, `width` × 4 bytes a row) as an
/// AVIF file, as the Mac's Image I/O writes one at `quality` (0…1, Bezzle's export quality).
bool write(int width, int height, const uint8_t *pixels, double quality, std::vector<uint8_t> &out);

/// The same with libavif's own qualities (0…100) for colour and alpha, and speed (0…10), to
/// compare with the Mac's.
bool write(int width, int height, const uint8_t *pixels, int avifQuality, int alphaQuality, int speed, std::vector<uint8_t> &out);

/// libavif's quality for Bezzle's export quality.
int qualityFor(double quality);
/// libavif's quality for the alpha, at every export quality.
extern const int alphaQuality;

}  // namespace avif
