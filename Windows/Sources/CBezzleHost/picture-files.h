// Picture files Skia does not write or read the Mac's way: JPEG as the Mac's Image I/O writes it
// (jpeg.cpp, libjpeg-turbo, as Skia built it), and HEIF pictures, HEIC from iPhones above all,
// read by Windows' own codecs where it has them (heif.cpp, the Windows Imaging Component). Apart
// from host.cpp, whose Skia headers mix neither with libjpeg's nor with windows.h; host.cpp makes
// Skia's pictures of what they read.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vector>

namespace jpeg {

/// Premultiplied sRGB RGBA pixels (8 bits, rows top first, `width` × 4 bytes a row) as a JPEG
/// file, as the Mac's Image I/O writes one at `quality` (0…1, kCGImageDestinationLossyCompressionQuality)
/// and `dpi` (kCGImagePropertyDPIWidth and Height; 0 or less when none is given): Image I/O's own
/// quantisation tables and colour sampling at every quality, its Huffman tables, restarts and
/// markers (jpeg.cpp tells what they are). What is see-through is left as it is premultiplied
/// (black), as Image I/O leaves it. On any thread.
bool write(int width, int height, const uint8_t *pixels, double quality, double dpi, std::vector<uint8_t> &out);

}  // namespace jpeg

namespace heif {

/// Whether `data` is an HEIF file holding a picture coded as HEVC (HEIC, as iPhones and the Mac
/// make it), by the brands its 'ftyp' box names; AVIF, also HEIF, goes to avif.cpp instead.
bool sniff(const void *data, size_t count);

/// Why Windows read no HEIF picture, when it did not.
enum Problem {
    none = 0,
    /// It has no HEIF codec: Microsoft's HEIF Image Extensions are not installed.
    noHEIF = 1,
    /// It has the HEIF codec but nothing to decode HEVC with: Microsoft's HEVC Video Extensions
    /// are not installed.
    noHEVC = 2,
    /// The file is damaged, or something else went wrong.
    unreadable = 3,
};

/// A picture read from an HEIF file: as kept, premultiplied RGBA, 8 bits, rows top first; how it is
/// to be turned and mirrored to stand upright (its 'irot' and 'imir', as Exif numbers them, 1 for
/// as it is); and its ICC profile when it has one (an iPhone's Display P3), else it is sRGB.
struct Picture {
    int width = 0, height = 0;
    int orientation = 1;
    std::vector<uint8_t> pixels;
    std::vector<uint8_t> icc;
};

/// Reads the file's picture. On any thread. Returns why not when it could not.
Problem read(const void *data, size_t count, Picture &picture);

/// How big the picture is, upright as it is turned when `upright` (as Image I/O makes it with
/// kCGImageSourceCreateThumbnailWithTransform), else as kept; without decoding it.
Problem size(const void *data, size_t count, bool upright, int *width, int *height);

/// Why the last HEIF picture Windows could not read was not read; none when every one so far was.
Problem lastProblem();

}  // namespace heif
