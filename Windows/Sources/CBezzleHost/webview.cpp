// Web pages read for bringing a website in (the Swift side is Import/WebCapture.swift): each in a
// WebView2 of its own, Microsoft Edge's engine, which Windows 11 has, as the Mac reads them in a
// WKWebView. A web view lives on a thread of its own with its own message loop, so that whoever
// asks (the app's main thread or a command-line tool) waits there for nothing: every call is
// handed to that thread and answered when WebView2 has answered. Its window is on screen but
// cloaked, and kept from being held back as hidden, so the page runs as if it were shown, as the
// Mac's window at no opacity does. Kept apart from host.cpp, whose Skia headers and windows.h do
// not mix. Built without WebView2's SDK (Packages\webview2, fetched by winrt.ps1), every call
// says so.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "BezzleHost.h"

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

char* copied(const std::string& s) {
    char* out = static_cast<char*>(malloc(s.size() + 1));
    if (out) memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

std::string lastError;

}  // namespace

extern "C" void bz_web_free(void* p) { free(p); }

#if !BEZZLE_WEBVIEW2

extern "C" int32_t bz_web_open(int32_t, int32_t, double, const char*, const char*) {
    lastError = "Bezzle was built without WebView2.";
    return 0;
}
extern "C" int32_t bz_web_resize(int32_t, int32_t, int32_t, const char*) { return -1; }
extern "C" int32_t bz_web_load(int32_t, const char*, int32_t) { return -1; }
extern "C" int32_t bz_web_state(int32_t, int32_t* status, int32_t* error, int32_t* navigations) {
    if (status) *status = 0;
    if (error) *error = 0;
    if (navigations) *navigations = 0;
    return 3;
}
extern "C" int32_t bz_web_call(int32_t, const char*, const char*, int32_t, char** answer) {
    if (answer) *answer = copied("{\"message\":\"Bezzle was built without WebView2.\"}");
    return -1;
}
extern "C" void bz_web_close(int32_t) {}
extern "C" char* bz_web_error(void) { return copied(lastError); }

#else

#include <dwmapi.h>
#include <shlobj.h>
#include <objbase.h>

#include "WebView2.h"

#include <atomic>
#include <chrono>
#include <functional>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

namespace {

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

std::string hex(HRESULT hr) {
    char text[16];
    snprintf(text, sizeof text, "0x%08lX", static_cast<unsigned long>(hr));
    return text;
}

/// A completion or event handler made of a function: what WebView2 calls back with.
template <typename I, typename... Args>
class Handler final : public I {
public:
    explicit Handler(std::function<HRESULT(Args...)> run) : run_(std::move(run)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (riid == __uuidof(I) || riid == IID_IUnknown) {
            *out = static_cast<I*>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG left = InterlockedDecrement(&refs_);
        if (left == 0) delete this;
        return left;
    }
    HRESULT STDMETHODCALLTYPE Invoke(Args... args) override { return run_(args...); }

private:
    std::function<HRESULT(Args...)> run_;
    ULONG refs_ = 1;
};

/// Hands a handler over: WebView2 keeps its own reference, so ours goes once given.
template <typename I, typename... Args, typename F>
I* handler(F f) {
    return new Handler<I, Args...>(std::function<HRESULT(Args...)>(f));
}

LPWSTR taskString(const std::wstring& s) {
    auto out = static_cast<LPWSTR>(CoTaskMemAlloc((s.size() + 1) * sizeof(wchar_t)));
    if (out) memcpy(out, s.c_str(), (s.size() + 1) * sizeof(wchar_t));
    return out;
}

/// How the browser runs: as if shown, whatever Windows thinks of the window, its timers at full
/// speed, nothing playing out loud and nothing playing by itself.
class Options final : public ICoreWebView2EnvironmentOptions {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (riid == __uuidof(ICoreWebView2EnvironmentOptions) || riid == IID_IUnknown) {
            *out = static_cast<ICoreWebView2EnvironmentOptions*>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG left = InterlockedDecrement(&refs_);
        if (left == 0) delete this;
        return left;
    }
    HRESULT STDMETHODCALLTYPE get_AdditionalBrowserArguments(LPWSTR* value) override {
        *value = taskString(arguments_);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_AdditionalBrowserArguments(LPCWSTR value) override {
        arguments_ = value ? value : L"";
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Language(LPWSTR* value) override {
        *value = taskString(L"");
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_Language(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_TargetCompatibleBrowserVersion(LPWSTR* value) override {
        // The SDK's own (WebView2EnvironmentOptions.h): the oldest runtime that has its interfaces.
        *value = taskString(L"131.0.2903.40");
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_TargetCompatibleBrowserVersion(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_AllowSingleSignOnUsingOSPrimaryAccount(BOOL* value) override {
        *value = FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_AllowSingleSignOnUsingOSPrimaryAccount(BOOL) override { return S_OK; }

private:
    std::wstring arguments_ = L"--disable-features=CalculateNativeWinOcclusion --disable-background-timer-throttling "
                              L"--disable-renderer-backgrounding --disable-backgrounding-occluded-windows "
                              L"--autoplay-policy=user-gesture-required --mute-audio";
    ULONG refs_ = 1;
};

// MARK: The thread the web views live on

const UINT taskMessage = WM_APP + 7;
std::once_flag started;
HWND tasks = nullptr;

LRESULT CALLBACK taskProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == taskMessage) {
        auto task = reinterpret_cast<std::function<void()>*>(l);
        (*task)();
        delete task;
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

void startThread() {
    std::call_once(started, [] {
        std::promise<void> ready;
        auto running = ready.get_future();
        std::thread([&ready] {
            CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
            WNDCLASSEXW tasksClass{sizeof(WNDCLASSEXW)};
            tasksClass.lpfnWndProc = taskProc;
            tasksClass.hInstance = GetModuleHandleW(nullptr);
            tasksClass.lpszClassName = L"BezzleWebTasks";
            RegisterClassExW(&tasksClass);
            WNDCLASSEXW pageClass{sizeof(WNDCLASSEXW)};
            pageClass.lpfnWndProc = DefWindowProcW;
            pageClass.hInstance = GetModuleHandleW(nullptr);
            pageClass.lpszClassName = L"BezzleWebPage";
            pageClass.hbrBackground = static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH));
            RegisterClassExW(&pageClass);
            tasks = CreateWindowExW(0, L"BezzleWebTasks", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
            ready.set_value();
            MSG message;
            while (GetMessageW(&message, nullptr, 0, 0) > 0) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }).detach();
        running.wait();
    });
}

void post(std::function<void()> task) {
    startThread();
    PostMessageW(tasks, taskMessage, 0, reinterpret_cast<LPARAM>(new std::function<void()>(std::move(task))));
}

/// What the web thread says back, once: later words (WebView2 calling back after a failure was
/// said, or after the asker stopped waiting) are let go.
template <typename T>
struct Answer {
    std::promise<T> promise;
    std::atomic<bool> said{false};
    void say(T value) {
        if (!said.exchange(true)) promise.set_value(std::move(value));
    }
};

template <typename T>
using Said = std::shared_ptr<Answer<T>>;

/// Hands `work` to the web thread and waits up to `timeout` for what it says; `fallback` when it
/// did not say in time.
template <typename T>
T ask(std::function<void(Said<T>)> work, std::chrono::milliseconds timeout, T fallback) {
    auto answer = std::make_shared<Answer<T>>();
    auto future = answer->promise.get_future();
    post([answer, work] { work(answer); });
    if (future.wait_for(timeout) != std::future_status::ready) return fallback;
    return future.get();
}

// MARK: Views

struct View {
    HWND window = nullptr;
    ICoreWebView2Environment* environment = nullptr;
    ICoreWebView2Controller* controller = nullptr;
    ICoreWebView2* web = nullptr;
    double scale = 1;

    // What loading came to, asked from any thread.
    std::mutex lock;
    int state = 0;       // 0 loading, 1 loaded, 2 failed, 3 the page's process went
    int status = 0;      // the HTTP status of the page
    int error = 0;       // why it failed, as bz_web_state says it
    int navigations = 0; // how many have begun
    UINT64 latest = 0;   // the one begun last
};

/// Why a page could not be loaded, as bz_web_state says it.
int reason(COREWEBVIEW2_WEB_ERROR_STATUS error) {
    switch (error) {
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT:
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED:
    case COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS:
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED:
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID: return 1;
    case COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_ABORTED:
    case COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_RESET:
    case COREWEBVIEW2_WEB_ERROR_STATUS_ERROR_HTTP_INVALID_SERVER_RESPONSE: return 2;
    case COREWEBVIEW2_WEB_ERROR_STATUS_DISCONNECTED: return 3;
    case COREWEBVIEW2_WEB_ERROR_STATUS_SERVER_UNREACHABLE:
    case COREWEBVIEW2_WEB_ERROR_STATUS_CANNOT_CONNECT: return 4;
    case COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED: return 5;
    case COREWEBVIEW2_WEB_ERROR_STATUS_REDIRECT_FAILED: return 6;
    case COREWEBVIEW2_WEB_ERROR_STATUS_VALID_AUTHENTICATION_CREDENTIALS_REQUIRED:
    case COREWEBVIEW2_WEB_ERROR_STATUS_VALID_PROXY_AUTHENTICATION_REQUIRED: return 7;
    case COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT: return 8;
    default: return 0;
    }
}

using Reply = std::pair<int32_t, std::string>;

std::mutex viewsLock;
std::map<int32_t, std::shared_ptr<View>> views;
std::atomic<int32_t> counter{0};

std::shared_ptr<View> find(int32_t id) {
    std::lock_guard<std::mutex> guard(viewsLock);
    auto it = views.find(id);
    return it == views.end() ? nullptr : it->second;
}

template <typename T>
void release(T*& p) {
    if (p) p->Release();
    p = nullptr;
}

void letGo(View& v) {
    if (v.controller) v.controller->Close();
    release(v.web);
    release(v.controller);
    release(v.environment);
    if (v.window) DestroyWindow(v.window);
    v.window = nullptr;
}

void place(View& v, int32_t width, int32_t height) {
    const int w = int(width * v.scale + 0.5), h = int(height * v.scale + 0.5);
    // Where the screen begins, as the Mac puts its window at the screen's corner: on screen,
    // cloaked, never in front.
    RECT area{0, 0, 0, 0};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0);
    SetWindowPos(v.window, HWND_BOTTOM, area.left, area.top, w, h, SWP_NOACTIVATE);
    if (v.controller) v.controller->put_Bounds(RECT{0, 0, w, h});
}

void setAgent(View& v, const std::wstring& agent) {
    ICoreWebView2Settings* settings = nullptr;
    if (!v.web || FAILED(v.web->get_Settings(&settings)) || !settings) return;
    ICoreWebView2Settings2* settings2 = nullptr;
    if (SUCCEEDED(settings->QueryInterface(IID_PPV_ARGS(&settings2))) && settings2) {
        // Empty is WebView2's own, as given at first.
        static std::wstring own;
        if (own.empty()) {
            LPWSTR was = nullptr;
            if (SUCCEEDED(settings2->get_UserAgent(&was)) && was) {
                own = was;
                CoTaskMemFree(was);
            }
        }
        settings2->put_UserAgent(agent.empty() ? own.c_str() : agent.c_str());
        settings2->Release();
    }
    settings->Release();
}

/// Everything a page might ask of someone looking at it is refused or left unanswered, as a
/// WKWebView with no one to ask refuses it: windows, downloads, permissions, passwords, dialogs.
void settle(std::shared_ptr<View> view) {
    View& v = *view;
    EventRegistrationToken token;
    ICoreWebView2Settings* settings = nullptr;
    if (SUCCEEDED(v.web->get_Settings(&settings)) && settings) {
        settings->put_IsStatusBarEnabled(FALSE);
        settings->put_AreDefaultContextMenusEnabled(FALSE);
        settings->put_AreDefaultScriptDialogsEnabled(FALSE);
        settings->put_IsZoomControlEnabled(FALSE);
        settings->put_IsBuiltInErrorPageEnabled(TRUE);
        ICoreWebView2Settings4* settings4 = nullptr;
        if (SUCCEEDED(settings->QueryInterface(IID_PPV_ARGS(&settings4))) && settings4) {
            settings4->put_IsPasswordAutosaveEnabled(FALSE);
            settings4->put_IsGeneralAutofillEnabled(FALSE);
            settings4->Release();
        }
        settings->Release();
    }
    std::weak_ptr<View> weak = view;
    v.web->add_NavigationStarting(
        handler<ICoreWebView2NavigationStartingEventHandler, ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs*>(
            [weak](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
                auto view = weak.lock();
                if (!view) return S_OK;
                UINT64 id = 0;
                args->get_NavigationId(&id);
                std::lock_guard<std::mutex> guard(view->lock);
                if (view->state != 3) view->state = 0;
                view->latest = id;
                view->navigations += 1;
                return S_OK;
            }),
        &token);
    v.web->add_NavigationCompleted(
        handler<ICoreWebView2NavigationCompletedEventHandler, ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs*>(
            [weak](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
                auto view = weak.lock();
                if (!view) return S_OK;
                UINT64 id = 0;
                args->get_NavigationId(&id);
                BOOL success = FALSE;
                args->get_IsSuccess(&success);
                COREWEBVIEW2_WEB_ERROR_STATUS error = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                args->get_WebErrorStatus(&error);
                int status = 0;
                ICoreWebView2NavigationCompletedEventArgs2* args2 = nullptr;
                if (SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(&args2))) && args2) {
                    args2->get_HttpStatusCode(&status);
                    args2->Release();
                }
                std::lock_guard<std::mutex> guard(view->lock);
                if (view->state == 3 || (id != view->latest && view->latest != 0)) return S_OK;
                // A load given up for another (or for a download) is no failure, as on the Mac.
                if (!success && error == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) return S_OK;
                view->status = status;
                // A page the server sent with an error status still shows: it is read, and its
                // status named, as the Mac does.
                if (success || status >= 400) {
                    view->state = 1;
                } else {
                    view->state = 2;
                    view->error = reason(error);
                }
                return S_OK;
            }),
        &token);
    v.web->add_ProcessFailed(
        handler<ICoreWebView2ProcessFailedEventHandler, ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*>(
            [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
                auto view = weak.lock();
                if (!view) return S_OK;
                COREWEBVIEW2_PROCESS_FAILED_KIND kind = COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED;
                args->get_ProcessFailedKind(&kind);
                if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED || kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED ||
                    kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE) {
                    std::lock_guard<std::mutex> guard(view->lock);
                    view->state = 3;
                }
                return S_OK;
            }),
        &token);
    // Pages that open others leave them unopened.
    v.web->add_NewWindowRequested(
        handler<ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs*>(
            [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
                args->put_Handled(TRUE);
                return S_OK;
            }),
        &token);
    v.web->add_PermissionRequested(
        handler<ICoreWebView2PermissionRequestedEventHandler, ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs*>(
            [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
                args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
                return S_OK;
            }),
        &token);
    // Alerts and questions are answered with nothing, at once.
    v.web->add_ScriptDialogOpening(
        handler<ICoreWebView2ScriptDialogOpeningEventHandler, ICoreWebView2*, ICoreWebView2ScriptDialogOpeningEventArgs*>(
            [](ICoreWebView2*, ICoreWebView2ScriptDialogOpeningEventArgs*) -> HRESULT { return S_OK; }),
        &token);
    ICoreWebView2_4* web4 = nullptr;
    if (SUCCEEDED(v.web->QueryInterface(IID_PPV_ARGS(&web4))) && web4) {
        web4->add_DownloadStarting(
            handler<ICoreWebView2DownloadStartingEventHandler, ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs*>(
                [](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
                    args->put_Cancel(TRUE);
                    args->put_Handled(TRUE);
                    return S_OK;
                }),
            &token);
        web4->Release();
    }
    ICoreWebView2_8* web8 = nullptr;
    if (SUCCEEDED(v.web->QueryInterface(IID_PPV_ARGS(&web8))) && web8) {
        web8->put_IsMuted(TRUE);
        web8->Release();
    }
    ICoreWebView2_10* web10 = nullptr;
    if (SUCCEEDED(v.web->QueryInterface(IID_PPV_ARGS(&web10))) && web10) {
        web10->add_BasicAuthenticationRequested(
            handler<ICoreWebView2BasicAuthenticationRequestedEventHandler, ICoreWebView2*, ICoreWebView2BasicAuthenticationRequestedEventArgs*>(
                [](ICoreWebView2*, ICoreWebView2BasicAuthenticationRequestedEventArgs* args) -> HRESULT {
                    args->put_Cancel(TRUE);
                    return S_OK;
                }),
            &token);
        web10->Release();
    }
}

/// Where WebView2 keeps what it must (pages are read in private, so nothing of theirs stays).
std::wstring dataFolder() {
    PWSTR local = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local)) && local) out = std::wstring(local) + L"\\Bezzle\\Web Pages";
    if (local) CoTaskMemFree(local);
    return out;
}

/// Makes the view: its window, the browser, its controller and its settings; says "" when it is
/// ready, otherwise why not.
void create(std::shared_ptr<View> view, int32_t width, int32_t height, std::wstring agent, std::wstring awake,
            Said<std::string> done) {
    View& v = *view;
    v.window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, L"BezzleWebPage", L"Bezzle", WS_POPUP,
                               0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!v.window) {
        done->say("its window could not be made (" + hex(HRESULT_FROM_WIN32(GetLastError())) + ")");
        return;
    }
    // On screen, as a shown page runs, but cloaked: no one sees it.
    BOOL cloak = TRUE;
    DwmSetWindowAttribute(v.window, DWMWA_CLOAK, &cloak, sizeof cloak);
    place(v, width, height);
    ShowWindow(v.window, SW_SHOWNOACTIVATE);
    auto options = new Options();
    const std::wstring folder = dataFolder();
    const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, folder.empty() ? nullptr : folder.c_str(), options,
        handler<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, HRESULT, ICoreWebView2Environment*>(
            [view, width, height, agent, awake, done](HRESULT hr, ICoreWebView2Environment* environment) -> HRESULT {
                View& v = *view;
                if (FAILED(hr) || !environment) {
                    done->say("WebView2 could not start (" + hex(hr) + ")");
                    return S_OK;
                }
                environment->AddRef();
                v.environment = environment;
                auto made = handler<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, HRESULT, ICoreWebView2Controller*>(
                    [view, width, height, agent, awake, done](HRESULT hr, ICoreWebView2Controller* controller) -> HRESULT {
                        View& v = *view;
                        if (FAILED(hr) || !controller) {
                            done->say("WebView2 could not show a page (" + hex(hr) + ")");
                            return S_OK;
                        }
                        controller->AddRef();
                        v.controller = controller;
                        // CSS pixels `scale` device pixels each, whatever the screen is.
                        ICoreWebView2Controller3* controller3 = nullptr;
                        if (SUCCEEDED(controller->QueryInterface(IID_PPV_ARGS(&controller3))) && controller3) {
                            controller3->put_ShouldDetectMonitorScaleChanges(FALSE);
                            controller3->put_RasterizationScale(v.scale);
                            controller3->Release();
                        }
                        place(v, width, height);
                        controller->put_IsVisible(TRUE);
                        if (FAILED(controller->get_CoreWebView2(&v.web)) || !v.web) {
                            done->say("WebView2 gave no page");
                            return S_OK;
                        }
                        settle(view);
                        setAgent(v, agent);
                        if (awake.empty()) {
                            done->say("");
                            return S_OK;
                        }
                        auto added = handler<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, HRESULT, LPCWSTR>(
                            [done](HRESULT hr, LPCWSTR) -> HRESULT {
                                done->say(FAILED(hr) ? "its first script could not be given (" + hex(hr) + ")" : "");
                                return S_OK;
                            });
                        v.web->AddScriptToExecuteOnDocumentCreated(awake.c_str(), added);
                        added->Release();
                        return S_OK;
                    });
                // In private: nothing a page keeps (cookies, storage) outlasts the view.
                ICoreWebView2Environment10* environment10 = nullptr;
                ICoreWebView2ControllerOptions* controllerOptions = nullptr;
                HRESULT asked = E_NOINTERFACE;
                if (SUCCEEDED(environment->QueryInterface(IID_PPV_ARGS(&environment10))) && environment10 &&
                    SUCCEEDED(environment10->CreateCoreWebView2ControllerOptions(&controllerOptions)) && controllerOptions) {
                    controllerOptions->put_IsInPrivateModeEnabled(TRUE);
                    asked = environment10->CreateCoreWebView2ControllerWithOptions(v.window, controllerOptions, made);
                }
                if (controllerOptions) controllerOptions->Release();
                if (environment10) environment10->Release();
                if (FAILED(asked)) asked = environment->CreateCoreWebView2Controller(v.window, made);
                made->Release();
                if (FAILED(asked)) done->say("WebView2 could not show a page (" + hex(asked) + ")");
                return S_OK;
            }));
    options->Release();
    if (FAILED(started)) done->say("WebView2 could not start (" + hex(started) + ")");
}

}  // namespace

extern "C" int32_t bz_web_open(int32_t width, int32_t height, double scale, const char* agent, const char* awake) {
    auto view = std::make_shared<View>();
    view->scale = scale > 0 ? scale : GetDpiForSystem() / 96.0;
    const std::wstring a = wide(agent), s = wide(awake);
    const std::string failure = ask<std::string>(
        [view, width, height, a, s](Said<std::string> done) { create(view, width, height, a, s, done); },
        std::chrono::seconds(60), "WebView2 took too long to start");
    if (!failure.empty()) {
        lastError = failure;
        post([view] { letGo(*view); });
        return 0;
    }
    const int32_t id = ++counter;
    std::lock_guard<std::mutex> guard(viewsLock);
    views[id] = view;
    return id;
}

extern "C" int32_t bz_web_resize(int32_t id, int32_t width, int32_t height, const char* agent) {
    auto view = find(id);
    if (!view) return -1;
    const std::wstring a = wide(agent);
    return ask<int32_t>(
        [view, width, height, a](Said<int32_t> done) {
            place(*view, width, height);
            setAgent(*view, a);
            done->say(0);
        },
        std::chrono::seconds(20), -2);
}

extern "C" int32_t bz_web_load(int32_t id, const char* text, int32_t isHTML) {
    auto view = find(id);
    if (!view) return -1;
    {
        std::lock_guard<std::mutex> guard(view->lock);
        if (view->state != 3) view->state = 0;
        view->status = 0;
        view->error = 0;
        view->latest = 0;
    }
    const std::wstring t = wide(text);
    return ask<int32_t>(
        [view, t, isHTML](Said<int32_t> done) {
            if (!view->web) {
                done->say(-1);
                return;
            }
            const HRESULT hr = isHTML ? view->web->NavigateToString(t.c_str()) : view->web->Navigate(t.c_str());
            if (FAILED(hr)) {
                std::lock_guard<std::mutex> guard(view->lock);
                view->state = 2;
                view->error = 0;
            }
            done->say(FAILED(hr) ? -1 : 0);
        },
        std::chrono::seconds(20), -2);
}

extern "C" int32_t bz_web_state(int32_t id, int32_t* status, int32_t* error, int32_t* navigations) {
    auto view = find(id);
    if (!view) return 3;
    std::lock_guard<std::mutex> guard(view->lock);
    if (status) *status = view->status;
    if (error) *error = view->error;
    if (navigations) *navigations = view->navigations;
    return view->state;
}

extern "C" int32_t bz_web_call(int32_t id, const char* method, const char* params, int32_t timeout, char** answer) {
    if (answer) *answer = nullptr;
    auto view = find(id);
    if (!view) return -1;
    const std::wstring m = wide(method), p = wide(params && *params ? params : "{}");
    const Reply said = ask<Reply>(
        [view, m, p](Said<Reply> done) {
            if (!view->web) {
                done->say({-1, "{\"message\":\"The page is gone.\"}"});
                return;
            }
            auto answered = handler<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, HRESULT, LPCWSTR>(
                [done](HRESULT hr, LPCWSTR json) -> HRESULT {
                    done->say({FAILED(hr) ? 1 : 0, json ? narrow(json) : std::string("{}")});
                    return S_OK;
                });
            const HRESULT hr = view->web->CallDevToolsProtocolMethod(m.c_str(), p.c_str(), answered);
            answered->Release();
            if (FAILED(hr)) done->say({-1, "{\"message\":\"WebView2 refused the call (" + hex(hr) + ")\"}"});
        },
        std::chrono::milliseconds(timeout > 0 ? timeout : 60000), Reply{-2, "{\"message\":\"The page took too long to answer.\"}"});
    if (answer) *answer = copied(said.second);
    return said.first;
}

extern "C" void bz_web_close(int32_t id) {
    std::shared_ptr<View> view;
    {
        std::lock_guard<std::mutex> guard(viewsLock);
        auto it = views.find(id);
        if (it == views.end()) return;
        view = it->second;
        views.erase(it);
    }
    ask<int32_t>(
        [view](Said<int32_t> done) {
            letGo(*view);
            done->say(0);
        },
        std::chrono::seconds(10), -2);
}

extern "C" char* bz_web_error(void) { return copied(lastError); }

#endif
