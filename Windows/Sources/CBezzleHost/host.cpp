// Bezzle's core on Windows, the part Skia does: see BezzleHost.h. Each piece follows its
// counterpart in Web/site/bezzle.mjs, which does the same with CanvasKit (Skia in the browser), so
// a design draws and measures here as it does there, and there as on the Mac.

#include "BezzleHost.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkBlurTypes.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkRRect.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPathUtils.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/codec/SkCodec.h"
#include "include/codec/SkEncodedOrigin.h"
#include "include/codec/SkJpegDecoder.h"
#include "include/codec/SkPngDecoder.h"
#include "include/codec/SkWebpDecoder.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/encode/SkPngEncoder.h"
#include "include/encode/SkJpegEncoder.h"
#include "include/encode/SkWebpEncoder.h"
#include "include/docs/SkPDFDocument.h"
#include "include/docs/SkPDFJpegHelpers.h"
#include "include/effects/SkGradient.h"
#include "include/effects/SkImageFilters.h"
#include "include/pathops/SkPathOps.h"
#include "include/ports/SkFontMgr_empty.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skparagraph/include/TypefaceFontProvider.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <algorithm>
#include <array>
#include <iterator>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace skia::textlayout;

namespace {

std::mutex lock;

/// With BEZZLE_HOST_TRACE set, what a drawing asks for and is not there goes to stderr.
bool tracing() {
    static const bool on = getenv("BEZZLE_HOST_TRACE") != nullptr;
    return on;
}

std::vector<uint8_t> answer;

void keep(const std::vector<double>& values) {
    answer.resize(values.size() * sizeof(double));
    if (!values.empty()) memcpy(answer.data(), values.data(), answer.size());
}

// MARK: Paths, as CanvasKit's commands: a verb, then its points.

enum Verb { kMove = 0, kLine = 1, kQuad = 2, kConic = 3, kCubic = 4, kClose = 5 };

SkPath readPath(const double* c, size_t n, SkPathFillType fill) {
    SkPathBuilder b(fill);
    size_t i = 0;
    auto f = [&](size_t k) { return static_cast<float>(c[i + k]); };
    while (i < n) {
        switch (static_cast<int>(c[i++])) {
            case kMove: if (i + 2 > n) return b.detach(); b.moveTo(f(0), f(1)); i += 2; break;
            case kLine: if (i + 2 > n) return b.detach(); b.lineTo(f(0), f(1)); i += 2; break;
            case kQuad: if (i + 4 > n) return b.detach(); b.quadTo(f(0), f(1), f(2), f(3)); i += 4; break;
            case kConic: if (i + 5 > n) return b.detach(); b.conicTo(f(0), f(1), f(2), f(3), f(4)); i += 5; break;
            case kCubic: if (i + 6 > n) return b.detach(); b.cubicTo(f(0), f(1), f(2), f(3), f(4), f(5)); i += 6; break;
            case kClose: b.close(); break;
            default: return b.detach();
        }
    }
    return b.detach();
}

void writePath(const SkPath& path, std::vector<double>& out) {
    SkPath::Iter it(path, false);
    while (auto r = it.next()) {
        const auto& p = r->fPoints;
        switch (r->fVerb) {
            case SkPathVerb::kMove: out.insert(out.end(), {double(kMove), p[0].fX, p[0].fY}); break;
            case SkPathVerb::kLine: out.insert(out.end(), {double(kLine), p[1].fX, p[1].fY}); break;
            case SkPathVerb::kQuad: out.insert(out.end(), {double(kQuad), p[1].fX, p[1].fY, p[2].fX, p[2].fY}); break;
            case SkPathVerb::kConic:
                out.insert(out.end(), {double(kConic), p[1].fX, p[1].fY, p[2].fX, p[2].fY, r->fConicWeight});
                break;
            case SkPathVerb::kCubic:
                out.insert(out.end(), {double(kCubic), p[1].fX, p[1].fY, p[2].fX, p[2].fY, p[3].fX, p[3].fY});
                break;
            case SkPathVerb::kClose: out.push_back(double(kClose)); break;
        }
    }
}

SkPathFillType fillOf(double rule) { return rule == 1 ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding; }

/// op, rule, then path A, path B and parameters, each counted: as bezzle.mjs's pathOp.
std::vector<double> pathOp(const double* v, size_t n) {
    std::vector<double> out;
    if (n < 3) return out;
    size_t i = 0;
    const int op = int(v[i++]);
    const auto fill = fillOf(v[i++]);
    const size_t nA = size_t(v[i++]); if (i + nA > n) return out;
    const double* a = v + i; i += nA;
    const size_t nB = i < n ? size_t(v[i++]) : 0; if (i + nB > n) return out;
    const double* b = v + i; i += nB;
    const size_t nP = i < n ? size_t(v[i++]) : 0; if (i + nP > n) return out;
    const double* p = v + i;
    const SkPath A = readPath(a, nA, fill);
    std::optional<SkPath> R;
    if (op >= 1 && op <= 4) {
        const SkPathOp ops[] = {kUnion_SkPathOp, kIntersect_SkPathOp, kDifference_SkPathOp, kXOR_SkPathOp};
        R = Op(A, readPath(b, nB, fill), ops[op - 1]);
    } else if (op == 5) {
        R = Simplify(A);
    } else if (op == 6 && nP >= 4) {
        SkPaint paint;
        paint.setStyle(SkPaint::kStroke_Style);
        paint.setStrokeWidth(float(p[0]));
        const SkPaint::Cap caps[] = {SkPaint::kButt_Cap, SkPaint::kRound_Cap, SkPaint::kSquare_Cap};
        const SkPaint::Join joins[] = {SkPaint::kMiter_Join, SkPaint::kRound_Join, SkPaint::kBevel_Join};
        paint.setStrokeCap(caps[std::clamp(int(p[1]), 0, 2)]);
        paint.setStrokeJoin(joins[std::clamp(int(p[2]), 0, 2)]);
        paint.setStrokeMiter(float(p[3]));
        R = skpathutils::FillPathWithPaint(A, paint);
    } else if (op == 7) {
        // makeDashed(on, off, phase): the dashes as a hairline would draw them, not stroked.
        const float on = nP > 1 ? float(p[1]) : 1, off = nP > 2 ? float(p[2]) : on;
        const float intervals[] = {on, off};
        SkPaint paint;
        paint.setStyle(SkPaint::kStroke_Style);
        paint.setStrokeWidth(0);
        paint.setPathEffect(SkDashPathEffect::Make(intervals, nP > 0 ? float(p[0]) : 0));
        R = skpathutils::FillPathWithPaint(A, paint);
    }
    if (R) writePath(*R, out);
    return out;
}

// MARK: Pictures

struct Asset { sk_sp<SkImage> image; };
std::vector<Asset> assets;                      // by number - 1
std::map<std::string, int> assetsByName;

sk_sp<SkImage> decode(const void* data, size_t count) {
    static std::once_flag registered;
    std::call_once(registered, [] {
        SkCodecs::Register(SkPngDecoder::Decoder());
        SkCodecs::Register(SkJpegDecoder::Decoder());
        SkCodecs::Register(SkWebpDecoder::Decoder());
    });
    if (!data || !count) return nullptr;
    auto image = SkImages::DeferredFromEncodedData(SkData::MakeWithCopy(data, count));
    // With mipmaps, as the page makes them, for pictures drawn smaller.
    auto raster = image ? image->makeRasterImage(nullptr) : nullptr;
    return raster ? raster->withDefaultMipmaps() : nullptr;
}

extern "C" int32_t bz_image_size(const void* data, int32_t count, int32_t* width, int32_t* height) {
    decode(nullptr, 0);  // the decoders, registered once
    auto codec = SkCodec::MakeFromData(SkData::MakeWithoutCopy(data, size_t(count)));
    if (!codec) return 0;
    const auto d = codec->dimensions();
    // Turned on its side by its orientation, it is as wide as it is tall.
    const bool turned = SkEncodedOriginSwapsWidthHeight(codec->getOrigin());
    *width = turned ? d.height() : d.width();
    *height = turned ? d.width() : d.height();
    return d.width() > 0 && d.height() > 0 ? 1 : 0;
}

/// A picture by name: its number, width and height, or 0 when there is none (bezzle.mjs's image).
std::vector<double> imageByName(const double* v, size_t n) {
    std::string name;
    for (size_t i = 0; i < n; i++) name.push_back(char(int(v[i])));
    auto it = assetsByName.find(name);
    if (it == assetsByName.end()) {
        if (tracing()) fprintf(stderr, "[host] no asset %s\n", name.c_str());
        return {0};
    }
    const auto& image = assets[it->second - 1].image;
    return {double(it->second), double(image->width()), double(image->height())};
}

struct Picture {
    enum Kind { kAsset, kRecording, kChanged, kPixels } kind = kAsset;
    int width = 0, height = 0;
    int asset = 0;
    std::vector<double> commands;
    int from = 0;
    double crop[4] = {0, 0, 0, 0};
    double blur = -1;
    bool clamp = false;
    bool hasPerspective = false;
    double perspective[9] = {};
    bool hasRamp = false;
    double ramp[4] = {};
    int bytesPerRow = 0;
    std::vector<uint8_t> pixels;
    /// A photo developed (bz_picture_develop): its colour cube, `cubeSize` a side, and the rest.
    bool develops = false;
    std::vector<float> cube;
    int cubeSize = 0;
    double dehaze = 0, clarity = 0, texture = 0, sharpness = 0;
};
std::map<int, Picture> pictures;
std::map<int, sk_sp<SkImage>> made;

sk_sp<SkImage> get(int id);
void play(SkCanvas* canvas, const double* c, size_t n);

SkImageInfo rgba(int w, int h) {
    return SkImageInfo::Make(std::max(1, w), std::max(1, h), kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
}

template <typename Draw> sk_sp<SkImage> raster(int w, int h, Draw draw) {
    auto surface = SkSurfaces::Raster(rgba(w, h));
    if (!surface) return nullptr;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    draw(canvas);
    return surface->makeImageSnapshot();
}

// MARK: Developing photos, as the Mac's Developer does with Core Image

namespace develop {

inline float encode(float x) {
    const float a = std::fabs(x);
    const float v = a <= 0.0031308f ? a * 12.92f : 1.055f * std::pow(a, 1.0f / 2.4f) - 0.055f;
    return x < 0 ? -v : v;
}
inline float decode(float x) {
    const float a = std::fabs(x);
    const float v = a <= 0.04045f ? a / 12.92f : std::pow((a + 0.055f) / 1.055f, 2.4f);
    return x < 0 ? -v : v;
}
inline float luma(const float* c) { return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]; }

SkImageInfo linear(int w, int h) {
    return SkImageInfo::Make(w, h, kRGBA_F32_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGBLinear());
}

/// A picture as Core Image works on it: light itself, premultiplied, four floats a pixel.
std::vector<float> read(const sk_sp<SkImage>& image, int w, int h) {
    std::vector<float> px(size_t(w) * h * 4);
    auto surface = SkSurfaces::Raster(linear(w, h));
    if (!surface) return {};
    surface->getCanvas()->clear(SK_ColorTRANSPARENT);
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    surface->getCanvas()->drawImageRect(image, SkRect::MakeWH(float(w), float(h)), SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), &paint);
    surface->readPixels(linear(w, h), px.data(), size_t(w) * 16, 0, 0);
    return px;
}

/// The same pixels blurred by `sigma`, their edges carried on outward first, as Core Image's
/// clamped Gaussian blur is: in light, as Core Image blurs.
std::vector<float> blurred(const std::vector<float>& px, int w, int h, float sigma) {
    SkPixmap source(linear(w, h), px.data(), size_t(w) * 16);
    auto image = SkImages::RasterFromPixmapCopy(source);
    auto surface = SkSurfaces::Raster(linear(w, h));
    std::vector<float> out(px.size());
    if (!image || !surface) return px;
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrc);
    paint.setImageFilter(SkImageFilters::Blur(sigma, sigma, SkTileMode::kClamp, nullptr));
    surface->getCanvas()->drawImage(image, 0, 0, SkSamplingOptions(), &paint);
    surface->readPixels(linear(w, h), out.data(), size_t(w) * 16, 0, 0);
    return out;
}

/// A pixel as the Mac's kernels see it: unpremultiplied, through the sRGB curve.
inline void seen(const float* p, float* c) {
    const float a = p[3];
    for (int k = 0; k < 3; k++) c[k] = encode(a > 0.0001f ? p[k] / a : 0);
}

/// The colour of a picture's haze: that of its haziest part, where even its darkest colour is
/// lightest, as a sky usually is (the Mac's Developer.air), from the picture read small.
void air(const sk_sp<SkImage>& image, float out[3]) {
    out[0] = out[1] = out[2] = 0.9f;
    const int w0 = image->width(), h0 = image->height();
    const double s = std::min(1.0, 96.0 / std::max(w0, h0));
    const int w = std::max(1, int(std::lround(w0 * s))), h = std::max(1, int(std::lround(h0 * s)));
    const SkImageInfo info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::Raster(info);
    if (!surface) return;
    surface->getCanvas()->clear(SK_ColorTRANSPARENT);
    surface->getCanvas()->drawImageRect(image, SkRect::MakeWH(float(w), float(h)), SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), nullptr);
    std::vector<uint8_t> px(size_t(w) * h * 4);
    surface->readPixels(info, px.data(), size_t(w) * 4, 0, 0);
    std::vector<std::pair<float, std::array<float, 3>>> darks;
    for (size_t i = 0; i < size_t(w) * h; i++) {
        const float a = px[i * 4 + 3] / 255.0f;
        if (a <= 0.5f) continue;
        const std::array<float, 3> c = {px[i * 4] / 255.0f / a, px[i * 4 + 1] / 255.0f / a, px[i * 4 + 2] / 255.0f / a};
        darks.push_back({std::min({c[0], c[1], c[2]}), c});
    }
    std::sort(darks.begin(), darks.end(), [](const auto& x, const auto& y) { return x.first > y.first; });
    const size_t top = std::max<size_t>(1, darks.size() / 100);
    if (darks.empty()) return;
    float sum[3] = {0, 0, 0};
    for (size_t i = 0; i < top && i < darks.size(); i++) for (int k = 0; k < 3; k++) sum[k] += darks[i].second[k];
    const size_t n = std::min(top, darks.size());
    for (int k = 0; k < 3; k++) out[k] = std::clamp(sum[k] / float(n), 0.45f, 1.0f);
}

/// The haze taken away, or more laid over, after the dark channel prior (the Mac's
/// Developer.dehazed and its bezzleDehaze kernel), worked out on a quarter of the picture.
void dehaze(std::vector<float>& px, int w, int h, double amount, const float air[3]) {
    const double longest = std::max(w, h);
    const int qw = std::max(1, int(std::lround(w * 0.25))), qh = std::max(1, int(std::lround(h * 0.25)));
    // A quarter of the picture, its darkest colour round about each pixel, softened.
    std::vector<float> small(size_t(qw) * qh * 4);
    for (int y = 0; y < qh; y++) {
        for (int x = 0; x < qw; x++) {
            // Box-sampled down, as a quarter scale averages what it covers.
            float sum[4] = {0, 0, 0, 0};
            int count = 0;
            for (int dy = 0; dy < 4; dy++) for (int dx = 0; dx < 4; dx++) {
                const int sx = std::min(w - 1, x * 4 + dx), sy = std::min(h - 1, y * 4 + dy);
                const float* p = &px[(size_t(sy) * w + sx) * 4];
                for (int k = 0; k < 4; k++) sum[k] += p[k];
                count++;
            }
            float* o = &small[(size_t(y) * qw + x) * 4];
            const float m = std::min({sum[0], sum[1], sum[2]}) / count;
            o[0] = o[1] = o[2] = m;
            o[3] = sum[3] / count;
        }
    }
    const int reach = std::max(1, int(std::lround(longest * 0.25 * 0.01)));
    // The darkest in a square `reach` each way: across, then down.
    std::vector<float> across(small.size());
    for (int y = 0; y < qh; y++) for (int x = 0; x < qw; x++) {
        float m[4] = {1e9f, 1e9f, 1e9f, 1e9f};
        for (int d = -reach; d <= reach; d++) {
            const int sx = std::clamp(x + d, 0, qw - 1);
            const float* p = &small[(size_t(y) * qw + sx) * 4];
            for (int k = 0; k < 4; k++) m[k] = std::min(m[k], p[k]);
        }
        std::copy(m, m + 4, &across[(size_t(y) * qw + x) * 4]);
    }
    for (int y = 0; y < qh; y++) for (int x = 0; x < qw; x++) {
        float m[4] = {1e9f, 1e9f, 1e9f, 1e9f};
        for (int d = -reach; d <= reach; d++) {
            const int sy = std::clamp(y + d, 0, qh - 1);
            const float* p = &across[(size_t(sy) * qw + x) * 4];
            for (int k = 0; k < 4; k++) m[k] = std::min(m[k], p[k]);
        }
        std::copy(m, m + 4, &small[(size_t(y) * qw + x) * 4]);
    }
    small = blurred(small, qw, qh, float(reach * 1.6));
    const float a = std::max((air[0] + air[1] + air[2]) / 3.0f, 0.2f);
    const float amt = float(amount);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            float* e = &px[(size_t(y) * w + x) * 4];
            if (e[3] <= 0.0001f) continue;
            // The dark round about, laid back over the whole picture, smoothly.
            const float fx = std::clamp((x + 0.5f) / 4 - 0.5f, 0.0f, float(qw - 1)), fy = std::clamp((y + 0.5f) / 4 - 0.5f, 0.0f, float(qh - 1));
            const int x0 = int(fx), y0 = int(fy), x1 = std::min(x0 + 1, qw - 1), y1 = std::min(y0 + 1, qh - 1);
            const float tx = fx - x0, ty = fy - y0;
            auto at = [&](int xx, int yy, int k) { return small[(size_t(yy) * qw + xx) * 4 + k]; };
            float dark[2];
            for (int k = 0; k < 2; k++) {
                const int ch = k == 0 ? 0 : 3;
                dark[k] = (at(x0, y0, ch) * (1 - tx) + at(x1, y0, ch) * tx) * (1 - ty) + (at(x0, y1, ch) * (1 - tx) + at(x1, y1, ch) * tx) * ty;
            }
            float c[3];
            seen(e, c);
            const float d = std::clamp(encode(dark[1] > 0.0001f ? dark[0] / dark[1] : 0) / a, 0.0f, 1.0f);
            if (amt > 0) {
                const float t = std::max(1 - amt * 0.92f * d, 0.22f);
                for (int k = 0; k < 3; k++) c[k] = (c[k] - air[k]) / t + air[k] + (1 - t) * 0.18f * amt;
            } else {
                const float m = -amt * 0.62f * (0.3f + 0.7f * d);
                for (int k = 0; k < 3; k++) c[k] = c[k] + (air[k] - c[k]) * m;
            }
            for (int k = 0; k < 3; k++) e[k] = decode(c[k]) * e[3];
        }
    }
}

/// Each colour, as it looks, through the cube, as Core Image's colour cube in sRGB takes it:
/// unpremultiplied, the nearest eight of its steps mixed.
void cube(std::vector<float>& px, const std::vector<float>& lut, int n) {
    if (n < 2 || lut.size() < size_t(n) * n * n * 3) return;
    const float top = float(n - 1);
    for (size_t i = 0; i < px.size(); i += 4) {
        float* p = &px[i];
        const float a = p[3];
        if (a <= 0.0001f) continue;
        float c[3];
        for (int k = 0; k < 3; k++) c[k] = std::clamp(encode(p[k] / a), 0.0f, 1.0f) * top;
        const int r0 = std::min(int(c[0]), n - 2), g0 = std::min(int(c[1]), n - 2), b0 = std::min(int(c[2]), n - 2);
        const float tr = c[0] - r0, tg = c[1] - g0, tb = c[2] - b0;
        float out[3] = {0, 0, 0};
        for (int db = 0; db < 2; db++) for (int dg = 0; dg < 2; dg++) for (int dr = 0; dr < 2; dr++) {
            const float wgt = (dr ? tr : 1 - tr) * (dg ? tg : 1 - tg) * (db ? tb : 1 - tb);
            const float* e = &lut[((size_t(b0 + db) * n + (g0 + dg)) * n + (r0 + dr)) * 3];
            for (int k = 0; k < 3; k++) out[k] += e[k] * wgt;
        }
        for (int k = 0; k < 3; k++) p[k] = decode(out[k]) * a;
    }
}

/// Clarity, texture and sharpness, as the Mac's bezzleDetail kernel: the difference from a wide
/// blur in the middle tones, the band between a fine and a middling blur, and the difference
/// from the finest blur in lightness only. Each blur is taken in turn, to keep only two at once.
void detail(std::vector<float>& px, int w, int h, double clarity, double texture, double sharpness) {
    const double longest = std::max(w, h);
    const size_t count = size_t(w) * h;
    // What each pixel becomes as it looks, from how it looks to begin with.
    std::vector<float> o(count * 3), c(count * 3);
    for (size_t i = 0; i < count; i++) seen(&px[i * 4], &o[i * 3]);
    c = o;
    auto sigma = [&](double part, double least) { return float(std::max(longest * part, least)); };
    if (clarity != 0) {
        const auto wide = blurred(px, w, h, sigma(0.014, 2));
        for (size_t i = 0; i < count; i++) {
            if (px[i * 4 + 3] <= 0.0001f) continue;
            float s[3];
            seen(&wide[i * 4], s);
            const float l = std::clamp(luma(s), 0.0f, 1.0f);
            const float m = 1 - std::pow(std::fabs(2 * l - 1), 2.2f);
            for (int k = 0; k < 3; k++) c[i * 3 + k] += float(clarity) * m * (o[i * 3 + k] - s[k]);
        }
    }
    if (texture != 0) {
        const auto mid = blurred(px, w, h, sigma(0.0045, 1.5));
        const auto fine = blurred(px, w, h, sigma(0.0011, 0.6));
        for (size_t i = 0; i < count; i++) {
            if (px[i * 4 + 3] <= 0.0001f) continue;
            float f[3], md[3];
            seen(&fine[i * 4], f);
            seen(&mid[i * 4], md);
            // Not where it would push deep shadows to black or bright skies to white.
            const float m = 1 - std::pow(std::fabs(2 * std::clamp(luma(&o[i * 3]), 0.0f, 1.0f) - 1), 3.0f);
            for (int k = 0; k < 3; k++) c[i * 3 + k] += float(texture) * m * (f[k] - md[k]);
        }
    }
    if (sharpness != 0) {
        const auto tiny = blurred(px, w, h, sigma(0.00045, 0.7));
        for (size_t i = 0; i < count; i++) {
            if (px[i * 4 + 3] <= 0.0001f) continue;
            float t[3];
            seen(&tiny[i * 4], t);
            const float d = std::clamp(luma(&o[i * 3]) - luma(t), -0.25f, 0.25f);
            for (int k = 0; k < 3; k++) c[i * 3 + k] += float(sharpness) * d;
        }
    }
    for (size_t i = 0; i < count; i++) {
        float* p = &px[i * 4];
        if (p[3] <= 0.0001f) continue;
        for (int k = 0; k < 3; k++) p[k] = decode(c[i * 3 + k]) * p[3];
    }
}

}  // namespace develop

/// A photo developed as the Mac's Developer develops it, from the picture as it is.
sk_sp<SkImage> developed(const sk_sp<SkImage>& from, const Picture& d) {
    const int w = from->width(), h = from->height();
    auto px = develop::read(from, w, h);
    if (px.empty()) return from;
    if (d.dehaze != 0) {
        float air[3];
        develop::air(from, air);
        develop::dehaze(px, w, h, d.dehaze, air);
    }
    if (!d.cube.empty()) develop::cube(px, d.cube, d.cubeSize);
    if (d.clarity != 0 || d.texture != 0 || d.sharpness != 0) develop::detail(px, w, h, d.clarity, d.texture, d.sharpness);
    // Back into sRGB, eight bits a channel, as the Mac's developed pictures are.
    SkPixmap done(develop::linear(w, h), px.data(), size_t(w) * 16);
    auto image = SkImages::RasterFromPixmapCopy(done);
    if (!image) return from;
    return raster(w, h, [&](SkCanvas* canvas) {
        SkPaint paint;
        paint.setBlendMode(SkBlendMode::kSrc);
        canvas->drawImage(image, 0, 0, SkSamplingOptions(), &paint);
    });
}

sk_sp<SkImage> make(const Picture& d) {
    switch (d.kind) {
        case Picture::kAsset:
            return d.asset > 0 && size_t(d.asset) <= assets.size() ? assets[d.asset - 1].image : nullptr;
        case Picture::kRecording:
            return raster(d.width, d.height, [&](SkCanvas* canvas) {
                // Core Graphics' space: y up from the bottom left.
                canvas->concat(SkMatrix::MakeAll(1, 0, 0, 0, -1, float(d.height), 0, 0, 1));
                play(canvas, d.commands.data(), d.commands.size());
            });
        case Picture::kChanged: {
            auto from = get(d.from);
            if (!from) return nullptr;
            if (d.develops) return developed(from, d);
            const double crop[4] = {d.crop[2] > 0 ? d.crop[0] : 0, d.crop[2] > 0 ? d.crop[1] : 0, 0, 0};
            return raster(d.width, d.height, [&](SkCanvas* canvas) {
                canvas->translate(float(-crop[0]), float(-crop[1]));
                if (d.hasPerspective) {
                    const double* m = d.perspective;
                    canvas->concat(SkMatrix::MakeAll(float(m[0]), float(m[1]), float(m[2]), float(m[3]), float(m[4]),
                                                     float(m[5]), float(m[6]), float(m[7]), float(m[8])));
                }
                const SkSamplingOptions sampling(SkFilterMode::kLinear, SkMipmapMode::kNone);
                const SkTileMode tiles = d.clamp ? SkTileMode::kClamp : SkTileMode::kDecal;
                if (d.hasRamp && d.blur > 0) {
                    // A blur growing along the ramp: the picture at a few strengths, from sharp to
                    // the whole blur, each weighed by how near the ramp is to it there, and added
                    // up. The weights always come to one, so it blends from one to the next.
                    const int levels = 5;
                    const SkPoint ends[2] = {{float(d.ramp[0]), float(d.ramp[1])}, {float(d.ramp[2]), float(d.ramp[3])}};
                    for (int k = 0; k < levels; k++) {
                        const float at = float(k) / float(levels - 1), step = 1.0f / float(levels - 1);
                        std::vector<SkColor4f> colors;
                        std::vector<float> positions;
                        if (k > 0) { positions.push_back(at - step); colors.push_back({0, 0, 0, 0}); }
                        positions.push_back(at);
                        colors.push_back({0, 0, 0, 1});
                        if (k < levels - 1) { positions.push_back(at + step); colors.push_back({0, 0, 0, 0}); }
                        if (positions.size() == 1) { positions.insert(positions.begin(), 0); colors.insert(colors.begin(), {0, 0, 0, 1}); }
                        SkPaint weigh;
                        weigh.setShader(SkShaders::LinearGradient(ends, SkGradient(SkGradient::Colors(colors, positions, SkTileMode::kClamp), {})));
                        weigh.setBlendMode(SkBlendMode::kDstIn);
                        SkPaint sum;
                        sum.setBlendMode(SkBlendMode::kPlus);
                        canvas->saveLayer(nullptr, &sum);
                        SkPaint level;
                        const float sigma = float(d.blur) * at;
                        if (sigma > 0.01f) level.setImageFilter(SkImageFilters::Blur(sigma, sigma, tiles, nullptr));
                        canvas->drawImage(from, 0, 0, sampling, &level);
                        canvas->drawPaint(weigh);
                        canvas->restore();
                    }
                } else {
                    SkPaint paint;
                    if (d.blur >= 0) paint.setImageFilter(SkImageFilters::Blur(float(d.blur), float(d.blur), tiles, nullptr));
                    canvas->drawImage(from, 0, 0, sampling, &paint);
                }
            });
        }
        case Picture::kPixels: {
            if (d.pixels.empty()) return nullptr;
            return SkImages::RasterFromData(rgba(d.width, d.height), SkData::MakeWithCopy(d.pixels.data(), d.pixels.size()), size_t(d.bytesPerRow));
        }
    }
    return nullptr;
}

sk_sp<SkImage> get(int id) {
    if (auto it = made.find(id); it != made.end()) return it->second;
    auto it = pictures.find(id);
    if (it == pictures.end()) {
        if (tracing()) fprintf(stderr, "[host] no picture %d\n", id);
        return nullptr;
    }
    auto image = make(it->second);
    made[id] = image;
    return image;
}

// MARK: Text, through Skia's paragraphs (bezzle.mjs's style, paragraph, slice and textCall)

sk_sp<SkFontMgr> fontManager() {
    static sk_sp<SkFontMgr> manager = SkFontMgr_New_Custom_Empty();
    return manager;
}
sk_sp<TypefaceFontProvider> provider = sk_make_sp<TypefaceFontProvider>();
sk_sp<FontCollection> collection;
sk_sp<SkUnicode> unicode;
std::map<std::string, sk_sp<SkTypeface>> faces;   // "family|face"
std::map<std::string, double> leadings;

sk_sp<FontCollection> fonts() {
    if (!collection) {
        collection = sk_make_sp<FontCollection>();
        collection->setDefaultFontManager(provider);
        collection->enableFontFallback();
        unicode = SkUnicodes::ICU::Make();
    }
    return collection;
}

struct Run {
    std::u16string text;
    std::string family, face;
    double size, tracking, weight, opticalSize;
    bool underline, strike, hasColor;
    SkColor4f color;
    std::string features, axes;
};

/// "tag=value,tag=value" as pairs of four-letter tags and numbers.
std::vector<std::pair<std::string, double>> tagged(const std::string& list) {
    std::vector<std::pair<std::string, double>> out;
    size_t at = 0;
    while (at < list.size()) {
        size_t end = list.find(',', at);
        if (end == std::string::npos) end = list.size();
        std::string item = list.substr(at, end - at);
        size_t eq = item.find('=');
        if (eq == 4) out.push_back({item.substr(0, 4), std::atof(item.c_str() + 5)});
        at = end + 1;
    }
    return out;
}

SkFourByteTag fourBytes(const std::string& t) { return SkSetFourByteTag(t[0], t[1], t[2], t[3]); }

std::u16string utf16(const char* s) {
    std::u16string out;
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(s); *p;) {
        uint32_t c = *p++;
        int more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (more) c &= (0x3F >> more);
        for (; more > 0 && (*p & 0xC0) == 0x80; more--) c = (c << 6) | (*p++ & 0x3F);
        if (c >= 0x10000) {
            c -= 0x10000;
            out.push_back(char16_t(0xD800 + (c >> 10)));
            out.push_back(char16_t(0xDC00 + (c & 0x3FF)));
        } else {
            out.push_back(char16_t(c));
        }
    }
    return out;
}

TextStyle style(const Run& run) {
    TextStyle s;
    s.setFontSize(float(run.size));
    s.setLetterSpacing(float(run.tracking));
    s.setColor(run.hasColor ? run.color.toSkColor() : SK_ColorTRANSPARENT);
    // The font's OpenType features as the layer sets them, and its axes: the system font's weight
    // and optical size by its face and size, unless the layer sets them itself.
    const auto features = tagged(run.features);
    for (const auto& [tag, value] : features) s.addFontFeature(SkString(tag.c_str()), int(value));
    // The Mac always sets letters' spacing (Text Kit's kern), and set to nought, Core Text leaves
    // out the font's own kerning between pairs such as "Te"; set to anything else, it keeps it.
    const bool kernSet = std::any_of(features.begin(), features.end(), [](const auto& f) { return f.first == "kern"; });
    if (run.tracking == 0 && !kernSet) s.addFontFeature(SkString("kern"), 0);
    std::vector<SkFontArguments::VariationPosition::Coordinate> axes;
    const auto set = tagged(run.axes);
    auto has = [&](const char* tag) { for (const auto& a : set) if (a.first == tag) return true; return false; };
    if (run.family == "System") {
        s.setFontFamilies({SkString("System")});
        if (!has("wght")) axes.push_back({SkSetFourByteTag('w', 'g', 'h', 't'), float(run.weight > 0 ? run.weight : 400)});
        if (run.opticalSize > 0 && !has("opsz")) axes.push_back({SkSetFourByteTag('o', 'p', 's', 'z'), float(run.opticalSize)});
    } else {
        s.setFontFamilies({SkString((run.family + "|" + run.face).c_str()), SkString("System")});
    }
    for (const auto& [tag, value] : set) axes.push_back({fourBytes(tag), float(value)});
    if (!axes.empty()) {
        SkFontArguments arguments;
        arguments.setVariationDesignPosition({axes.data(), int(axes.size())});
        s.setFontArguments(arguments);
    }
    int decoration = TextDecoration::kNoDecoration;
    if (run.underline) decoration |= TextDecoration::kUnderline;
    if (run.strike) decoration |= TextDecoration::kLineThrough;
    if (decoration) {
        s.setDecoration(TextDecoration(decoration));
        s.setDecorationColor(s.getColor());
    }
    return s;
}

std::unique_ptr<Paragraph> paragraph(const std::vector<Run>& runs, const Run& first, double width, int align) {
    ParagraphStyle ps;
    const TextAlign aligns[] = {TextAlign::kLeft, TextAlign::kCenter, TextAlign::kRight, TextAlign::kJustify};
    ps.setTextAlign(aligns[std::clamp(align, 0, 3)]);
    ps.setTextStyle(style(first));
    // fonts() first: it makes `unicode` too, and arguments are evaluated in no set order.
    auto collection = fonts();
    auto builder = ParagraphBuilder::make(ps, collection, unicode);
    for (const auto& r : runs) {
        builder->pushStyle(style(r));
        builder->addText(r.text);
        builder->pop();
    }
    auto p = builder->Build();
    p->layout(float(width));
    return p;
}

/// The runs of [start, end) of the words, in UTF-16, as Skia and Text Kit both count.
std::vector<Run> slice(const std::vector<Run>& runs, size_t start, size_t end) {
    std::vector<Run> out;
    size_t at = 0;
    for (const auto& r : runs) {
        const size_t a = std::max(start, at), z = std::min(end, at + r.text.size());
        if (z > a) {
            Run part = r;
            part.text = r.text.substr(a - at, z - a);
            out.push_back(part);
        }
        at += r.text.size();
    }
    return out;
}

double leadingOf(const Run& run) {
    if (run.family == "System") return 0;
    const std::string key = run.family + "|" + run.face + "|" + std::to_string(run.size);
    if (auto it = leadings.find(key); it != leadings.end()) return it->second;
    double leading = 0;
    if (auto it = faces.find(run.family + "|" + run.face); it != faces.end()) {
        SkFont font(it->second, float(run.size));
        SkFontMetrics metrics;
        font.getMetrics(&metrics);
        leading = metrics.fLeading;
    }
    leadings[key] = leading;
    return leading;
}

struct Text {
    /// Each line on its own, where Skia puts its baseline, and how far to the left it is drawn:
    /// Skia puts half the letters' spacing before each, Core Text all of it after, which shows in
    /// lines set from the left (centred or set from the right, Skia's lines lie where the Mac's do).
    struct Line { std::unique_ptr<Paragraph> paragraph; double baseline; double back; };
    std::vector<Line> lines;
    std::vector<double> baselines;
};
std::map<int, Text> texts;
int nextText = 1;

/// A text set as one line for a curve: its letters, each drawn on its own where the core places it.
struct Glyph { SkFont font; SkGlyphID id; };
std::map<int, std::vector<Glyph>> glyphLines;

/// How many bytes UTF-8 takes for these letters, as Skia counts its clusters.
size_t utf8Length(const std::u16string& s) {
    size_t n = 0;
    for (size_t k = 0; k < s.size(); k++) {
        const char16_t c = s[k];
        if (c >= 0xD800 && c < 0xDC00 && k + 1 < s.size()) { n += 4; k++; }
        else n += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
    }
    return n;
}

// MARK: Playing a recording (bezzle.mjs's look and play)

const SkBlendMode blends[] = {
    SkBlendMode::kSrcOver, SkBlendMode::kMultiply, SkBlendMode::kScreen, SkBlendMode::kOverlay, SkBlendMode::kDarken,
    SkBlendMode::kLighten, SkBlendMode::kColorDodge, SkBlendMode::kColorBurn, SkBlendMode::kSoftLight,
    SkBlendMode::kHardLight, SkBlendMode::kDifference, SkBlendMode::kExclusion, SkBlendMode::kHue,
    SkBlendMode::kSaturation, SkBlendMode::kColor, SkBlendMode::kLuminosity, SkBlendMode::kClear, SkBlendMode::kSrc,
    SkBlendMode::kSrcIn, SkBlendMode::kSrcOut, SkBlendMode::kSrcATop, SkBlendMode::kDstOver, SkBlendMode::kDstIn,
    SkBlendMode::kDstOut, SkBlendMode::kDstATop, SkBlendMode::kXor, SkBlendMode::kMultiply, SkBlendMode::kPlus,
};

struct Look { double alpha; int blend; bool shadowed; };

/// Alpha, blend mode and shadow, as each drawing carries them: 10 numbers.
Look look(const double* c, size_t& i, SkPaint& paint, SkCanvas* canvas) {
    const double alpha = c[i], blend = c[i + 1], shadowed = c[i + 2];
    const int b = int(blend);
    paint.setBlendMode(b >= 0 && b < int(std::size(blends)) ? blends[b] : SkBlendMode::kSrcOver);
    if (shadowed != 0) {
        // Given in device pixels, as Core Graphics measures shadows: back into the canvas's own space.
        const SkMatrix m = canvas->getTotalMatrix();
        const double a = m.getScaleX(), bb = m.getSkewY(), cc = m.getSkewX(), d = m.getScaleY();
        const double det = a * d - bb * cc;
        const double dx = c[i + 3], dy = c[i + 4];
        const double lx = det != 0 ? (d * dx - cc * dy) / det : dx, ly = det != 0 ? (-bb * dx + a * dy) / det : dy;
        const double scale = std::sqrt(std::abs(det)) != 0 ? std::sqrt(std::abs(det)) : 1;
        const float sigma = float(c[i + 5] / scale);
        const SkColor4f color = {float(c[i + 6]), float(c[i + 7]), float(c[i + 8]), float(c[i + 9])};
        paint.setImageFilter(SkImageFilters::DropShadow(float(lx), float(ly), sigma, sigma, color.toSkColor(), nullptr));
    }
    i += 10;
    return {alpha, b, shadowed != 0};
}

SkPath path(const double* c, size_t& i, size_t n, double rule) {
    const size_t count = size_t(c[i]);
    const size_t start = i + 1;
    i = std::min(n, start + count);
    return readPath(c + start, i - start, fillOf(rule));
}

SkColor4f color(const double* c, size_t& i, double alpha) {
    const SkColor4f out = {float(c[i]), float(c[i + 1]), float(c[i + 2]), float(c[i + 3] * alpha)};
    i += 4;
    return out;
}

void play(SkCanvas* canvas, const double* c, size_t n) {
    size_t i = 0;
    while (i < n) {
        const int op = int(c[i++]);
        switch (op) {
            case 1: canvas->save(); break;
            case 2: canvas->restore(); break;
            case 3:
                canvas->concat(SkMatrix::MakeAll(float(c[i]), float(c[i + 2]), float(c[i + 4]), float(c[i + 1]), float(c[i + 3]),
                                                 float(c[i + 5]), 0, 0, 1));
                i += 6;
                break;
            case 4: {
                const double rule = c[i++];
                if (c[i] == 0) { canvas->clipRect(SkRect::MakeEmpty(), SkClipOp::kIntersect, false); i += 1; break; }
                canvas->clipPath(path(c, i, n, rule), SkClipOp::kIntersect, true);
                break;
            }
            case 5: case 6: {
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                if (op == 5) {
                    const double rule = c[i++];
                    paint.setColor4f(color(c, i, l.alpha));
                    canvas->drawPath(path(c, i, n, rule), paint);
                } else {
                    paint.setStyle(SkPaint::kStroke_Style);
                    paint.setStrokeWidth(float(c[i]));
                    const SkPaint::Cap caps[] = {SkPaint::kButt_Cap, SkPaint::kRound_Cap, SkPaint::kSquare_Cap};
                    const SkPaint::Join joins[] = {SkPaint::kMiter_Join, SkPaint::kRound_Join, SkPaint::kBevel_Join};
                    paint.setStrokeCap(caps[std::clamp(int(c[i + 1]), 0, 2)]);
                    paint.setStrokeJoin(joins[std::clamp(int(c[i + 2]), 0, 2)]);
                    paint.setStrokeMiter(float(c[i + 3]));
                    const double phase = c[i + 4];
                    const size_t nd = size_t(c[i + 5]);
                    i += 6;
                    if (nd > 0) {
                        std::vector<float> dashes;
                        for (size_t k = 0; k < nd; k++) dashes.push_back(float(c[i + k]));
                        if (nd % 2) for (size_t k = 0; k < nd; k++) dashes.push_back(float(c[i + k]));
                        paint.setPathEffect(SkDashPathEffect::Make(dashes, float(phase)));
                    }
                    i += nd;
                    paint.setColor4f(color(c, i, l.alpha));
                    canvas->drawPath(path(c, i, n, 0), paint);
                }
                break;
            }
            case 7: case 8: {
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                const double* g = c + i;
                i += op == 7 ? 4 : 6;
                const bool before = c[i] != 0, after = c[i + 1] != 0;
                const size_t count = size_t(c[i + 2]);
                i += 3;
                std::vector<SkColor4f> colors;
                std::vector<float> positions;
                for (size_t k = 0; k < count; k++) {
                    positions.push_back(float(c[i]));
                    colors.push_back({float(c[i + 1]), float(c[i + 2]), float(c[i + 3]), float(c[i + 4])});
                    i += 5;
                }
                const SkTileMode mode = before || after ? SkTileMode::kClamp : SkTileMode::kDecal;
                const SkGradient gradient(SkGradient::Colors(colors, positions, mode), {});
                sk_sp<SkShader> shader;
                if (op == 7) {
                    const SkPoint points[2] = {{float(g[0]), float(g[1])}, {float(g[2]), float(g[3])}};
                    shader = SkShaders::LinearGradient(points, gradient);
                } else {
                    shader = SkShaders::TwoPointConicalGradient({float(g[0]), float(g[1])}, float(g[2]),
                                                                {float(g[3]), float(g[4])}, float(g[5]), gradient);
                }
                paint.setShader(shader);
                paint.setAlphaf(float(l.alpha));
                canvas->drawPaint(paint);
                break;
            }
            case 9: {
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                const int id = int(c[i]);
                const float x = float(c[i + 1]), y = float(c[i + 2]), w = float(c[i + 3]), h = float(c[i + 4]);
                i += 6;
                if (auto image = get(id)) {
                    paint.setAlphaf(float(l.alpha));
                    // Core Graphics draws a picture with its top row at the rectangle's top, which is up.
                    canvas->save();
                    canvas->concat(SkMatrix::MakeAll(1, 0, 0, 0, -1, 2 * y + h, 0, 0, 1));
                    canvas->drawImageRect(image, SkRect::MakeWH(float(image->width()), float(image->height())), SkRect::MakeXYWH(x, y, w, h),
                                          SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear), &paint,
                                          SkCanvas::kFast_SrcRectConstraint);
                    canvas->restore();
                }
                break;
            }
            case 10: {
                SkPaint paint;
                const Look l = look(c, i, paint, canvas);
                paint.setAlphaf(float(l.alpha));
                const bool has = c[i] != 0;
                const SkRect bounds = SkRect::MakeXYWH(float(c[i + 1]), float(c[i + 2]), float(c[i + 3]), float(c[i + 4]));
                i += 5;
                canvas->saveLayer(has ? &bounds : nullptr, &paint);
                break;
            }
            case 11: canvas->restore(); break;
            case 13: {
                // One letter of a line set for a curve, its baseline's left end at the origin.
                SkPaint paint;
                paint.setAntiAlias(true);
                const Look l = look(c, i, paint, canvas);
                const int id = int(c[i]), k = int(c[i + 1]);
                i += 2;
                paint.setColor4f(color(c, i, l.alpha));
                if (auto it = glyphLines.find(id); it != glyphLines.end() && k >= 0 && k < int(it->second.size())) {
                    const Glyph& g = it->second[size_t(k)];
                    const SkPoint origin = {0, 0};
                    canvas->drawGlyphs({&g.id, 1}, {&origin, 1}, {0, 0}, g.font, paint);
                }
                break;
            }
            case 12: {
                SkPaint paint;
                const Look l = look(c, i, paint, canvas);
                const int id = int(c[i]);
                const float x = float(c[i + 1]), y = float(c[i + 2]);
                i += 3 + 5;
                const bool layered = l.alpha < 1 || l.shadowed || l.blend != 0;
                if (layered) { paint.setAlphaf(float(l.alpha)); canvas->saveLayer(nullptr, &paint); }
                if (auto it = texts.find(id); it != texts.end()) {
                    auto& t = it->second;
                    for (size_t k = 0; k < t.lines.size(); k++) {
                        auto& line = t.lines[k];
                        if (!line.paragraph) continue;
                        const double baseline = k < t.baselines.size() ? t.baselines[k] : 0;
                        line.paragraph->paint(canvas, float(x - line.back), float(y + baseline - line.baseline));
                    }
                }
                if (layered) canvas->restore();
                break;
            }
            default:
                fprintf(stderr, "[host] unknown drawing call %d at %zu\n", op, i - 1);
                return;
        }
    }
}

}  // namespace

// MARK: The C interface

extern "C" int32_t bz_host_call(int32_t function, const void* bytes, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    const auto* doubles = static_cast<const double*>(bytes);
    const size_t n = size_t(std::max(count, 0)) / sizeof(double);
    switch (function) {
        case 1: keep(pathOp(doubles, n)); break;
        case 2: keep(imageByName(doubles, n)); break;
        case 4:
            fprintf(stderr, "[core] %.*s\n", int(count), static_cast<const char*>(bytes));
            answer.clear();
            break;
        default: answer.clear();
    }
    return int32_t(answer.size());
}

extern "C" void bz_host_take(void* into) {
    std::lock_guard<std::mutex> guard(lock);
    if (into && !answer.empty()) memcpy(into, answer.data(), answer.size());
}

extern "C" int32_t bz_font_add(const char* family, const char* face, const void* data, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    auto typeface = fontManager()->makeFromData(SkData::MakeWithCopy(data, size_t(count)));
    if (!typeface) return 0;
    const std::string name = std::string(family) == "System" ? "System" : std::string(family) + "|" + face;
    provider->registerTypeface(typeface, SkString(name.c_str()));
    faces[name] = typeface;
    leadings.clear();
    if (collection) collection->clearCaches();
    return 1;
}

namespace {
std::vector<Run> runsOf(const bz_text_run* given, int32_t count) {
    std::vector<Run> runs;
    for (int32_t k = 0; k < count; k++) {
        const auto& r = given[k];
        runs.push_back({utf16(r.text ? r.text : ""), r.family ? r.family : "System", r.face ? r.face : "", r.size, r.tracking,
                        r.weight, r.opticalSize, r.underline != 0, r.strike != 0, r.hasColor != 0,
                        {float(r.color[0]), float(r.color[1]), float(r.color[2]), float(r.color[3])},
                        r.features ? r.features : "", r.axes ? r.axes : ""});
    }
    if (runs.empty()) runs.push_back({u"", "System", "", 12, 0, 400, 0, false, false, false, {0, 0, 0, 1}, "", ""});
    return runs;
}
}  // namespace

extern "C" int32_t bz_text_lay(const bz_text_run* given, int32_t count, double width, int32_t align,
                               double* lines, int32_t capacity, int32_t* lineCount) {
    std::lock_guard<std::mutex> guard(lock);
    const std::vector<Run> runs = runsOf(given, count);
    auto whole = paragraph(runs, runs[0], width, align);
    std::vector<LineMetrics> metrics;
    whole->getLineMetrics(metrics);
    Text text;
    const double leading = leadingOf(runs[0]);
    int32_t written = 0;
    for (const auto& m : metrics) {
        const size_t end = m.fEndIncludingNewline;
        auto part = slice(runs, m.fStartIndex, m.fEndExcludingWhitespaces);
        // Each line drawn on its own, so it can sit where the core puts it.
        std::unique_ptr<Paragraph> line = part.empty() ? nullptr : paragraph(part, part[0], width, align);
        double baseline = m.fBaseline;
        if (line) {
            std::vector<LineMetrics> lm;
            line->getLineMetrics(lm);
            if (!lm.empty()) baseline = lm[0].fBaseline;
        }
        const bool fromLeft = align == 0 || align == 3;
        text.lines.push_back({std::move(line), baseline, part.empty() || !fromLeft ? 0 : part[0].tracking / 2});
        text.baselines.push_back(m.fBaseline);
        if (written < capacity) {
            // Skia shares the leading out above and below the line; Text Kit keeps it apart.
            double* out = lines + written * 6;
            out[0] = double(m.fStartIndex);
            out[1] = double(end);
            out[2] = m.fWidth;
            out[3] = m.fAscent - leading / 2;
            out[4] = m.fDescent - leading / 2;
            out[5] = leading;
            written++;
        }
    }
    if (lineCount) *lineCount = int32_t(metrics.size());
    const int id = nextText++;
    texts[id] = std::move(text);
    return id;
}

extern "C" void bz_text_place(int32_t id, const double* baselines, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    if (auto it = texts.find(id); it != texts.end()) it->second.baselines.assign(baselines, baselines + std::max(count, 0));
}

extern "C" int32_t bz_text_glyphs(const bz_text_run* given, int32_t count, double* out, int32_t capacity,
                                  int32_t* glyphCount, double* line) {
    std::lock_guard<std::mutex> guard(lock);
    const std::vector<Run> runs = runsOf(given, count);
    auto p = paragraph(runs, runs[0], 1e7, 0);
    std::vector<LineMetrics> metrics;
    p->getLineMetrics(metrics);
    // Where each run begins in the words' UTF-8, which is how Skia tells where a letter is from.
    std::vector<size_t> starts;
    size_t at = 0;
    for (const auto& r : runs) { starts.push_back(at); at += utf8Length(r.text); }
    struct Laid { SkFont font; SkGlyphID id; double x, y; size_t run; };
    std::vector<Laid> laid;
    p->visit([&](int lineNumber, const Paragraph::VisitorInfo* info) {
        if (!info || lineNumber != 0) return;
        for (int k = 0; k < info->count; k++) {
            const size_t u = info->utf8Starts[k];
            size_t run = size_t(std::upper_bound(starts.begin(), starts.end(), u) - starts.begin());
            run = run > 0 ? run - 1 : 0;
            // Along the line from its start; up or down from the baseline as the letter is set.
            // Skia puts half the letters' spacing before each, Core Text all of it after.
            const double spacing = run < runs.size() ? runs[run].tracking : 0;
            laid.push_back({info->font, info->glyphs[k], double(info->origin.fX + info->positions[k].fX) - spacing / 2,
                            double(info->positions[k].fY), run});
        }
    });
    std::vector<Glyph> kept;
    // As long as Skia sets the line, but for the half of the spacing it puts before the first letter.
    double width = p->getMaxIntrinsicWidth() - runs[0].tracking / 2, capHeight = -1;
    for (size_t k = 0; k < laid.size(); k++) {
        const Laid& g = laid[k];
        SkFontMetrics m;
        g.font.getMetrics(&m);
        // As far as the next letter, or for the last, its own width and the spacing after it.
        double advance;
        if (k + 1 < laid.size() && laid[k + 1].x >= g.x) {
            advance = laid[k + 1].x - g.x;
        } else {
            SkScalar w = 0;
            g.font.getWidths({&g.id, 1}, {&w, 1});
            advance = double(w) + (g.run < runs.size() ? runs[g.run].tracking : 0);
        }
        width = std::max(width, g.x + advance);
        if (capHeight < 0) capHeight = m.fCapHeight;
        kept.push_back({g.font, g.id});
        if (int32_t(k) < capacity) {
            double* o = out + k * 10;
            SkScalar underline = 0, thickness = 0;
            if (!m.hasUnderlinePosition(&underline)) underline = -m.fAscent * 0.1f;
            if (!m.hasUnderlineThickness(&thickness)) thickness = g.font.getSize() / 14;
            o[0] = double(g.run);
            o[1] = g.x;
            o[2] = g.y;
            o[3] = advance;
            o[4] = -m.fAscent;
            o[5] = m.fDescent;
            o[6] = underline;
            o[7] = thickness;
            o[8] = m.fXHeight;
            o[9] = m.fCapHeight;
        }
    }
    if (glyphCount) *glyphCount = int32_t(laid.size());
    const double ascent = metrics.empty() ? runs[0].size * 0.8 : metrics[0].fAscent;
    const double descent = metrics.empty() ? runs[0].size * 0.2 : metrics[0].fDescent;
    if (line) {
        line[0] = width;
        line[1] = ascent;
        line[2] = descent;
        line[3] = capHeight >= 0 ? capHeight : ascent * 0.7;
    }
    const int id = nextText++;
    glyphLines[id] = std::move(kept);
    return id;
}

extern "C" void bz_text_forget(void) {
    std::lock_guard<std::mutex> guard(lock);
    texts.clear();
    glyphLines.clear();
}

extern "C" int32_t bz_asset_add(const char* name, const void* data, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    auto image = decode(data, size_t(count));
    if (!image) return 0;
    assets.push_back({image});
    const int number = int(assets.size());
    assetsByName[name] = number;
    return number;
}

extern "C" void bz_picture_asset(int32_t id, int32_t asset) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kAsset;
    p.asset = asset;
    pictures[id] = std::move(p);
}

extern "C" void bz_picture_recording(int32_t id, int32_t width, int32_t height, const double* commands, int64_t count) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kRecording;
    p.width = width;
    p.height = height;
    p.commands.assign(commands, commands + std::max<int64_t>(count, 0));
    pictures[id] = std::move(p);
}

extern "C" void bz_picture_changed(int32_t id, int32_t width, int32_t height, int32_t from, const double* crop, double blur,
                                   int32_t clamp, const double* perspective) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kChanged;
    p.width = width;
    p.height = height;
    p.from = from;
    if (crop) std::copy(crop, crop + 4, p.crop);
    p.blur = blur;
    p.clamp = clamp != 0;
    if (perspective) { p.hasPerspective = true; std::copy(perspective, perspective + 9, p.perspective); }
    pictures[id] = std::move(p);
}

extern "C" void bz_picture_develop(int32_t id, const float* cube, int32_t size, const double* amounts) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pictures.find(id);
    if (it == pictures.end()) return;
    Picture& p = it->second;
    p.develops = true;
    p.cubeSize = std::max(size, 0);
    if (cube && size > 1) p.cube.assign(cube, cube + size_t(size) * size * size * 3);
    if (amounts) { p.dehaze = amounts[0]; p.clarity = amounts[1]; p.texture = amounts[2]; p.sharpness = amounts[3]; }
}

extern "C" void bz_picture_ramp(int32_t id, const double* ends) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pictures.find(id);
    if (it == pictures.end() || !ends) return;
    it->second.hasRamp = true;
    std::copy(ends, ends + 4, it->second.ramp);
}

extern "C" void bz_picture_pixels(int32_t id, int32_t width, int32_t height, int32_t bytesPerRow, const uint8_t* bytes) {
    std::lock_guard<std::mutex> guard(lock);
    Picture p;
    p.kind = Picture::kPixels;
    p.width = width;
    p.height = height;
    p.bytesPerRow = bytesPerRow;
    p.pixels.assign(bytes, bytes + size_t(bytesPerRow) * size_t(std::max(height, 0)));
    pictures[id] = std::move(p);
}

extern "C" int32_t bz_picture_read(int32_t id, int32_t width, int32_t height, int32_t bgra, void* pixels) {
    std::lock_guard<std::mutex> guard(lock);
    auto image = get(id);
    if (!image) return 1;
    const SkImageInfo info = SkImageInfo::Make(std::max(1, width), std::max(1, height), bgra ? kBGRA_8888_SkColorType : kRGBA_8888_SkColorType,
                                               kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    return image->readPixels(nullptr, SkPixmap(info, pixels, size_t(width) * 4), 0, 0) ? 0 : 2;
}

extern "C" void bz_picture_forget(int32_t id) {
    std::lock_guard<std::mutex> guard(lock);
    pictures.erase(id);
    made.erase(id);
}

extern "C" int32_t bz_png_write(const char* path, int32_t width, int32_t height, const void* pixels) {
    SkFILEWStream file(path);
    if (!file.isValid()) return 1;
    const SkPixmap pixmap(rgba(width, height), pixels, size_t(width) * 4);
    return SkPngEncoder::Encode(&file, pixmap, {}) ? 0 : 2;
}

extern "C" int32_t bz_image_write(const char* path, int32_t width, int32_t height, const void* pixels, int32_t format, double quality) {
    SkFILEWStream file(path);
    if (!file.isValid()) return 1;
    const SkPixmap pixmap(rgba(width, height), pixels, size_t(width) * 4);
    switch (format) {
        case 1: {
            SkJpegEncoder::Options options;
            options.fQuality = std::clamp(int(quality * 100 + 0.5), 0, 100);
            return SkJpegEncoder::Encode(&file, pixmap, options) ? 0 : 2;
        }
        case 2: {
            // At the very top, lossless, as the Mac's WebP writer makes it.
            SkWebpEncoder::Options options;
            options.fCompression = quality >= 1 ? SkWebpEncoder::Compression::kLossless : SkWebpEncoder::Compression::kLossy;
            options.fQuality = float(quality >= 1 ? 75 : std::clamp(quality * 100, 0.0, 100.0));
            return SkWebpEncoder::Encode(&file, pixmap, options) ? 0 : 2;
        }
        default:
            return SkPngEncoder::Encode(&file, pixmap, {}) ? 0 : 2;
    }
}

/// A PDF being written: its file, and the document drawing into it.
struct PDF {
    std::unique_ptr<SkFILEWStream> file;
    sk_sp<SkDocument> document;
};
std::map<int, PDF> pdfs;
int nextPDF = 1;

extern "C" int32_t bz_pdf_begin(const char* path) {
    std::lock_guard<std::mutex> guard(lock);
    PDF pdf;
    pdf.file = std::make_unique<SkFILEWStream>(path);
    if (!pdf.file->isValid()) return 0;
    // Pictures in it kept as JPEG where they came as JPEG, as Skia asks a PDF to be given.
    SkPDF::Metadata metadata = SkPDF::JPEG::MetadataWithCallbacks();
    metadata.fCreator = "Bezzle";
    metadata.fProducer = "Bezzle";
    pdf.document = SkPDF::MakeDocument(pdf.file.get(), metadata);
    if (!pdf.document) return 0;
    const int id = nextPDF++;
    pdfs[id] = std::move(pdf);
    return id;
}

extern "C" int32_t bz_pdf_page(int32_t pdf, int32_t picture, double width, double height, double scale) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pdfs.find(pdf);
    auto p = pictures.find(picture);
    if (it == pdfs.end() || p == pictures.end() || p->second.kind != Picture::kRecording) return 1;
    SkCanvas* canvas = it->second.document->beginPage(float(width), float(height));
    if (!canvas) return 2;
    // The recording, at `scale` pixels a point, played as shapes and text rather than pixels.
    canvas->scale(float(1 / scale), float(1 / scale));
    canvas->concat(SkMatrix::MakeAll(1, 0, 0, 0, -1, float(p->second.height), 0, 0, 1));
    play(canvas, p->second.commands.data(), p->second.commands.size());
    it->second.document->endPage();
    return 0;
}

extern "C" int32_t bz_pdf_end(int32_t pdf) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = pdfs.find(pdf);
    if (it == pdfs.end()) return 1;
    it->second.document->close();
    it->second.file->flush();
    pdfs.erase(it);
    return 0;
}

extern "C" int32_t bz_shadow(int32_t width, int32_t height, int32_t pad, double blur, double dy, uint32_t rgb, double alpha, void* pixels) {
    const int w = std::max(1, width + 2 * pad), h = std::max(1, height + 2 * pad);
    const SkImageInfo info = SkImageInfo::Make(w, h, kBGRA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::WrapPixels(info, pixels, size_t(w) * 4);
    if (!surface) return 1;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f({float((rgb >> 16 & 0xFF) / 255.0), float((rgb >> 8 & 0xFF) / 255.0), float((rgb & 0xFF) / 255.0), float(alpha)});
    if (blur > 0) paint.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, float(blur / 2)));
    canvas->drawRect(SkRect::MakeXYWH(float(pad), float(pad + dy), float(width), float(height)), paint);
    return 0;
}

extern "C" int32_t bz_stage(int32_t width, int32_t height, double scale, uint32_t table, uint32_t light, double strength,
                            double x, double y, double reach, double shade, void* pixels) {
    const int w = std::max(1, width), h = std::max(1, height);
    const SkImageInfo info = SkImageInfo::Make(w, h, kBGRA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    auto surface = SkSurfaces::WrapPixels(info, pixels, size_t(w) * 4);
    if (!surface) return 1;
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(SK_ColorTRANSPARENT);
    auto c = [](uint32_t rgb, double a) { return SkColor4f{float((rgb >> 16 & 0xFF) / 255.0), float((rgb >> 8 & 0xFF) / 255.0), float((rgb & 0xFF) / 255.0), float(a)}; };
    const SkRRect shape = SkRRect::MakeRectXY(SkRect::MakeWH(float(w), float(h)), float(20 * scale), float(20 * scale));
    canvas->clipRRect(shape, true);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor4f(c(table, 1));
    canvas->drawPaint(paint);
    // The pool: an elliptical gradient, as SwiftUI's EllipticalGradient fills the table's frame.
    const SkColor4f pool[2] = {c(light, strength), c(light, 0)};
    const SkGradient lit(SkGradient::Colors(pool, SkTileMode::kClamp), {});
    SkMatrix stretch = SkMatrix::Scale(float(w * reach), float(h * reach));
    stretch.postTranslate(float(w * x), float(h * y));
    SkPaint glow;
    glow.setShader(SkShaders::RadialGradient({0, 0}, 1, lit, &stretch));
    canvas->drawPaint(glow);
    // The far edge falling into shade.
    const SkColor4f fall[2] = {c(0, 0), c(0, shade)};
    const SkPoint ends[2] = {{0, float(h / 2.0)}, {0, float(h)}};
    SkPaint dim;
    dim.setShader(SkShaders::LinearGradient(ends, SkGradient(SkGradient::Colors(fall, SkTileMode::kClamp), {})));
    canvas->drawPaint(dim);
    return 0;
}
