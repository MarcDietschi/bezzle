// Checking spelling through Windows' own spell checkers (spellcheck.h), as the Mac's find bar
// asks NSSpellChecker: which words are misspelt, how they might be spelt, and words learnt. Kept apart from host.cpp, whose Skia headers and windows.h do not mix.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <spellcheck.h>

#include "BezzleHost.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

namespace {

std::mutex lock;
ISpellCheckerFactory* factory = nullptr;
std::map<std::string, ISpellChecker*> checkers;

ISpellCheckerFactory* theFactory() {
    if (factory) return factory;
    // WinUI's thread has COM already; this does nothing then.
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) factory = nullptr;
    return factory;
}

std::wstring wide(const char* s) {
    if (!s || !*s) return L"";
    const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring out(size_t(n > 0 ? n - 1 : 0), L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, out.data(), n);
    return out;
}

std::string narrow(const wchar_t* s) {
    if (!s || !*s) return "";
    const int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    std::string out(size_t(n > 0 ? n - 1 : 0), '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, s, -1, out.data(), n, nullptr, nullptr);
    return out;
}

ISpellChecker* checker(const char* language) {
    const std::string key = language ? language : "";
    if (auto it = checkers.find(key); it != checkers.end()) return it->second;
    ISpellChecker* made = nullptr;
    if (auto f = theFactory()) {
        const std::wstring tag = wide(language);
        BOOL supported = FALSE;
        if (SUCCEEDED(f->IsSupported(tag.c_str(), &supported)) && supported) {
            if (FAILED(f->CreateSpellChecker(tag.c_str(), &made))) made = nullptr;
        }
    }
    checkers[key] = made;
    return made;
}

std::wstring words(const uint16_t* text, int32_t count) {
    return std::wstring(reinterpret_cast<const wchar_t*>(text), size_t(count > 0 ? count : 0));
}

int32_t copy(const std::string& s, char* out, int32_t capacity) {
    if (out && capacity > 0) memcpy(out, s.data(), size_t(std::min<int32_t>(capacity, int32_t(s.size()))));
    return int32_t(s.size());
}

}  // namespace

extern "C" int32_t bz_spell_languages(char* out, int32_t capacity) {
    std::lock_guard<std::mutex> guard(lock);
    std::string list;
    if (auto f = theFactory()) {
        IEnumString* tags = nullptr;
        if (SUCCEEDED(f->get_SupportedLanguages(&tags)) && tags) {
            LPOLESTR tag = nullptr;
            while (tags->Next(1, &tag, nullptr) == S_OK) {
                if (!list.empty()) list += ",";
                list += narrow(tag);
                CoTaskMemFree(tag);
            }
            tags->Release();
        }
    }
    return copy(list, out, capacity);
}

extern "C" int32_t bz_spell_check(const char* language, const uint16_t* text, int32_t count, int32_t* ranges, int32_t capacity) {
    std::lock_guard<std::mutex> guard(lock);
    ISpellChecker* c = checker(language);
    if (!c) return -1;
    const std::wstring w = words(text, count);
    IEnumSpellingError* errors = nullptr;
    if (FAILED(c->Check(w.c_str(), &errors)) || !errors) return 0;
    int32_t found = 0;
    ISpellingError* error = nullptr;
    while (errors->Next(&error) == S_OK && error) {
        ULONG start = 0, length = 0;
        CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
        error->get_StartIndex(&start);
        error->get_Length(&length);
        error->get_CorrectiveAction(&action);
        // A word said twice is grammar, which the Mac's spelling leaves to its grammar.
        if (length > 0 && (action == CORRECTIVE_ACTION_GET_SUGGESTIONS || action == CORRECTIVE_ACTION_REPLACE)) {
            if (found < capacity) {
                ranges[found * 2] = int32_t(start);
                ranges[found * 2 + 1] = int32_t(length);
            }
            found++;
        }
        error->Release();
        error = nullptr;
    }
    errors->Release();
    return found;
}

extern "C" int32_t bz_spell_guesses(const char* language, const uint16_t* word, int32_t count, char* out, int32_t capacity) {
    std::lock_guard<std::mutex> guard(lock);
    ISpellChecker* c = checker(language);
    if (!c) return 0;
    const std::wstring w = words(word, count);
    std::string list;
    IEnumString* guesses = nullptr;
    if (SUCCEEDED(c->Suggest(w.c_str(), &guesses)) && guesses) {
        LPOLESTR guess = nullptr;
        while (guesses->Next(1, &guess, nullptr) == S_OK) {
            if (!list.empty()) list += "\n";
            list += narrow(guess);
            CoTaskMemFree(guess);
        }
        guesses->Release();
    }
    return copy(list, out, capacity);
}

extern "C" int32_t bz_spell_repeats(const char* language, const uint16_t* text, int32_t count, int32_t* ranges, int32_t capacity) {
    std::lock_guard<std::mutex> guard(lock);
    ISpellChecker* c = checker(language);
    if (!c) return -1;
    const std::wstring w = words(text, count);
    IEnumSpellingError* errors = nullptr;
    if (FAILED(c->Check(w.c_str(), &errors)) || !errors) return 0;
    int32_t found = 0;
    ISpellingError* error = nullptr;
    while (errors->Next(&error) == S_OK && error) {
        ULONG start = 0, length = 0;
        CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
        error->get_StartIndex(&start);
        error->get_Length(&length);
        error->get_CorrectiveAction(&action);
        // What Windows says to delete is a word said twice.
        if (length > 0 && action == CORRECTIVE_ACTION_DELETE) {
            if (found < capacity) {
                ranges[found * 2] = int32_t(start);
                ranges[found * 2 + 1] = int32_t(length);
            }
            found++;
        }
        error->Release();
        error = nullptr;
    }
    errors->Release();
    return found;
}

extern "C" void bz_spell_learn(const char* language, const uint16_t* word, int32_t count) {
    std::lock_guard<std::mutex> guard(lock);
    if (ISpellChecker* c = checker(language)) c->Add(words(word, count).c_str());
}
