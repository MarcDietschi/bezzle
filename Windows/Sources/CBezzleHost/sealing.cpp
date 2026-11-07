// Sealing as Relay/SHARING.md has it, with Windows' own cryptography (bcrypt.h): AES-256-GCM, and
// HMAC-SHA256, which HKDF is made of. What CryptoKit does on the Mac; the Swift side is
// Host/Sealing.swift. Kept apart from host.cpp, whose Skia headers and windows.h do not mix.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

#include "BezzleHost.h"

#include <mutex>

namespace {

BCRYPT_ALG_HANDLE gcm() {
    static BCRYPT_ALG_HANDLE alg = nullptr;
    static std::once_flag opened;
    std::call_once(opened, [] {
        BCRYPT_ALG_HANDLE h = nullptr;
        if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&h, BCRYPT_AES_ALGORITHM, nullptr, 0))) return;
        if (!BCRYPT_SUCCESS(BCryptSetProperty(h, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_GCM, sizeof(BCRYPT_CHAIN_MODE_GCM), 0))) {
            BCryptCloseAlgorithmProvider(h, 0);
            return;
        }
        alg = h;
    });
    return alg;
}

BCRYPT_ALG_HANDLE hmac() {
    static BCRYPT_ALG_HANDLE alg = nullptr;
    static std::once_flag opened;
    std::call_once(opened, [] {
        BCRYPT_ALG_HANDLE h = nullptr;
        if (BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&h, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG))) alg = h;
    });
    return alg;
}

}  // namespace

extern "C" int32_t bz_gcm(int32_t seal, const uint8_t* key, const uint8_t* nonce, const uint8_t* aad, int32_t aadCount,
                          const uint8_t* input, int64_t count, uint8_t* output, uint8_t* tag) {
    BCRYPT_ALG_HANDLE alg = gcm();
    if (!alg) return -1;
    if (count < 0 || count > 0x7fffffff) return -2;
    BCRYPT_KEY_HANDLE k = nullptr;
    if (!BCRYPT_SUCCESS(BCryptGenerateSymmetricKey(alg, &k, nullptr, 0, (PUCHAR)key, 32, 0))) return -3;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = (PUCHAR)nonce;
    info.cbNonce = 12;
    // Nothing at all to seal still has its tag; BCrypt wants somewhere to read and write.
    static uint8_t none[1] = {0};
    info.pbAuthData = aadCount > 0 ? (PUCHAR)aad : nullptr;
    info.cbAuthData = ULONG(aadCount > 0 ? aadCount : 0);
    info.pbTag = tag;
    info.cbTag = 16;
    ULONG done = 0;
    PUCHAR in = count > 0 ? (PUCHAR)input : none, out = count > 0 ? output : none;
    NTSTATUS status = seal ? BCryptEncrypt(k, in, ULONG(count), &info, nullptr, 0, out, ULONG(count), &done, 0)
                           : BCryptDecrypt(k, in, ULONG(count), &info, nullptr, 0, out, ULONG(count), &done, 0);
    BCryptDestroyKey(k);
    return BCRYPT_SUCCESS(status) && int64_t(done) == count ? 0 : -4;
}

extern "C" int32_t bz_hmac_sha256(const uint8_t* key, int32_t keyCount, const uint8_t* data, int64_t count, uint8_t* out) {
    BCRYPT_ALG_HANDLE alg = hmac();
    if (!alg) return -1;
    if (count < 0 || count > 0x7fffffff) return -2;
    static uint8_t none[1] = {0};
    NTSTATUS status = BCryptHash(alg, keyCount > 0 ? (PUCHAR)key : none, ULONG(keyCount > 0 ? keyCount : 0),
                                 count > 0 ? (PUCHAR)data : none, ULONG(count), out, 32);
    return BCRYPT_SUCCESS(status) ? 0 : -3;
}
