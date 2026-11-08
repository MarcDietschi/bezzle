// JPEG files as the Mac's Image I/O writes them (see picture-files.h), with the libjpeg-turbo that
// Skia is built with (Packages/skia, linked as libjpeg): Skia's own encoder sets libjpeg's tables
// by quality, which at the same quality are another picture than Image I/O's.
//
// Image I/O's tables, read from the files it writes on macOS 27 (one 64-entry table for brightness
// and one for colour, in the order the file keeps them, zigzag from the top left; the same for a
// 32 by 24 picture as for a 1024 by 640 one): 4:2:0, baseline, JFIF, as libjpeg's defaults are.

#include "picture-files.h"

#include <algorithm>
#include <cmath>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>

#include "third_party/externals/libjpeg-turbo/src/jpeglib.h"

namespace {

struct Tables {
    double quality;
    unsigned int luma[64];
    unsigned int chroma[64];
};

/// At 0.82, the Finder's picture of a design (Store/DesignPreview.swift).
const Tables finderPicture = {0.82,
    {2, 2, 2, 2, 2, 2, 3, 2, 2, 3, 4, 3, 3, 3, 4, 5, 4, 4, 4, 4, 5, 6, 5, 5, 5, 5, 5, 6, 8, 6, 6, 6,
     6, 6, 6, 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12},
    {2, 2, 2, 3, 3, 3, 5, 3, 3, 5, 12, 8, 7, 8, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
     12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12}};

/// At 0.72, a glimpse of a picture for the others in a shared design (Model/Live.swift's LiveGlimpse).
const Tables glimpse = {0.72,
    {2, 2, 2, 2, 2, 2, 4, 2, 2, 4, 5, 4, 4, 4, 5, 7, 5, 5, 5, 5, 7, 9, 7, 7, 7, 7, 7, 9, 11, 9, 9, 9,
     9, 9, 9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17},
    {3, 3, 3, 4, 4, 4, 7, 4, 4, 7, 18, 12, 10, 12, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
     18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18}};

/// Where each entry of a table in a file's (zigzag) order lies in a block, row by row, as libjpeg
/// takes its tables.
const int natural[64] = {
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

const Tables* tables(double quality) {
    for (const Tables* t : {&finderPicture, &glimpse}) {
        if (std::abs(t->quality - quality) < 0.001) return t;
    }
    return nullptr;
}

/// libjpeg ends the program on a mistake unless told otherwise: here it comes back to `write`.
struct Failure {
    jpeg_error_mgr manager;
    std::jmp_buf back;
};

void fail(j_common_ptr info) { std::longjmp(reinterpret_cast<Failure*>(info->err)->back, 1); }
void quiet(j_common_ptr) {}

/// What libjpeg writes into, kept where a jump back leaves it.
struct Written {
    unsigned char* bytes = nullptr;
    unsigned long count = 0;
};

bool compress(jpeg_compress_struct& info, Failure& failure, Written& written, int width, int height, const uint8_t* pixels,
              double quality) {
    if (setjmp(failure.back)) return false;
    jpeg_create_compress(&info);
    jpeg_mem_dest(&info, &written.bytes, &written.count);
    info.image_width = JDIMENSION(width);
    info.image_height = JDIMENSION(height);
    // Premultiplied, its alpha left out: what is see-through comes out black, as from Image I/O.
    info.input_components = 4;
    info.in_color_space = JCS_EXT_RGBA;
    jpeg_set_defaults(&info);
    if (const Tables* t = tables(quality)) {
        unsigned int luma[64], chroma[64];
        for (int k = 0; k < 64; k++) {
            luma[natural[k]] = t->luma[k];
            chroma[natural[k]] = t->chroma[k];
        }
        jpeg_add_quant_table(&info, 0, luma, 100, TRUE);
        jpeg_add_quant_table(&info, 1, chroma, 100, TRUE);
    } else {
        jpeg_set_quality(&info, std::clamp(int(quality * 100 + 0.5), 0, 100), TRUE);
    }
    info.optimize_coding = TRUE;
    jpeg_start_compress(&info, TRUE);
    while (info.next_scanline < info.image_height) {
        JSAMPROW row = const_cast<JSAMPROW>(pixels + size_t(info.next_scanline) * size_t(width) * 4);
        jpeg_write_scanlines(&info, &row, 1);
    }
    jpeg_finish_compress(&info);
    return true;
}

}  // namespace

namespace jpeg {

bool write(int width, int height, const uint8_t* pixels, double quality, std::vector<uint8_t>& out) {
    if (width <= 0 || height <= 0 || !pixels) return false;
    jpeg_compress_struct info = {};
    Failure failure = {};
    info.err = jpeg_std_error(&failure.manager);
    failure.manager.error_exit = fail;
    failure.manager.output_message = quiet;
    Written written;
    const bool done = compress(info, failure, written, width, height, pixels, quality);
    if (done) out.assign(written.bytes, written.bytes + written.count);
    jpeg_destroy_compress(&info);
    std::free(written.bytes);
    return done;
}

}  // namespace jpeg
