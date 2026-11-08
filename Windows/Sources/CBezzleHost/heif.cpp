// HEIF pictures (HEIC, as iPhones and the Mac make them) read by Windows' own codecs, the Windows
// Imaging Component's, as Explorer and Photos read them (see picture-files.h). Windows reads them
// only with two of Microsoft's extensions from the Microsoft Store: HEIF Image Extensions, free
// and on most Windows 11 computers, which reads the file, and HEVC Video Extensions, which
// decodes its pictures; that one has a price (or comes free from some computers' makers), as
// HEVC has patent fees. Bezzle brings no HEVC decoder of its own: where Windows has none, a HEIC
// picture shows as a missing one does, and Bezzle says why.
//
// BEZZLE_NO_HEIF=1 or BEZZLE_NO_HEVC=1 make Bezzle behave as if Windows lacked that extension,
// to try what it then shows on a computer that has both.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincodec.h>

#include "picture-files.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <utility>

namespace {

std::atomic<int> last{heif::none};

bool pretending(const char* name) {
    const char* v = std::getenv(name);
    return v && v[0] == '1';
}

/// COM for as long as it lives, on whatever thread it is made: one that already has it (the
/// window's, apartment-threaded) keeps what it has.
struct Apartment {
    bool mine;
    Apartment() {
        const HRESULT h = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        mine = SUCCEEDED(h);
    }
    ~Apartment() {
        if (mine) CoUninitialize();
    }
};

template <class T> struct Held {
    T* p = nullptr;
    ~Held() {
        if (p) p->Release();
    }
    T** operator&() { return &p; }
    T* operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
};

/// Whether Windows has anything to decode HEVC with: Media Foundation's decoders, the HEVC Video
/// Extensions' among them. Asked of mfplat.dll as it is, not linked to.
bool hasHEVC() {
    if (pretending("BEZZLE_NO_HEVC")) return false;
    using Enum = HRESULT(WINAPI*)(GUID, UINT32, const void*, const void*, void***, UINT32*);
    static Enum find = [] {
        HMODULE m = LoadLibraryW(L"mfplat.dll");
        return m ? reinterpret_cast<Enum>(GetProcAddress(m, "MFTEnumEx")) : nullptr;
    }();
    if (!find) return false;
    struct TypeInfo { GUID major, sub; };
    static const GUID decoders = {0xd6c02d4b, 0x6833, 0x45b4, {0x97, 0x1a, 0x05, 0xa4, 0xb0, 0x4b, 0xab, 0x91}};
    static const GUID video = {0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
    static const GUID hevc = {0x43564548, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
    const TypeInfo input = {video, hevc};
    void** found = nullptr;
    UINT32 count = 0;
    // Every kind there is: in-process, asynchronous, hardware, and those from the Store.
    const UINT32 every = 0x3F | 0x400;
    if (FAILED(find(decoders, every, &input, nullptr, &found, &count))) return false;
    for (UINT32 k = 0; k < count; k++) static_cast<IUnknown*>(found[k])->Release();
    CoTaskMemFree(found);
    return count > 0;
}

/// Reads the file's first picture, its pixels only when `pixels` is given.
heif::Problem open(const void* data, size_t count, int* width, int* height, int* orientation, std::vector<uint8_t>* pixels,
                   std::vector<uint8_t>* icc) {
    if (pretending("BEZZLE_NO_HEIF")) return heif::noHEIF;
    Apartment apartment;
    Held<IWICImagingFactory> factory;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return heif::unreadable;
    Held<IWICBitmapDecoder> decoder;
    // No codec for the container: Windows lacks the HEIF Image Extensions.
    if (FAILED(factory->CreateDecoder(GUID_ContainerFormatHeif, nullptr, &decoder))) return heif::noHEIF;
    Held<IWICStream> stream;
    if (FAILED(factory->CreateStream(&stream)) ||
        FAILED(stream->InitializeFromMemory(static_cast<BYTE*>(const_cast<void*>(data)), DWORD(count)))) return heif::unreadable;
    // Read, but what it holds is not decoded: most often for want of HEVC.
    const auto stuck = [] { return hasHEVC() ? heif::unreadable : heif::noHEVC; };
    if (FAILED(decoder->Initialize(stream.p, WICDecodeMetadataCacheOnDemand))) return stuck();
    Held<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) return stuck();
    UINT w = 0, h = 0;
    if (FAILED(frame->GetSize(&w, &h)) || w == 0 || h == 0) return stuck();
    *width = int(w);
    *height = int(h);
    // How it is turned and mirrored (its 'irot' and 'imir'), as Exif counts it: the codec gives
    // the picture as kept.
    *orientation = 1;
    Held<IWICMetadataQueryReader> reader;
    if (SUCCEEDED(frame->GetMetadataQueryReader(&reader))) {
        PROPVARIANT v;
        PropVariantInit(&v);
        if (SUCCEEDED(reader->GetMetadataByName(L"/heifProps/Orientation", &v))) {
            if (v.vt == VT_UI2 && v.uiVal >= 1 && v.uiVal <= 8) *orientation = v.uiVal;
            else if (v.vt == VT_UI4 && v.ulVal >= 1 && v.ulVal <= 8) *orientation = int(v.ulVal);
            else if (v.vt == VT_UI1 && v.bVal >= 1 && v.bVal <= 8) *orientation = v.bVal;
        }
        PropVariantClear(&v);
    }
    if (!pixels) return heif::none;
    if (pretending("BEZZLE_NO_HEVC")) return heif::noHEVC;
    // Its colours: by its ICC profile when it has one (an iPhone's Display P3), else sRGB.
    if (icc) {
        UINT contexts = 0;
        if (SUCCEEDED(frame->GetColorContexts(0, nullptr, &contexts)) && contexts > 0) {
            std::vector<IWICColorContext*> made(contexts, nullptr);
            for (auto& c : made) factory->CreateColorContext(&c);
            UINT given = 0;
            if (SUCCEEDED(frame->GetColorContexts(contexts, made.data(), &given))) {
                for (UINT k = 0; k < given && icc->empty(); k++) {
                    WICColorContextType type;
                    UINT size = 0;
                    if (made[k] && SUCCEEDED(made[k]->GetType(&type)) && type == WICColorContextProfile &&
                        SUCCEEDED(made[k]->GetProfileBytes(0, nullptr, &size)) && size > 0) {
                        icc->resize(size);
                        if (FAILED(made[k]->GetProfileBytes(size, icc->data(), &size))) icc->clear();
                    }
                }
            }
            for (auto c : made) if (c) c->Release();
        }
    }
    Held<IWICFormatConverter> converter;
    if (FAILED(factory->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(frame.p, GUID_WICPixelFormat32bppPRGBA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)))
        return stuck();
    pixels->resize(size_t(w) * h * 4);
    if (FAILED(converter->CopyPixels(nullptr, w * 4, UINT(pixels->size()), pixels->data()))) {
        pixels->clear();
        return stuck();
    }
    return heif::none;
}

}  // namespace

namespace heif {

bool sniff(const void* data, size_t count) {
    const auto* b = static_cast<const uint8_t*>(data);
    if (!b || count < 16 || std::memcmp(b + 4, "ftyp", 4) != 0) return false;
    const size_t box = std::min(count, size_t(uint32_t(b[0]) << 24 | uint32_t(b[1]) << 16 | uint32_t(b[2]) << 8 | b[3]));
    const auto named = [&](size_t at, const char* brand) { return at + 4 <= box && std::memcmp(b + at, brand, 4) == 0; };
    static const char* hevc[] = {"heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs"};
    for (size_t at = 8; at + 4 <= box; at += at == 8 ? 8 : 4) {
        for (const char* brand : hevc) {
            if (named(at, brand)) return true;
        }
    }
    // A plain HEIF picture of another kind than AVIF's (avif.cpp is asked first).
    return named(8, "mif1") || named(8, "msf1");
}

Problem read(const void* data, size_t count, Picture& picture) {
    const Problem p = open(data, count, &picture.width, &picture.height, &picture.orientation, &picture.pixels, &picture.icc);
    if (p != none) last = p;
    return p;
}

Problem size(const void* data, size_t count, bool upright, int* width, int* height) {
    int orientation = 1;
    const Problem p = open(data, count, width, height, &orientation, nullptr, nullptr);
    // Exif's 5 to 8 turn it a quarter: as tall as it was wide.
    if (p == none && upright && orientation >= 5) std::swap(*width, *height);
    if (p != none) last = p;
    return p;
}

Problem lastProblem() { return Problem(last.load()); }

}  // namespace heif
