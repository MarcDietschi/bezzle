// A WebSocket through WinHTTP, Windows' own, for the live room's connection to the relay
// (LiveWebSocket in Host/LiveTogether.swift). Swift's Foundation on Windows has one too, but it keeps a core busy for
// as long as it is open (libcurl's socket kept being reported as ready); WinHTTP's calls block,
// each on the thread that makes it, and nothing runs while nothing comes. One thread receives,
// another sends: WinHTTP takes one of each at a time. Kept apart from host.cpp, whose Skia headers
// and windows.h do not mix.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include "BezzleHost.h"

#include <cstdlib>
#include <cstring>

struct bz_ws {
    HINTERNET session = nullptr;
    HINTERNET connection = nullptr;
    HINTERNET request = nullptr;
    HINTERNET socket = nullptr;
    volatile LONG aborted = 0;
};

namespace {

void closeAll(bz_ws *ws) {
    if (ws->request) WinHttpCloseHandle(ws->request);
    if (ws->connection) WinHttpCloseHandle(ws->connection);
    if (ws->session) WinHttpCloseHandle(ws->session);
    ws->request = ws->connection = ws->session = nullptr;
}

}  // namespace

extern "C" bz_ws *bz_ws_open(const wchar_t *host, int32_t port, int32_t secure, const wchar_t *path, const wchar_t *headers,
                             int32_t timeout, uint32_t *error) {
    auto *ws = new bz_ws();
    auto fail = [&](DWORD why) -> bz_ws * {
        if (error) *error = why;
        if (ws->socket) WinHttpCloseHandle(ws->socket);
        closeAll(ws);
        delete ws;
        return nullptr;
    };
    ws->session = WinHttpOpen(L"Bezzle", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    // Before Windows 8.1, the proxy as Internet Options have it is the default one.
    if (!ws->session) ws->session = WinHttpOpen(L"Bezzle", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!ws->session) return fail(GetLastError());
    // Receiving waits as long as it takes: the room can be quiet, and the Swift side's pings notice
    // a connection that went away.
    WinHttpSetTimeouts(ws->session, timeout, timeout, timeout, 0);
    ws->connection = WinHttpConnect(ws->session, host, (INTERNET_PORT)port, 0);
    if (!ws->connection) return fail(GetLastError());
    ws->request = WinHttpOpenRequest(ws->connection, L"GET", path, nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                     secure ? WINHTTP_FLAG_SECURE : 0);
    if (!ws->request) return fail(GetLastError());
    if (!WinHttpSetOption(ws->request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) return fail(GetLastError());
    if (!WinHttpSendRequest(ws->request, headers ? headers : WINHTTP_NO_ADDITIONAL_HEADERS, headers ? (DWORD)-1L : 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0))
        return fail(GetLastError());
    if (!WinHttpReceiveResponse(ws->request, nullptr)) return fail(GetLastError());
    DWORD status = 0, size = sizeof(status);
    WinHttpQueryHeaders(ws->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &size,
                        WINHTTP_NO_HEADER_INDEX);
    if (status != 101) return fail(status ? 100000 + status : ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
    ws->socket = WinHttpWebSocketCompleteUpgrade(ws->request, 0);
    if (!ws->socket) return fail(GetLastError());
    // What the upgrade came through is the socket's now.
    WinHttpCloseHandle(ws->request);
    ws->request = nullptr;
    if (error) *error = 0;
    return ws;
}

extern "C" int64_t bz_ws_receive(bz_ws *ws, uint8_t **buffer, uint64_t *capacity, int32_t *kind, int64_t limit) {
    uint64_t length = 0;
    for (;;) {
        if (ws->aborted) return -1;
        if (*capacity - length < 64 * 1024) {
            uint64_t grown = *capacity ? *capacity * 2 : 256 * 1024;
            auto *bigger = (uint8_t *)realloc(*buffer, grown);
            if (!bigger) return -1;
            *buffer = bigger;
            *capacity = grown;
        }
        DWORD read = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE type;
        DWORD result = WinHttpWebSocketReceive(ws->socket, *buffer + length, (DWORD)(*capacity - length), &read, &type);
        // Quiet longer than the receive timeout: still there, as far as this side knows.
        if (result == ERROR_WINHTTP_TIMEOUT && !ws->aborted) continue;
        if (result != NO_ERROR) return -1;
        length += read;
        if ((int64_t)length > limit) return -1;
        switch (type) {
        case WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE:
        case WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE:
            continue;
        case WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE:
            *kind = 0;
            return (int64_t)length;
        case WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE:
            *kind = 1;
            return (int64_t)length;
        default:
            *kind = 2;
            return -1;
        }
    }
}

extern "C" int32_t bz_ws_send(bz_ws *ws, const void *data, uint64_t length, int32_t text) {
    if (ws->aborted) return -1;
    DWORD result = WinHttpWebSocketSend(ws->socket,
                                        text ? WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE : WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
                                        (PVOID)data, (DWORD)length);
    return result == NO_ERROR ? 0 : -1;
}

extern "C" void bz_ws_abort(bz_ws *ws) {
    // Closing the socket's handle ends the receive and the send waiting on it, on their threads.
    if (InterlockedExchange(&ws->aborted, 1) == 0 && ws->socket) {
        WinHttpWebSocketShutdown(ws->socket, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, nullptr, 0);
        WinHttpCloseHandle(ws->socket);
    }
}

extern "C" void bz_ws_free(bz_ws *ws) {
    if (!ws) return;
    if (InterlockedExchange(&ws->aborted, 1) == 0 && ws->socket) WinHttpCloseHandle(ws->socket);
    closeAll(ws);
    delete ws;
}
