// HDR pictures (PQ and HLG) brought down to what Bezzle's drawing holds, as the Mac brings them:
// Image I/O hands Bezzle such a picture as it is kept, and Core Graphics tone maps it when it is
// drawn into Bezzle's 8-bit sRGB bitmap, with ColorSync's reference white tone mapping (read out
// and measured on macOS 27.2: within one level of the Mac on every picture tried, 71 to 100 dB),
// or, where the picture says it is no brighter than reference white, with the ITU method. Core
// Image, which develops photos, takes them in with the ITU method alone. Without Skia, so the same
// code can be tried on any machine; host.cpp makes Skia's pictures of what this gives.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

namespace hdr {

/// The transfers of ITU-T H.273 that are HDR: PQ (SMPTE ST 2084) and HLG (ARIB STD-B67).
enum { pq = 16, hlg = 18 };
/// The primaries of ITU-T H.273 known here: BT.709 (sRGB's), BT.2020, Display P3.
enum { bt709 = 1, bt2020 = 9, p3 = 12 };

inline bool isHDR(int transfer) { return transfer == pq || transfer == hlg; }

/// How much brighter than reference white (203 nits) the picture goes, as Image I/O gives it
/// (CGImageGetContentHeadroom): its content light level when it says one (clli's MaxCLL), else its
/// mastering display's peak (mdcv), else 1000 nits; never below 1. The same for PQ and HLG.
inline double headroom(double maxCLL, double mastering) {
    const double h = maxCLL > 0 ? maxCLL / 203.0 : mastering > 0 ? mastering / 203.0 : 1000.0 / 203.0;
    return h > 1 ? h : 1.0;
}

// Linear light from each primaries' to BT.2020's, where the tone mapping is done, and from
// BT.2020's to sRGB's (ColorSync's own, as CGColorConversionInfoShowSteps prints them); row by row.
const double p3To2020[9] = {0.7538269162, 0.1986033320, 0.0475698039, 0.0457511619, 0.9417546988, 0.0124941459, -0.0012095238, 0.0176098906, 0.9835996032};
const double bt709To2020[9] = {0.6274039, 0.3292830, 0.0433131, 0.0690973, 0.9195404, 0.0113623, 0.0163914, 0.0880133, 0.8955953};
const double bt2020ToSRGB[9] = {1.6605981588, -0.5877246261, -0.0728735998, -0.1246126369, 1.1329555511, -0.0083428752, -0.0181352198, -0.1005659476, 1.1187012196};
// The inverse of p3To2020.
const double bt2020ToP3[9] = {1.3435930525, -0.2821975706, -0.0613955518, -0.0653102081, 1.0758171446, -0.0105069406, 0.0028214869, -0.0196079246, 1.0167864682};

inline void mul(const double* m, double* v) {
    const double r = v[0], g = v[1], b = v[2];
    v[0] = m[0] * r + m[1] * g + m[2] * b;
    v[1] = m[3] * r + m[4] * g + m[5] * b;
    v[2] = m[6] * r + m[7] * g + m[8] * b;
}

/// PQ's signal to light, 1 for 10,000 nits.
inline double pqLight(double e) {
    if (e <= 0) return 0;
    if (e > 1) e = 1;
    const double p = std::pow(e, 1 / 78.84375), n = p - 0.8359375;
    return n <= 0 ? 0 : std::pow(n / (18.8515625 - 18.6875 * p), 1 / 0.1593017578125);
}
/// Light in nits to PQ's signal.
inline double pqSignal(double nits) {
    const double y = std::clamp(nits / 10000, 0.0, 1.0);
    const double p = std::pow(y, 0.1593017578125);
    return std::pow((0.8359375 + 18.8515625 * p) / (1 + 18.6875 * p), 78.84375);
}
/// HLG's signal to the light of the scene, 0…1.
inline double hlgScene(double e) {
    if (e <= 0) return 0;
    if (e > 1) e = 1;
    return e <= 0.5 ? e * e / 3 : (std::exp((e - 0.55991073) / 0.17883277) + 0.28466892) / 12;
}
inline double srgbEncode(double l) {
    if (!(l > 0)) return 0;
    if (l >= 1) return 1;
    return l < 0.0031308 ? 12.92 * l : 1.055 * std::pow(l, 1 / 2.4) - 0.055;
}

/// ColorSync's reference white tone curve (CMMConvRWToneMapping::ReferenceWhiteToneMap) for a
/// picture of headroom H drawn where white is the brightest there is: light relative to reference
/// white, up to H, to 0…1. Reference white comes out lower the more headroom there is (0.5 at the
/// default 4.93), straight below it, then a quadratic Bézier shoulder to H, under a gamma.
struct Curve {
    double H = 1, gamma = 1, k = 1, X1 = 1, Y1 = 1, A = 0, B = 0;
    explicit Curve(double headroom) : H(headroom) {
        const double s = std::clamp(std::log2(H) / 3, 0.0, 1.0);
        const double e = 1 - 0.65 * s;
        gamma = 1 - 0.1 * s;
        k = std::pow(e, 1 / gamma);
        Y1 = 1 - 0.35 * (1 - k);
        X1 = Y1 / k;
        A = 1 - 2 * X1 + H;
        B = X1 - 1;
    }
    double operator()(double m) const {
        double z;
        if (m <= 1) {
            z = k * m;
        } else if (m >= H) {
            z = 1;
        } else {
            // x(t) = 1 + 2 B t + A t² inverted, then y(t) on the Bézier.
            const double t = std::fabs(A) > 1e-9 ? (-B + std::sqrt(B * B + A * (m - 1))) / A : (m - 1) / (2 * B);
            const double u = 1 - t;
            z = k * u * u + 2 * Y1 * t * u + t * t;
        }
        return std::pow(z, gamma);
    }
};

/// The BT.2390 EETF from 1,000 nits to 203 in PQ's signal, as a gain on light of luminance `y`
/// nits (vImage's PQ tone map, the ITU method): not held at 1,000 nits beyond it.
inline double ituGain(double y) {
    if (y <= 0) return 1;
    static const double top = pqSignal(1000), white = pqSignal(203) / top, knee = 1.5 * white - 0.5;
    const double e1 = pqSignal(y) / top;
    double e2 = e1;
    if (e1 >= knee) {
        const double t = (e1 - knee) / (1 - knee), t2 = t * t, t3 = t2 * t;
        e2 = (2 * t3 - 3 * t2 + 1) * knee + (t3 - 2 * t2 + t) * (1 - knee) + (-2 * t3 + 3 * t2) * white;
    }
    return pqLight(e2 * top) * 10000 / y;
}

/// What a picture's light is in BT.2020's primaries, for its own.
inline const double* to2020(int primaries) { return primaries == p3 ? p3To2020 : primaries == bt709 ? bt709To2020 : nullptr; }
/// Its luma weights, by its primaries, as ColorSync takes them for HLG's OOTF.
inline void lumaWeights(int primaries, double w[3]) {
    if (primaries == p3) { w[0] = 0.2290000021; w[1] = 0.6916999817; w[2] = 0.0793000013; }
    else if (primaries == bt709) { w[0] = 0.2126; w[1] = 0.7152; w[2] = 0.0722; }
    else { w[0] = 0.2626999915; w[1] = 0.6779999733; w[2] = 0.0593000017; }
}

/// One pixel's signal (0…1 each) to linear sRGB, 0…1, as Core Graphics draws it into an sRGB bitmap.
inline void drawn(const Curve& c, int transfer, int primaries, const double sig[3], double out[3]) {
    double v[3], w[3];
    lumaWeights(primaries, w);
    const double* into = to2020(primaries);
    if (c.H <= 1) {
        // No headroom to bring down: the ITU method.
        if (transfer == hlg) {
            // The BT.2100 OOTF for a display of 203 nits, its system gamma 1.2 × 1.111^log2(0.203),
            // over the mean of luma and the brightest channel.
            for (int i = 0; i < 3; i++) v[i] = hlgScene(sig[i]);
            const double most = std::max({v[0], v[1], v[2]});
            const double ys = 0.5 * most + 0.5 * (w[0] * v[0] + w[1] * v[1] + w[2] * v[2]);
            const double g = ys > 0 ? std::pow(ys, -0.058070302) : 0;
            for (int i = 0; i < 3; i++) v[i] *= g;
            if (into) mul(into, v);
        } else {
            for (int i = 0; i < 3; i++) v[i] = pqLight(sig[i]) * 10000;
            if (into) mul(into, v);
            const double g = ituGain(0.2627 * v[0] + 0.6780 * v[1] + 0.0593 * v[2]) / 203;
            for (int i = 0; i < 3; i++) v[i] *= g;
        }
    } else {
        double scale;
        if (transfer == hlg) {
            // The BT.2100 OOTF for 1,000 nits: system gamma 1.2.
            for (int i = 0; i < 3; i++) v[i] = hlgScene(sig[i]);
            const double ys = w[0] * v[0] + w[1] * v[1] + w[2] * v[2];
            const double g = ys > 0 ? std::pow(ys, 0.2) : 0;
            for (int i = 0; i < 3; i++) v[i] *= g;
            scale = 1000.0 / 203.0;
        } else {
            for (int i = 0; i < 3; i++) v[i] = pqLight(sig[i]);
            scale = 10000.0 / 203.0;
        }
        if (into) mul(into, v);
        for (int i = 0; i < 3; i++) v[i] *= scale;
        // On the brightest channel, the others kept in proportion: hues stay as they are.
        const double m = std::max({v[0], v[1], v[2], 0.001});
        const double gain = c(m) / m;
        for (int i = 0; i < 3; i++) v[i] *= gain;
    }
    mul(bt2020ToSRGB, v);
    for (int i = 0; i < 3; i++) out[i] = std::clamp(v[i], 0.0, 1.0);
}

/// One pixel's signal to light as Core Image takes it in to develop it (the ITU method), 1 for
/// reference white, nothing held to 0…1, in BT.2020's primaries (or Display P3's for a P3 picture,
/// which the Mac develops in Display P3).
inline void developed(int transfer, int primaries, const double sig[3], double out[3]) {
    double v[3], w[3];
    lumaWeights(primaries, w);
    const double* into = to2020(primaries);
    if (transfer == hlg) {
        for (int i = 0; i < 3; i++) v[i] = hlgScene(sig[i]);
        const double most = std::max({v[0], v[1], v[2]});
        const double ys = 0.5 * most + 0.5 * (w[0] * v[0] + w[1] * v[1] + w[2] * v[2]);
        const double g = ys > 0 ? std::pow(ys, -0.058070302) : 0;
        for (int i = 0; i < 3; i++) v[i] *= g;
        if (into) mul(into, v);
    } else {
        for (int i = 0; i < 3; i++) v[i] = pqLight(sig[i]) * 10000;
        if (into) mul(into, v);
        const double g = ituGain(0.2627 * v[0] + 0.6780 * v[1] + 0.0593 * v[2]) / 203;
        for (int i = 0; i < 3; i++) v[i] *= g;
    }
    if (primaries == p3) mul(bt2020ToP3, v);
    for (int i = 0; i < 3; i++) out[i] = v[i];
}

/// Work over the rows of a picture, split across the processor's cores.
template <typename Rows> void inRows(int h, Rows rows) {
    const int n = std::max(1, std::min<int>(int(std::thread::hardware_concurrency()), 16));
    if (n == 1 || h < 64) { rows(0, h); return; }
    std::vector<std::thread> threads;
    for (int k = 0; k < n; k++) threads.emplace_back([&, k] { rows(h * k / n, h * (k + 1) / n); });
    for (auto& t : threads) t.join();
}

/// A picture's pixels, premultiplied RGBA of 8 or 16 bits as libavif gives them, rows top first,
/// each through `pixel` (signal 0…1 in, three values out), with its alpha.
template <typename Pixel> void eachPixel(const uint8_t* pixels, bool sixteen, int w, int h, Pixel pixel) {
    inRows(h, [&](int from, int to) {
        for (int y = from; y < to; y++) {
            for (int x = 0; x < w; x++) {
                const size_t i = size_t(y) * w + x;
                double c[4];
                if (sixteen) {
                    uint16_t s[4];
                    std::memcpy(s, pixels + i * 8, 8);
                    for (int k = 0; k < 4; k++) c[k] = s[k] / 65535.0;
                } else {
                    for (int k = 0; k < 4; k++) c[k] = pixels[i * 4 + k] / 255.0;
                }
                const double a = c[3];
                double sig[3];
                for (int k = 0; k < 3; k++) sig[k] = a > 0 ? std::min(c[k] / a, 1.0) : 0;
                pixel(i, sig, a);
            }
        }
    });
}

/// The reference white tone mapping of `drawn`, worked out once for every signal level and
/// looked up, for whole pictures: each channel's light by its code, the curve's gain by the
/// brightest channel's light (in steps of 1/1024 of a stop), the sRGB curve in 65,536 steps.
struct Fast {
    std::vector<double> light;
    std::vector<double> gain;
    std::vector<double> encode;
    double lowest = std::log2(0.001), step = 1.0 / 1024, highest = 0;
    int transfer, primaries;
    double scale, w[3];
    const double* into;
    Fast(const Curve& c, int transfer, int primaries, int codes) : transfer(transfer), primaries(primaries) {
        lumaWeights(primaries, w);
        into = to2020(primaries);
        scale = transfer == hlg ? 1000.0 / 203.0 : 10000.0 / 203.0;
        light.resize(size_t(codes));
        for (int k = 0; k < codes; k++) light[size_t(k)] = transfer == hlg ? hlgScene(k / double(codes - 1)) : pqLight(k / double(codes - 1));
        const int n = int(std::ceil((std::log2(std::max(c.H, 1.0)) - lowest) / step)) + 2;
        gain.resize(size_t(n));
        for (int k = 0; k < n; k++) {
            const double m = std::exp2(lowest + k * step);
            gain[size_t(k)] = c(m) / m;
        }
        highest = std::exp2(lowest + (n - 1) * step);
        encode.resize(65537);
        for (int k = 0; k <= 65536; k++) encode[size_t(k)] = srgbEncode(k / 65536.0);
    }
    double gainAt(double m) const {
        if (m >= highest) return 1 / m;
        const double f = (std::log2(m) - lowest) / step;
        const size_t i = size_t(f);
        const double t = f - double(i);
        return gain[i] * (1 - t) + gain[i + 1] * t;
    }
    double encoded(double l) const {
        if (!(l > 0)) return 0;
        if (l >= 1) return 1;
        const double f = l * 65536;
        const size_t i = size_t(f);
        const double t = f - double(i);
        return encode[i] * (1 - t) + encode[i + 1] * t;
    }
    /// One pixel, by its channels' codes, to 8-bit sRGB.
    void pixel(const int code[3], uint8_t out[3]) const {
        double v[3] = {light[size_t(code[0])], light[size_t(code[1])], light[size_t(code[2])]};
        if (transfer == hlg) {
            const double ys = w[0] * v[0] + w[1] * v[1] + w[2] * v[2];
            const double g = ys > 0 ? std::pow(ys, 0.2) : 0;
            for (int i = 0; i < 3; i++) v[i] *= g;
        }
        if (into) mul(into, v);
        for (int i = 0; i < 3; i++) v[i] *= scale;
        const double m = std::max({v[0], v[1], v[2], 0.001});
        const double g = gainAt(m);
        for (int i = 0; i < 3; i++) v[i] *= g;
        mul(bt2020ToSRGB, v);
        for (int i = 0; i < 3; i++) out[i] = uint8_t(std::lround(encoded(v[i]) * 255));
    }
};

/// The picture as it lands in Bezzle's 8-bit sRGB bitmap: premultiplied sRGB RGBA, 8 bits.
inline std::vector<uint8_t> toSRGB(const uint8_t* pixels, bool sixteen, int w, int h, int transfer, int primaries, double H) {
    std::vector<uint8_t> out(size_t(w) * h * 4);
    const Curve curve(H);
    if (H > 1) {
        // Solid pixels by their codes, looked up; see-through ones worked out.
        const Fast fast(curve, transfer, primaries, sixteen ? 65536 : 256);
        inRows(h, [&](int from, int to) {
            for (int y = from; y < to; y++) {
                for (int x = 0; x < w; x++) {
                    const size_t i = size_t(y) * w + x;
                    int code[4];
                    if (sixteen) {
                        uint16_t s[4];
                        std::memcpy(s, pixels + i * 8, 8);
                        for (int k = 0; k < 4; k++) code[k] = s[k];
                    } else {
                        for (int k = 0; k < 4; k++) code[k] = pixels[i * 4 + k];
                    }
                    if (code[3] != (sixteen ? 65535 : 255)) {
                        const double a = code[3] / (sixteen ? 65535.0 : 255.0);
                        double sig[3], l[3];
                        for (int k = 0; k < 3; k++) sig[k] = a > 0 ? std::min(code[k] / (sixteen ? 65535.0 : 255.0) / a, 1.0) : 0;
                        drawn(curve, transfer, primaries, sig, l);
                        for (int k = 0; k < 3; k++) out[i * 4 + k] = uint8_t(std::lround(srgbEncode(l[k]) * a * 255));
                        out[i * 4 + 3] = uint8_t(std::lround(a * 255));
                        continue;
                    }
                    fast.pixel(code, &out[i * 4]);
                    out[i * 4 + 3] = 255;
                }
            }
        });
        return out;
    }
    eachPixel(pixels, sixteen, w, h, [&](size_t i, const double sig[3], double a) {
        double l[3];
        drawn(curve, transfer, primaries, sig, l);
        for (int k = 0; k < 3; k++) out[i * 4 + k] = uint8_t(std::lround(srgbEncode(l[k]) * a * 255));
        out[i * 4 + 3] = uint8_t(std::lround(a * 255));
    });
    return out;
}

/// The picture as Core Image takes it to develop: premultiplied linear light, four floats a pixel.
inline std::vector<float> toDevelop(const uint8_t* pixels, bool sixteen, int w, int h, int transfer, int primaries) {
    std::vector<float> out(size_t(w) * h * 4);
    eachPixel(pixels, sixteen, w, h, [&](size_t i, const double sig[3], double a) {
        double l[3];
        developed(transfer, primaries, sig, l);
        for (int k = 0; k < 3; k++) out[i * 4 + k] = float(l[k] * a);
        out[i * 4 + 3] = float(a);
    });
    return out;
}

}  // namespace hdr
