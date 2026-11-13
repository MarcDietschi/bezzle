// A film saved as a movie on Windows (Host/FilmMovie.swift), as the Mac's FilmExport writes one
// with AVFoundation: H.264 in an MPEG-4 file, High profile, a whole picture every second, what
// says how it is read before the pictures (put there once it is whole) so it plays from a website
// before all of it has come,
// and its colours said to be what they are, sRGB: BT.709 primaries and matrix, sRGB's curve.
//
// Media Foundation's sink writer packs it, with Windows' own H.264 encoder. The frames come as the
// film's BGRA pixels and are turned into NV12 here, with BT.709's matrix in studio range, as the
// file says: the encoder takes NV12, and doing it here leaves nothing to a converter's own choice.
#include "BezzleHost.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <codecapi.h>

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

struct bz_movie {
    IMFSinkWriter* writer = nullptr;
    DWORD stream = 0;
    int width = 0, height = 0, fps = 60;
    bool started = false;
    std::vector<uint8_t> nv12;
};

namespace {

std::wstring wide(const char* utf8) {
    if (!utf8) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring out(size_t(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), n);
    out.resize(size_t(n - 1));
    return out;
}

template <typename T> void release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

/// 100-nanosecond units at frame `index`, rounded, so the frames never drift from their moments.
LONGLONG at(int64_t index, int fps) { return (LONGLONG(index) * 10000000LL + fps / 2) / fps; }

/// Premultiplied BGRA (solid) into NV12: BT.709, studio range (16 to 235, 16 to 240).
void toNV12(const uint8_t* bgra, int w, int h, uint8_t* out) {
    uint8_t* Y = out;
    uint8_t* UV = out + size_t(w) * h;
    for (int y = 0; y < h; y++) {
        const uint8_t* row = bgra + size_t(y) * w * 4;
        uint8_t* line = Y + size_t(y) * w;
        for (int x = 0; x < w; x++) {
            const double b = row[4 * x] / 255.0, g = row[4 * x + 1] / 255.0, r = row[4 * x + 2] / 255.0;
            const double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            line[x] = uint8_t(std::lround(16 + 219 * luma));
        }
    }
    for (int y = 0; y < h / 2; y++) {
        uint8_t* line = UV + size_t(y) * w;
        for (int x = 0; x < w / 2; x++) {
            double r = 0, g = 0, b = 0;
            for (int dy = 0; dy < 2; dy++) {
                const uint8_t* p = bgra + (size_t(2 * y + dy) * w + 2 * x) * 4;
                for (int dx = 0; dx < 2; dx++) {
                    b += p[4 * dx]; g += p[4 * dx + 1]; r += p[4 * dx + 2];
                }
            }
            r /= 4 * 255.0; g /= 4 * 255.0; b /= 4 * 255.0;
            const double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            const double cb = (b - luma) / 1.8556, cr = (r - luma) / 1.5748;
            line[2 * x] = uint8_t(std::lround(std::min(240.0, std::max(16.0, 128 + 224 * cb))));
            line[2 * x + 1] = uint8_t(std::lround(std::min(240.0, std::max(16.0, 128 + 224 * cr))));
        }
    }
}

bool startedUp = false;

/// How many steps of the last movie's work went well before one did not: for saying where.
int lastStep = 0;

}  // namespace

/// One step of the work, taken only while those before it went well, and counted.
#define STEP(x) do { if (SUCCEEDED(hr)) { hr = (x); if (SUCCEEDED(hr)) lastStep++; } } while (0)

extern "C" int32_t bz_movie_failed_step(void) { return lastStep; }

extern "C" bz_movie* bz_movie_open(const char* path, int32_t width, int32_t height, int32_t fps, int64_t bitrate, int32_t* error) {
    auto fail = [&](HRESULT hr) -> bz_movie* {
        if (error) *error = int32_t(hr);
        return nullptr;
    };
    if (width < 2 || height < 2 || width % 2 || height % 2 || fps < 1) return fail(E_INVALIDARG);
    // The window's thread is COM's already; any other is made one, as Media Foundation asks.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com) && com != RPC_E_CHANGED_MODE) return fail(com);
    if (!startedUp) {
        const HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        if (FAILED(hr)) return fail(hr);
        startedUp = true;
    }
    auto movie = new bz_movie();
    movie->width = width;
    movie->height = height;
    movie->fps = fps;
    IMFAttributes* attributes = nullptr;
    IMFMediaType* out = nullptr;
    IMFMediaType* in = nullptr;
    lastStep = 0;
    HRESULT hr = MFCreateAttributes(&attributes, 4);
    STEP(attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4));
    STEP(attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE));
    // What says how the movie is read is put first afterwards (FilmMovie.swift's fastStart):
    // Media Foundation's own way of doing so, MF_MPEG4SINK_MOOV_BEFORE_MDAT, is refused writing
    // to a file by its name, and given a stream of its own leaves the pictures' places wrong.
    const std::wstring file = wide(path);
    STEP(MFCreateSinkWriterFromURL(file.c_str(), nullptr, attributes, &movie->writer));

    STEP(MFCreateMediaType(&out));
    STEP(out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    STEP(out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264));
    STEP(out->SetUINT32(MF_MT_AVG_BITRATE, UINT32(std::min<int64_t>(std::max<int64_t>(bitrate, 100000), 0xFFFFFFFF))));
    STEP(out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    STEP(MFSetAttributeSize(out, MF_MT_FRAME_SIZE, UINT32(width), UINT32(height)));
    STEP(MFSetAttributeRatio(out, MF_MT_FRAME_RATE, UINT32(fps), 1));
    STEP(MFSetAttributeRatio(out, MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
    STEP(out->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High));
    // A whole picture every second, so the movie can be dragged through.
    STEP(out->SetUINT32(MF_MT_MAX_KEYFRAME_SPACING, UINT32(fps)));
    STEP(out->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709));
    STEP(out->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB));
    STEP(out->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709));
    STEP(out->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235));
    STEP(movie->writer->AddStream(out, &movie->stream));

    STEP(MFCreateMediaType(&in));
    STEP(in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    STEP(in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12));
    STEP(in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    STEP(MFSetAttributeSize(in, MF_MT_FRAME_SIZE, UINT32(width), UINT32(height)));
    STEP(MFSetAttributeRatio(in, MF_MT_FRAME_RATE, UINT32(fps), 1));
    STEP(MFSetAttributeRatio(in, MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
    STEP(in->SetUINT32(MF_MT_DEFAULT_STRIDE, UINT32(width)));
    STEP(in->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709));
    STEP(in->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB));
    STEP(in->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709));
    STEP(in->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235));
    STEP(movie->writer->SetInputMediaType(movie->stream, in, nullptr));
    STEP(movie->writer->BeginWriting());
    release(attributes);
    release(out);
    release(in);
    if (FAILED(hr)) {
        release(movie->writer);
        delete movie;
        return fail(hr);
    }
    movie->started = true;
    movie->nv12.resize(size_t(width) * height * 3 / 2);
    if (error) *error = 0;
    return movie;
}

extern "C" int32_t bz_movie_add(bz_movie* movie, const void* pixels, int64_t index) {
    if (!movie || !movie->writer || !pixels) return int32_t(E_POINTER);
    toNV12(static_cast<const uint8_t*>(pixels), movie->width, movie->height, movie->nv12.data());
    IMFMediaBuffer* buffer = nullptr;
    IMFSample* sample = nullptr;
    const DWORD size = DWORD(movie->nv12.size());
    lastStep = 100;
    HRESULT hr = MFCreateMemoryBuffer(size, &buffer);
    BYTE* into = nullptr;
    STEP(buffer->Lock(&into, nullptr, nullptr));
    if (SUCCEEDED(hr)) {
        memcpy(into, movie->nv12.data(), size);
        buffer->Unlock();
        hr = buffer->SetCurrentLength(size);
    }
    STEP(MFCreateSample(&sample));
    STEP(sample->AddBuffer(buffer));
    const LONGLONG start = at(index, movie->fps);
    STEP(sample->SetSampleTime(start));
    STEP(sample->SetSampleDuration(at(index + 1, movie->fps) - start));
    STEP(movie->writer->WriteSample(movie->stream, sample));
    release(sample);
    release(buffer);
    return SUCCEEDED(hr) ? 0 : int32_t(hr);
}

extern "C" int32_t bz_movie_finish(bz_movie* movie, int64_t frames) {
    if (!movie) return int32_t(E_POINTER);
    (void)frames;
    HRESULT hr = movie->writer ? movie->writer->Finalize() : E_POINTER;
    release(movie->writer);
    delete movie;
    return SUCCEEDED(hr) ? 0 : int32_t(hr);
}

extern "C" void bz_movie_cancel(bz_movie* movie) {
    if (!movie) return;
    release(movie->writer);
    delete movie;
}
