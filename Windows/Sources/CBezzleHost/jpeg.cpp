// JPEG files as the Mac's Image I/O writes them (see picture-files.h), with the libjpeg-turbo that
// Skia is built with (Packages/skia, linked as libjpeg): Skia's own encoder sets libjpeg's tables
// by quality, which at the same quality are another picture than Image I/O's.
//
// What Image I/O writes, read from the files it writes on macOS 27 (kCGImageDestinationLossy-
// CompressionQuality from 0 to 1 in steps of 0.0005, and 250,000 qualities picked at random;
// pictures from 1 by 1 to 2000 by 33, noise, flat colour and designs; the tables are the same
// whatever the picture):
//
// - Its quantisation tables are its tables at quality 0 (`lowest`), each entry divided by
//   1 + 32 q³ and rounded, and at least 1: the same in every one of the 2001 steps, and in all
//   but 7 of the 250,000 others, where an entry lay within a hundred-millionth of a half and
//   Image I/O's own arithmetic rounded it up. Less than 0 is 0.
// - From 0.9944 up (as a float: 0.99439999461174 is the last double below it) every entry is 1
//   and colour is kept at full size (4:4:4); below, at a quarter (4:2:0).
// - Huffman tables are the standard ones (JPEG Annex K), not fitted to the picture; a restart
//   marker ends each row of blocks; baseline.
// - Markers: JFIF 1.1 with no unit and the DPI it is given (72 without one) as its density, Exif
//   with the DPI (when given), sRGB as its colour space and the picture's size, and Photoshop's
//   empty IPTC record. No colour profile for sRGB.
// - Colour as `planes` makes it, read from the coefficients of its files (flat colours give each
//   pixel's values in the DC terms; photos, how colour is taken to a quarter), and the last row
//   and column of blocks coded whole (`resize`).
//
// Image I/O writes the frame before the tables (SOF, DHT, DQT, DRI) where libjpeg writes the
// tables first (DQT, SOF, DHT, DRI): the same markers and the same bytes in another order. Its
// DCT is its own (neither libjpeg's integer nor its float one, nor an exact one, gives its
// coefficients), so the coded picture differs in the last bit here and there. libjpeg's integer
// DCT is used, which comes out the same on every processor; its float one comes 0.3 to 1 dB
// nearer Image I/O's pixels but makes files 3 to 13% smaller than Image I/O's at quality 1.
//
// Against Image I/O writing the same pixels (12 artboards and a photo at 11 qualities from 0 to
// 1, bezzle-render BEZZLE_JPEG_OF in the VM): the same tables, sampling and markers, byte for
// byte, in all 143; files 0.3 to 0.7% larger on average up to 0.99 (each within -1.7 to +1%),
// 1.7% smaller at 1 (up to 6.5%); decoded, a mean of 0.3 to 1.1 of a level apart, 41 to 56 dB,
// each as far from the pixels it was given as the other. Skia's encoder at quality × 100, used
// before, made the photo's files 23 to 43% smaller than the Mac's and 34 to 47 dB from them.

#include "picture-files.h"

#include <algorithm>
#include <cmath>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "third_party/externals/libjpeg-turbo/src/jpeglib.h"

namespace {

/// Image I/O's tables at quality 0, brightness then colour, in the order a file keeps them (zigzag
/// from the top left).
const unsigned int lowest[2][64] = {
    {28, 28, 28, 28, 28, 28, 48, 28, 28, 48, 68, 48, 48, 48, 68, 92,
     68, 68, 68, 68, 92, 116, 92, 92, 92, 92, 92, 116, 140, 116, 116, 116,
     116, 116, 116, 140, 140, 140, 140, 140, 140, 140, 140, 168, 168, 168, 168, 168,
     168, 196, 196, 196, 196, 196, 220, 220, 220, 220, 220, 220, 220, 220, 220, 220},
    {34, 36, 36, 56, 52, 56, 96, 52, 52, 96, 230, 156, 128, 156, 230, 230,
     230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230,
     230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230,
     230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230, 230},
};

/// Where each entry of a table in a file's (zigzag) order lies in a block, row by row, as libjpeg
/// takes its tables.
const int natural[64] = {
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

/// How Image I/O codes a picture at a quality.
struct Settings {
    /// Brightness and colour, row by row in a block, as libjpeg takes them.
    unsigned int tables[2][64];
    /// Whether colour is kept at full size (4:4:4) rather than at a quarter (4:2:0).
    bool fullColour;
};

Settings settings(double quality) {
    const double q = std::isnan(quality) ? 0 : std::clamp(quality, 0.0, 1.0);
    Settings s = {};
    s.fullColour = float(q) >= 0.9944f;
    const double divisor = 1 + 32 * q * q * q;
    for (int t = 0; t < 2; t++) {
        for (int k = 0; k < 64; k++) {
            s.tables[t][natural[k]] = s.fullColour ? 1 : std::max(1u, unsigned(std::floor(lowest[t][k] / divisor + 0.5)));
        }
    }
    return s;
}

/// A DPI as Exif keeps it, a fraction: the first of its continued fraction's convergents within a
/// billionth of it, or where what is left over comes to under a hundred-thousandth, as Image I/O
/// writes them (2048/65 for 31.5076923…, 80/9 for 8.888888808, 1083/5 for 216.6).
void fraction(double x, uint32_t& numerator, uint32_t& denominator) {
    numerator = 0;
    denominator = 1;
    if (!(x > 0) || !std::isfinite(x)) return;
    uint64_t h0 = 0, h1 = 1, k0 = 1, k1 = 0;
    double y = x;
    for (int step = 0; step < 40; step++) {
        const double a = std::floor(y);
        if (a > 4294967295.0) break;
        const uint64_t h = uint64_t(a) * h1 + h0, k = uint64_t(a) * k1 + k0;
        if (h > 0xFFFFFFFFu || k > 0xFFFFFFFFu) break;
        h0 = h1, h1 = h, k0 = k1, k1 = k;
        if (std::abs(double(h1) / double(k1) - x) <= 1e-9 * x) break;
        const double left = y - a;
        if (left <= 0 || (h1 > 0 && left <= 1e-5)) break;
        y = 1 / left;
    }
    if (k1 == 0) {
        numerator = 0xFFFFFFFFu;
        return;
    }
    numerator = uint32_t(h1);
    denominator = uint32_t(k1);
}

/// Big-endian numbers into a marker's bytes.
void put16(std::vector<uint8_t>& b, unsigned v) {
    b.push_back(uint8_t(v >> 8));
    b.push_back(uint8_t(v));
}
void put32(std::vector<uint8_t>& b, uint32_t v) {
    put16(b, v >> 16);
    put16(b, v & 0xFFFF);
}
/// One TIFF directory entry holding its value (a short or a long) or where it is.
void entry(std::vector<uint8_t>& b, unsigned tag, unsigned type, uint32_t value) {
    put16(b, tag);
    put16(b, type);
    put32(b, 1);
    if (type == 3) {
        put16(b, value);
        put16(b, 0);
    } else {
        put32(b, value);
    }
}

/// The Exif Image I/O writes: the resolution in inches when it has a DPI, sRGB, and the size.
std::vector<uint8_t> exif(int width, int height, double dpi) {
    std::vector<uint8_t> b = {'E', 'x', 'i', 'f', 0, 0, 'M', 'M', 0, 42, 0, 0, 0, 8};
    // Offsets count from the TIFF header, 6 bytes in.
    if (dpi > 0) {
        uint32_t num, den;
        fraction(dpi, num, den);
        put16(b, 4);
        entry(b, 0x011A, 5, 0x3E);  // XResolution, at 62
        entry(b, 0x011B, 5, 0x46);  // YResolution, at 70
        entry(b, 0x0128, 3, 2);     // ResolutionUnit: inches
        entry(b, 0x8769, 4, 0x4E);  // the Exif directory, at 78
        put32(b, 0);
        put32(b, num), put32(b, den);
        put32(b, num), put32(b, den);
    } else {
        put16(b, 1);
        entry(b, 0x8769, 4, 0x1A);  // the Exif directory, at 26
        put32(b, 0);
    }
    put16(b, 3);
    entry(b, 0xA001, 3, 1);  // ColorSpace: sRGB
    entry(b, 0xA002, 4, uint32_t(width));
    entry(b, 0xA003, 4, uint32_t(height));
    put32(b, 0);
    return b;
}

/// Photoshop's resources Image I/O writes: an empty IPTC record and the MD5 digest of nothing.
const uint8_t photoshop[] = {'P', 'h', 'o', 't', 'o', 's', 'h', 'o', 'p', ' ', '3', '.', '0', 0,
                             '8', 'B', 'I', 'M', 0x04, 0x04, 0, 0, 0, 0, 0, 0,
                             '8', 'B', 'I', 'M', 0x04, 0x25, 0, 0, 0, 0, 0, 0x10,
                             0xD4, 0x1D, 0x8C, 0xD9, 0x8F, 0x00, 0xB2, 0x04, 0xE9, 0x80, 0x09, 0x98, 0xEC, 0xF8, 0x42, 0x7E};

/// The picture in the planes a JPEG codes, as Image I/O makes them: brightness and the two colour
/// differences of each pixel (BT.601 at full range): the brightness from tables of each channel's
/// part in 8 bits, rounded up, which is how near Image I/O's own comes; the colour in 16-bit fixed
/// point as libjpeg has it, but rounded half up where libjpeg rounds a half down; the colour at a
/// quarter as the mean of each 2 by 2 rounded half up (libjpeg alternates up and down); each plane
/// carried on to whole blocks of the frame by repeating its last column and row, as libjpeg does.
/// On 8192 flat colours: Image I/O's brightness for 99.7% of them (libjpeg's 99.2%), its colour for
/// 99.7%; on photos, the means of 98.5 to 99.3% of the colour blocks (libjpeg's 15 to 33%).
struct Planes {
    int columns[3] = {0, 0, 0};
    int rows[3] = {0, 0, 0};
    std::vector<JSAMPLE> samples[3];
};

Planes planes(int width, int height, const uint8_t* pixels, bool fullColour) {
    // Whole frames of blocks: 16 by 16 pixels with colour at a quarter, 8 by 8 without.
    const int side = fullColour ? 8 : 16;
    const int w = (width + side - 1) / side * side, h = (height + side - 1) / side * side;
    constexpr int bits = 16;
    constexpr int32_t half = 1 << (bits - 1);
    auto fix = [](double x) { return int32_t(x * (1 << bits) + 0.5); };
    auto part = [](double x, int i) { return int32_t(std::ceil(x * i * 256)); };
    int32_t yr[256], yg[256], yb[256], ur[256], ug[256], ub[256], vr[256], vg[256], vb[256];
    for (int i = 0; i < 256; i++) {
        yr[i] = part(0.299, i), yg[i] = part(0.587, i), yb[i] = part(0.114, i) + 128;
        ur[i] = -fix(0.16874) * i, ug[i] = -fix(0.33126) * i, ub[i] = fix(0.50000) * i + (128 << bits) + half;
        vr[i] = fix(0.50000) * i + (128 << bits) + half, vg[i] = -fix(0.41869) * i, vb[i] = -fix(0.08131) * i;
    }
    auto clamp = [](int32_t v) { return JSAMPLE(std::clamp(v, 0, 255)); };
    Planes p;
    p.columns[0] = w, p.rows[0] = h;
    p.samples[0].resize(size_t(w) * size_t(h));
    std::vector<JSAMPLE> cb(size_t(w) * size_t(h)), cr(size_t(w) * size_t(h));
    for (int y = 0; y < h; y++) {
        const uint8_t* row = pixels + size_t(std::min(y, height - 1)) * size_t(width) * 4;
        JSAMPLE* to = &p.samples[0][size_t(y) * size_t(w)];
        JSAMPLE* toB = &cb[size_t(y) * size_t(w)];
        JSAMPLE* toR = &cr[size_t(y) * size_t(w)];
        for (int x = 0; x < w; x++) {
            const uint8_t* px = row + size_t(std::min(x, width - 1)) * 4;
            const int r = px[0], g = px[1], b = px[2];
            to[x] = clamp((yr[r] + yg[g] + yb[b]) >> 8);
            toB[x] = clamp((ur[r] + ug[g] + ub[b]) >> bits);
            toR[x] = clamp((vr[r] + vg[g] + vb[b]) >> bits);
        }
    }
    for (int c = 1; c < 3; c++) {
        std::vector<JSAMPLE>& full = c == 1 ? cb : cr;
        if (fullColour) {
            p.columns[c] = w, p.rows[c] = h;
            p.samples[c] = std::move(full);
            continue;
        }
        const int cw = w / 2, ch = h / 2;
        p.columns[c] = cw, p.rows[c] = ch;
        p.samples[c].resize(size_t(cw) * size_t(ch));
        for (int y = 0; y < ch; y++) {
            const JSAMPLE* a = &full[size_t(2 * y) * size_t(w)];
            const JSAMPLE* b = a + w;
            JSAMPLE* to = &p.samples[c][size_t(y) * size_t(cw)];
            for (int x = 0; x < cw; x++) to[x] = JSAMPLE((a[2 * x] + a[2 * x + 1] + b[2 * x] + b[2 * x + 1] + 2) >> 2);
        }
    }
    return p;
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

/// Sets the size the frame header (SOF0) says. Image I/O codes a picture's last row and column of
/// frames as whole blocks of it, carried on by repeating its edge, where libjpeg makes blocks
/// beyond the picture copies of the last one's mean: coded at the frames' whole size and said to
/// be the picture's own, libjpeg's file has the same blocks as Image I/O's, which a reader then
/// cuts to the picture.
bool resize(std::vector<uint8_t>& file, int width, int height) {
    size_t i = 2;
    while (i + 4 <= file.size() && file[i] == 0xFF) {
        const uint8_t marker = file[i + 1];
        const size_t length = size_t(file[i + 2]) << 8 | file[i + 3];
        if (marker == 0xC0) {
            if (i + 9 > file.size()) return false;
            file[i + 5] = uint8_t(height >> 8), file[i + 6] = uint8_t(height);
            file[i + 7] = uint8_t(width >> 8), file[i + 8] = uint8_t(width);
            return true;
        }
        if (marker == 0xDA) return false;
        i += 2 + length;
    }
    return false;
}

/// What a file is made of besides the pixels, made before libjpeg is started, since a jump back
/// from it passes by C++'s clean-up.
struct Made {
    Settings settings;
    Planes planes;
    std::vector<uint8_t> exif;
    std::vector<JSAMPROW> rows[3];
    /// Whether the whole frames are within what a JPEG holds (65500 a side, as libjpeg has it).
    bool whole = true;
};

bool compress(jpeg_compress_struct& info, Failure& failure, Written& written, int width, int height, Made& made, double dpi) {
    if (setjmp(failure.back)) return false;
    jpeg_create_compress(&info);
    jpeg_mem_dest(&info, &written.bytes, &written.count);
    // Coded as whole frames of blocks (`planes` carries the picture on to them), the frame's own
    // size put back afterwards (`resize`), unless they would be more than a JPEG holds.
    info.image_width = JDIMENSION(made.whole ? made.planes.columns[0] : width);
    info.image_height = JDIMENSION(made.whole ? made.planes.rows[0] : height);
    // Given as the planes it codes, made as Image I/O makes them (`planes`).
    info.input_components = 3;
    info.in_color_space = JCS_YCbCr;
    jpeg_set_defaults(&info);
    info.raw_data_in = TRUE;
    const Settings& s = made.settings;
    jpeg_add_quant_table(&info, 0, s.tables[0], 100, TRUE);
    jpeg_add_quant_table(&info, 1, s.tables[1], 100, TRUE);
    if (s.fullColour) info.comp_info[0].h_samp_factor = info.comp_info[0].v_samp_factor = 1;
    // The standard Huffman tables, and a restart at each row of blocks.
    info.optimize_coding = FALSE;
    info.restart_in_rows = 1;
    // JFIF 1.1, its density the DPI rounded (cut to 16 bits, as Image I/O cuts it) with no unit.
    info.write_JFIF_header = TRUE;
    info.JFIF_major_version = 1;
    info.JFIF_minor_version = 1;
    info.density_unit = 0;
    const long density = dpi > 0 ? std::lround(std::min(dpi, 1e9)) : 72;
    info.X_density = info.Y_density = UINT16(density & 0xFFFF);
    jpeg_start_compress(&info, TRUE);
    jpeg_write_marker(&info, JPEG_APP0 + 1, made.exif.data(), unsigned(made.exif.size()));
    jpeg_write_marker(&info, JPEG_APP0 + 13, photoshop, unsigned(sizeof photoshop));
    // A row of frames at a time: 16 rows of brightness and 8 of colour, or 8 of each.
    const Planes& p = made.planes;
    const int lines = s.fullColour ? 8 : 16;
    while (info.next_scanline < info.image_height) {
        JSAMPARRAY planes[3];
        for (int c = 0; c < 3; c++) {
            const int first = int(info.next_scanline) * p.rows[c] / p.rows[0], count = lines * p.rows[c] / p.rows[0];
            for (int k = 0; k < count; k++) made.rows[c][size_t(k)] = const_cast<JSAMPLE*>(&p.samples[c][size_t(first + k) * size_t(p.columns[c])]);
            planes[c] = made.rows[c].data();
        }
        if (jpeg_write_raw_data(&info, planes, JDIMENSION(lines)) == 0) return false;
    }
    jpeg_finish_compress(&info);
    return true;
}

}  // namespace

namespace jpeg {

bool write(int width, int height, const uint8_t* pixels, double quality, double dpi, std::vector<uint8_t>& out) {
    if (width <= 0 || height <= 0 || !pixels) return false;
    Made made;
    made.settings = settings(quality);
    // Premultiplied, its alpha left out: what is see-through comes out black, as from Image I/O.
    made.planes = planes(width, height, pixels, made.settings.fullColour);
    made.exif = exif(width, height, dpi);
    made.whole = made.planes.columns[0] <= 65500 && made.planes.rows[0] <= 65500;
    for (auto& r : made.rows) r.resize(16);
    jpeg_compress_struct info = {};
    Failure failure = {};
    info.err = jpeg_std_error(&failure.manager);
    failure.manager.error_exit = fail;
    failure.manager.output_message = quiet;
    Written written;
    bool done = compress(info, failure, written, width, height, made, dpi);
    if (done) {
        out.assign(written.bytes, written.bytes + written.count);
        done = !made.whole || resize(out, width, height);
    }
    jpeg_destroy_compress(&info);
    std::free(written.bytes);
    return done;
}

}  // namespace jpeg
