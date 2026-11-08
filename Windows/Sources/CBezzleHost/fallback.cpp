// Which of Windows' own fonts draws a letter the design's fonts do not have, as Core Text falls
// back on the Mac's own fonts for scripts a font lacks (Arabic, Hebrew, Chinese, Japanese, Korean,
// Thai, Devanagari, emoji…): DirectWrite's system font fallback names the font, as Windows' own
// text does, and host.cpp has Skia read it from its file. Kept apart from host.cpp, whose Skia
// headers and windows.h do not mix.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwrite_2.h>

#include <cstdint>
#include <string>

extern "C" int32_t bz_fallback_font(uint32_t character, int32_t emoji, int32_t weight, int32_t italic, int32_t stretch,
                                    wchar_t* path, int32_t capacity, int32_t* index);

namespace {

/// The letter whose font is asked for, as DirectWrite reads text: in the language Windows is set
/// to, which picks between the Chinese, Japanese and Korean shapes of the same character; an
/// emoji asked to look like one (U+FE0F after it), as the text had it.
class Letter final : public IDWriteTextAnalysisSource {
public:
    Letter(uint32_t c, bool emoji, const wchar_t* locale) : locale(locale) {
        if (c >= 0x10000) {
            c -= 0x10000;
            text[length++] = wchar_t(0xD800 + (c >> 10));
            text[length++] = wchar_t(0xDC00 + (c & 0x3FF));
        } else {
            text[length++] = wchar_t(c);
        }
        if (emoji) text[length++] = wchar_t(0xFE0F);
    }
    UINT32 length = 0;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (id == __uuidof(IUnknown) || id == __uuidof(IDWriteTextAnalysisSource)) {
            *out = this;
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    // Lives on the stack for the one call it is asked in.
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }

    HRESULT STDMETHODCALLTYPE GetTextAtPosition(UINT32 at, const WCHAR** out, UINT32* count) override {
        *out = at < length ? text + at : nullptr;
        *count = at < length ? length - at : 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetTextBeforePosition(UINT32 at, const WCHAR** out, UINT32* count) override {
        *out = at > 0 && at <= length ? text : nullptr;
        *count = at > 0 && at <= length ? at : 0;
        return S_OK;
    }
    DWRITE_READING_DIRECTION STDMETHODCALLTYPE GetParagraphReadingDirection() override { return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT; }
    HRESULT STDMETHODCALLTYPE GetLocaleName(UINT32 at, UINT32* count, const WCHAR** name) override {
        *name = locale;
        *count = length > at ? length - at : 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetNumberSubstitution(UINT32 at, UINT32* count, IDWriteNumberSubstitution** out) override {
        *out = nullptr;
        *count = length > at ? length - at : 0;
        return S_OK;
    }

private:
    wchar_t text[3] = {0, 0, 0};
    const wchar_t* locale;
};

IDWriteFactory2* factory() {
    static IDWriteFactory2* made = [] {
        IDWriteFactory2* f = nullptr;
        if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory2), reinterpret_cast<IUnknown**>(&f)))) f = nullptr;
        return f;
    }();
    return made;
}

}  // namespace

/// The file (`path`, at most `capacity` letters with its end) and the font in it (`index`, for a
/// collection) Windows draws `character` with when the font asked for lacks it (as an emoji, in
/// colour, with `emoji`), at about the weight (100 to 900), slant and width (1 to 9, 5 normal)
/// asked for. 1 when there is one, else 0.
extern "C" int32_t bz_fallback_font(uint32_t character, int32_t emoji, int32_t weight, int32_t italic, int32_t stretch,
                                    wchar_t* path, int32_t capacity, int32_t* index) {
    IDWriteFactory2* f = factory();
    if (!f || !path || capacity <= 0) return 0;
    static IDWriteFontFallback* fallback = [f] {
        IDWriteFontFallback* made = nullptr;
        if (FAILED(f->GetSystemFontFallback(&made))) made = nullptr;
        return made;
    }();
    if (!fallback) return 0;
    static wchar_t locale[LOCALE_NAME_MAX_LENGTH] = {0};
    if (!locale[0] && !GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH)) wcscpy_s(locale, L"en-US");
    Letter letter(character, emoji != 0, locale);
    UINT32 mapped = 0;
    IDWriteFont* font = nullptr;
    FLOAT scale = 1;
    const auto w = DWRITE_FONT_WEIGHT(weight < 1 ? 400 : weight > 999 ? 999 : weight);
    const auto s = DWRITE_FONT_STRETCH(stretch < 1 ? 5 : stretch > 9 ? 9 : stretch);
    // An emoji in Windows' colour emoji where it has it, as the Mac's are in Apple Color Emoji:
    // the fallback alone gives some (a heart) a plain symbol font's outline.
    if (emoji) {
        IDWriteFontCollection* system = nullptr;
        if (SUCCEEDED(f->GetSystemFontCollection(&system)) && system) {
            UINT32 at = 0;
            BOOL exists = FALSE;
            IDWriteFontFamily* family = nullptr;
            if (SUCCEEDED(system->FindFamilyName(L"Segoe UI Emoji", &at, &exists)) && exists && SUCCEEDED(system->GetFontFamily(at, &family)) && family) {
                IDWriteFont* colour = nullptr;
                BOOL has = FALSE;
                if (SUCCEEDED(family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, &colour)) && colour) {
                    if (SUCCEEDED(colour->HasCharacter(character, &has)) && has) font = colour; else colour->Release();
                }
                family->Release();
            }
            system->Release();
        }
    }
    if (!font && (FAILED(fallback->MapCharacters(&letter, 0, letter.length, nullptr, nullptr, w, italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
                                                 s, &mapped, &font, &scale)) || !font)) {
        return 0;
    }
    int32_t found = 0;
    IDWriteFontFace* face = nullptr;
    if (SUCCEEDED(font->CreateFontFace(&face)) && face) {
        UINT32 files = 1;
        IDWriteFontFile* file = nullptr;
        if (SUCCEEDED(face->GetFiles(&files, &file)) && file) {
            const void* key = nullptr;
            UINT32 keySize = 0;
            IDWriteFontFileLoader* loader = nullptr;
            IDWriteLocalFontFileLoader* local = nullptr;
            if (SUCCEEDED(file->GetReferenceKey(&key, &keySize)) && SUCCEEDED(file->GetLoader(&loader)) && loader &&
                SUCCEEDED(loader->QueryInterface(__uuidof(IDWriteLocalFontFileLoader), reinterpret_cast<void**>(&local))) && local) {
                UINT32 length = 0;
                if (SUCCEEDED(local->GetFilePathLengthFromKey(key, keySize, &length)) && int32_t(length) < capacity &&
                    SUCCEEDED(local->GetFilePathFromKey(key, keySize, path, length + 1))) {
                    if (index) *index = int32_t(face->GetIndex());
                    found = 1;
                }
                local->Release();
            }
            if (loader) loader->Release();
            file->Release();
        }
        face->Release();
    }
    font->Release();
    return found;
}
