// The subject matte Remove Background cuts pictures out with (the Swift side is Host/SubjectMatte.swift):
// BiRefNet run with ONNX Runtime, on the graphics card through DirectML or on the processor, as the
// Mac runs the same model with Core ML on its GPU or its processor. Which of the two, and at which
// of the model's sizes, the Swift side decides for each picture from what this PC is like, which it
// asks here too (`bz_matte_machine`, `bz_matte_memory`). ONNX Runtime and DirectML are DLLs beside
// Bezzle.exe (Windows/onnx.ps1 fetches them), loaded the first time a matte is wanted, so Bezzle
// starts no slower for them. Kept apart from host.cpp, whose Skia headers and windows.h do not mix.
// Built without them (no Packages\onnxruntime), every call says so.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "BezzleHost.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <mutex>
#include <string>
#include <vector>

namespace {

std::string lastError;
std::mutex lock;

void say(char* out, int32_t capacity, const std::string& s) {
    if (!out || capacity <= 0) return;
    const size_t n = std::min(s.size(), size_t(capacity - 1));
    std::memcpy(out, s.data(), n);
    out[n] = 0;
}

std::string utf8(const wchar_t* w) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring wide(const char* s) {
    const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
    return w;
}

/// The processor's cores but for its efficiency cores: those of the highest efficiency class
/// Windows tells of (a processor with one kind of core has them all in one class). Where Windows
/// does not say, every logical processor.
int32_t fastCores() {
    DWORD length = 0;
    GetLogicalProcessorInformationEx(RelationProcessorCore, nullptr, &length);
    std::vector<char> buffer(length);
    if (length > 0 && GetLogicalProcessorInformationEx(RelationProcessorCore, reinterpret_cast<SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX*>(buffer.data()), &length)) {
        int32_t counts[256] = {};
        int highest = 0;
        for (DWORD at = 0; at + sizeof(DWORD) * 2 <= length;) {
            const auto* info = reinterpret_cast<const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX*>(buffer.data() + at);
            if (info->Size == 0) break;
            if (info->Relationship == RelationProcessorCore) {
                const int kind = info->Processor.EfficiencyClass;
                counts[kind]++;
                highest = std::max(highest, kind);
            }
            at += info->Size;
        }
        if (counts[highest] > 0) return counts[highest];
    }
    SYSTEM_INFO system;
    GetSystemInfo(&system);
    return std::max<int32_t>(1, int32_t(system.dwNumberOfProcessors));
}

/// This PC's memory, in bytes, as much of it as Windows has the use of.
int64_t physicalMemory() {
    MEMORYSTATUSEX status = {};
    status.dwLength = sizeof(status);
    return GlobalMemoryStatusEx(&status) ? int64_t(status.ullTotalPhys) : 0;
}

}  // namespace

extern "C" int32_t bz_matte_memory(int32_t* load, int64_t* available) {
    MEMORYSTATUSEX status = {};
    status.dwLength = sizeof(status);
    const bool asked = GlobalMemoryStatusEx(&status) != 0;
    if (load) *load = asked ? int32_t(status.dwMemoryLoad) : 0;
    if (available) *available = asked ? int64_t(status.ullAvailPhys) : 0;
    return asked ? 1 : 0;
}

#if !BEZZLE_ONNX

extern "C" int32_t bz_matte_available(void) { return 0; }
extern "C" int32_t bz_matte_machine(int64_t* bytes, int32_t* cores, int64_t* dedicated, int32_t* software, char* name, int32_t capacity) {
    if (bytes) *bytes = physicalMemory();
    if (cores) *cores = fastCores();
    if (dedicated) *dedicated = 0;
    if (software) *software = 0;
    say(name, capacity, "");
    return 0;
}
extern "C" int32_t bz_matte_side(void*) { return 0; }
extern "C" void* bz_matte_open(const char*, int32_t, char* error, int32_t capacity, char* device, int32_t deviceCapacity) {
    say(error, capacity, "Bezzle was built without ONNX Runtime.");
    say(device, deviceCapacity, "");
    return nullptr;
}
extern "C" int32_t bz_matte_run(void*, const float*, int32_t, float*, char* error, int32_t capacity) {
    say(error, capacity, "Bezzle was built without ONNX Runtime.");
    return 1;
}
extern "C" int32_t bz_matte_device(void*, char* out, int32_t capacity) {
    say(out, capacity, "");
    return 0;
}
extern "C" void bz_matte_close(void*) {}

#else

#include <dxgi1_6.h>
#include <d3d12.h>
#include "dml_provider_factory.h"

namespace {

HMODULE runtime = nullptr;
const OrtApi* api = nullptr;
const OrtDmlApi* dml = nullptr;
OrtEnv* env = nullptr;

/// A file beside the running executable.
std::wstring beside(const wchar_t* name) {
    wchar_t path[MAX_PATH * 4];
    const DWORD n = GetModuleFileNameW(nullptr, path, DWORD(std::size(path)));
    std::wstring folder(path, n);
    const size_t slash = folder.find_last_of(L"\\/");
    return (slash == std::wstring::npos ? std::wstring() : folder.substr(0, slash + 1)) + name;
}

/// What went wrong, as ONNX Runtime says it; the status let go. Empty when nothing did.
std::string failed(OrtStatus* status) {
    if (!status) return {};
    std::string why = api->GetErrorMessage(status);
    api->ReleaseStatus(status);
    return why.empty() ? "ONNX Runtime failed." : why;
}

/// ONNX Runtime, loaded once, from beside Bezzle.exe: its dependencies (DirectML.dll) are looked
/// for there first, before Windows' own older DirectML.
bool load(std::string& why) {
    if (api) return true;
    if (!runtime) {
        const std::wstring path = beside(L"onnxruntime.dll");
        runtime = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!runtime) {
            why = "ONNX Runtime is not beside Bezzle (onnxruntime.dll, error " + std::to_string(GetLastError()) + ").";
            return false;
        }
    }
    using Base = const OrtApiBase*(ORT_API_CALL*)(void);
    const auto base = reinterpret_cast<Base>(GetProcAddress(runtime, "OrtGetApiBase"));
    const OrtApi* found = base ? base()->GetApi(ORT_API_VERSION) : nullptr;
    if (!found) {
        why = "The ONNX Runtime beside Bezzle is older than it needs.";
        return false;
    }
    api = found;
    if (const auto e = failed(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "Bezzle", &env)); !e.empty()) {
        why = e;
        api = nullptr;
        return false;
    }
    // ONNX Runtime's builds report to Windows' diagnostics unless told not to; Bezzle tells it not to.
    api->DisableTelemetryEvents(env);
    // DirectML's part, which a build of ONNX Runtime without it lacks.
    const void* provider = nullptr;
    if (failed(api->GetExecutionProviderApi("DML", ORT_API_VERSION, &provider)).empty()) dml = static_cast<const OrtDmlApi*>(provider);
    return true;
}

struct Adapter {
    int index = -1;
    std::string name;
    bool software = false;
    /// The memory it has of its own, in bytes: little or none where graphics share the PC's memory.
    uint64_t dedicated = 0;
};

/// The graphics adapter DirectML should run on: the one Windows calls the fastest, if Direct3D 12
/// runs on it; with `software`, Windows' own on the processor (WARP) when there is no other.
/// DirectML counts adapters as DXGI lists them.
Adapter adapter(bool software) {
    Adapter best;
    IDXGIFactory1* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)))) return best;
    LUID fastest = {};
    bool knowsFastest = false;
    IDXGIFactory6* six = nullptr;
    if (SUCCEEDED(factory->QueryInterface(__uuidof(IDXGIFactory6), reinterpret_cast<void**>(&six)))) {
        IDXGIAdapter1* a = nullptr;
        if (SUCCEEDED(six->EnumAdapterByGpuPreference(0, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, __uuidof(IDXGIAdapter1), reinterpret_cast<void**>(&a)))) {
            DXGI_ADAPTER_DESC1 d;
            if (SUCCEEDED(a->GetDesc1(&d))) {
                fastest = d.AdapterLuid;
                knowsFastest = true;
            }
            a->Release();
        }
        six->Release();
    }
    Adapter hardware, warp;
    IDXGIAdapter1* a = nullptr;
    for (UINT i = 0; factory->EnumAdapters1(i, &a) != DXGI_ERROR_NOT_FOUND; i++) {
        DXGI_ADAPTER_DESC1 d;
        const bool described = SUCCEEDED(a->GetDesc1(&d));
        // Whether Direct3D 12 runs on it at all (a display-only adapter, as a virtual machine's, does not).
        const bool runs = described && SUCCEEDED(D3D12CreateDevice(a, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), nullptr));
        a->Release();
        if (!runs) continue;
        // Software: so marked, or Windows' Basic Render Driver (Microsoft's 0x8C), as ONNX Runtime tells them.
        const bool software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 || (d.VendorId == 0x1414 && d.DeviceId == 0x8C);
        Adapter here{int(i), utf8(d.Description), software, uint64_t(d.DedicatedVideoMemory)};
        if (here.software) {
            if (warp.index < 0) warp = here;
        } else if (hardware.index < 0 || (knowsFastest && d.AdapterLuid.LowPart == fastest.LowPart && d.AdapterLuid.HighPart == fastest.HighPart)) {
            hardware = here;
        }
    }
    factory->Release();
    if (hardware.index >= 0) return hardware;
    return software ? warp : best;
}

struct Matte {
    OrtSession* session = nullptr;
    OrtMemoryInfo* memory = nullptr;
    /// The model, for opening it again on the processor.
    std::wstring file;
    /// Where it runs, in words; and whether on the graphics card, which may give up on a picture.
    std::string where;
    bool onCard = false;
    /// Opened for the graphics card alone: should the card give up, that is an error, and the
    /// processor does not take over here (who asked takes a lighter way).
    bool alone = false;
    /// The side of the square the graph takes its picture at; 0 where it takes any.
    int32_t side = 0;
};

/// DirectML on Windows' software adapter (WARP), on a Direct3D 12 device and queue made here, given
/// to ONNX Runtime, which holds them as long as the session. Empty when done, else why not.
std::string withOwnDevice(OrtSessionOptions* options) {
    static HMODULE directML = nullptr;
    if (!directML) directML = LoadLibraryExW(beside(L"DirectML.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    using Create = HRESULT(WINAPI*)(ID3D12Device*, DML_CREATE_DEVICE_FLAGS, REFIID, void**);
    const auto create = directML ? reinterpret_cast<Create>(GetProcAddress(directML, "DMLCreateDevice")) : nullptr;
    if (!create) return "DirectML.dll is not beside Bezzle.";
    IDXGIFactory4* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory4), reinterpret_cast<void**>(&factory)))) return "DXGI could not be reached.";
    IDXGIAdapter* warp = nullptr;
    const HRESULT found = factory->EnumWarpAdapter(__uuidof(IDXGIAdapter), reinterpret_cast<void**>(&warp));
    factory->Release();
    if (FAILED(found)) return "Windows has no software adapter here.";
    ID3D12Device* device = nullptr;
    const HRESULT made = D3D12CreateDevice(warp, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), reinterpret_cast<void**>(&device));
    warp->Release();
    if (FAILED(made)) return "Direct3D 12 does not run on the software adapter.";
    D3D12_COMMAND_QUEUE_DESC description = {};
    description.Type = D3D12_COMMAND_LIST_TYPE_COMPUTE;
    ID3D12CommandQueue* queue = nullptr;
    IDMLDevice* dmlDevice = nullptr;
    std::string why;
    if (FAILED(device->CreateCommandQueue(&description, __uuidof(ID3D12CommandQueue), reinterpret_cast<void**>(&queue)))) {
        why = "No command queue could be made.";
    } else if (FAILED(create(device, DML_CREATE_DEVICE_FLAG_NONE, __uuidof(IDMLDevice), reinterpret_cast<void**>(&dmlDevice)))) {
        why = "DirectML could not make its device.";
    } else {
        why = failed(dml->SessionOptionsAppendExecutionProvider_DML1(options, dmlDevice, queue));
    }
    if (dmlDevice) dmlDevice->Release();
    if (queue) queue->Release();
    device->Release();
    return why;
}

OrtSession* session(const std::wstring& path, const Adapter* on, std::string& why) {
    OrtSessionOptions* options = nullptr;
    if (why = failed(api->CreateSessionOptions(&options)); !why.empty()) return nullptr;
    OrtSession* made = nullptr;
    // On the processor, only the basic rewrites: the extended ones join half-precision nodes into
    // ones the processor has no half-precision kernels for (Gelu), where ONNX Runtime otherwise
    // runs each half-precision node in full precision by casting round it.
    why = failed(api->SetSessionGraphOptimizationLevel(options, on ? ORT_ENABLE_ALL : ORT_ENABLE_BASIC));
    // On the processor the model needs gigabytes while it runs: given back to Windows after each
    // picture, rather than kept for the next in ONNX Runtime's arena while Bezzle goes on.
    if (why.empty() && !on) why = failed(api->DisableCpuMemArena(options));
    if (why.empty() && on) {
        // As DirectML needs: one node after another, and no memory planned ahead.
        why = failed(api->DisableMemPattern(options));
        if (why.empty()) why = failed(api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
        if (why.empty() && on->software) {
            // ONNX Runtime refuses Windows' software adapter by its number, as slower than its own
            // way on the processor; given a device made on it here, it takes it (for trying DirectML
            // where there is no graphics card, as in a virtual machine). Node by node, not fused into
            // one graph: the software adapter's memory does not hold the whole graph at 2,048 pixels.
            why = failed(api->AddSessionConfigEntry(options, "ep.dml.disable_graph_fusion", "1"));
            if (why.empty()) why = withOwnDevice(options);
        } else if (why.empty()) {
            why = failed(dml->SessionOptionsAppendExecutionProvider_DML(options, on->index));
        }
    }
    if (why.empty()) why = failed(api->CreateSession(env, path.c_str(), options, &made));
    api->ReleaseSessionOptions(options);
    return why.empty() ? made : nullptr;
}

/// The side of the square the model of `session` takes its picture at, as its graph says; 0 where
/// it takes any size, or does not say.
int32_t squareSide(OrtSession* session) {
    OrtTypeInfo* type = nullptr;
    if (!failed(api->SessionGetInputTypeInfo(session, 0, &type)).empty() || !type) return 0;
    // The shape belongs to `type`, and goes with it.
    const OrtTensorTypeAndShapeInfo* shape = nullptr;
    int64_t dimensions[4] = {0, 0, 0, 0};
    size_t count = 0;
    std::string why = failed(api->CastTypeInfoToTensorInfo(type, &shape));
    if (why.empty() && shape) why = failed(api->GetDimensionsCount(shape, &count));
    if (why.empty() && shape && count == 4) why = failed(api->GetDimensions(shape, dimensions, 4));
    api->ReleaseTypeInfo(type);
    return why.empty() && dimensions[2] > 0 && dimensions[2] == dimensions[3] && dimensions[2] <= 16384 ? int32_t(dimensions[2]) : 0;
}

}  // namespace

extern "C" int32_t bz_matte_machine(int64_t* bytes, int32_t* cores, int64_t* dedicated, int32_t* software, char* name, int32_t capacity) {
    if (bytes) *bytes = physicalMemory();
    if (cores) *cores = fastCores();
    // The adapter a matte would run on: the fastest Direct3D 12 runs on, or none.
    const Adapter on = adapter(false);
    if (dedicated) *dedicated = on.index >= 0 ? int64_t(on.dedicated) : 0;
    if (software) *software = on.software ? 1 : 0;
    say(name, capacity, on.name);
    return on.index >= 0 ? 1 : 0;
}

extern "C" int32_t bz_matte_available(void) {
    std::lock_guard<std::mutex> guard(lock);
    std::string why;
    return load(why) ? (dml ? 2 : 1) : 0;
}

extern "C" void* bz_matte_open(const char* path, int32_t device, char* error, int32_t capacity, char* device_out, int32_t deviceCapacity) {
    std::lock_guard<std::mutex> guard(lock);
    std::string why;
    say(device_out, deviceCapacity, "");
    if (!load(why)) {
        say(error, capacity, why);
        return nullptr;
    }
    const std::wstring file = wide(path);
    OrtSession* made = nullptr;
    std::string where;
    // 0: the graphics card if it can, else the processor; 1: the processor; 2: DirectML on any
    // adapter, Windows' software one too (for trying it where there is no other); 3: the graphics
    // card. With 2 and 3 it is the card alone: one that cannot is an error, now and in any run
    // after, and who asked decides what to take instead (a lighter way, Host/SubjectMatte.swift).
    const bool alone = device == 2 || device == 3;
    if (alone && !dml) {
        say(error, capacity, "The ONNX Runtime beside Bezzle has no DirectML.");
        return nullptr;
    }
    if (device != 1 && dml) {
        const Adapter on = adapter(device == 2);
        if (on.index >= 0) {
            std::string refused;
            made = session(file, &on, refused);
            if (made) {
                where = "DirectML on " + on.name;
            } else if (alone) {
                say(error, capacity, refused);
                return nullptr;
            } else {
                where = "processor (DirectML on " + on.name + " could not: " + refused + ")";
            }
        } else if (alone) {
            say(error, capacity, "No graphics adapter here runs Direct3D 12.");
            return nullptr;
        }
    }
    if (!made) {
        made = session(file, nullptr, why);
        if (!made) {
            say(error, capacity, why);
            return nullptr;
        }
        if (where.empty()) where = "processor";
    }
    auto* matte = new Matte;
    matte->session = made;
    matte->file = file;
    matte->where = where;
    matte->onCard = where.rfind("DirectML", 0) == 0;
    matte->alone = alone;
    matte->side = squareSide(made);
    if (why = failed(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &matte->memory)); !why.empty()) {
        api->ReleaseSession(made);
        delete matte;
        say(error, capacity, why);
        return nullptr;
    }
    say(device_out, deviceCapacity, where);
    return matte;
}

extern "C" int32_t bz_matte_run(void* handle, const float* input, int32_t side, float* output, char* error, int32_t capacity) {
    auto* matte = static_cast<Matte*>(handle);
    if (!matte || !api) {
        say(error, capacity, "No subject matte is open.");
        return 1;
    }
    // One picture at a time: the model is large, and two at once only slow each other.
    std::lock_guard<std::mutex> guard(lock);
    const int64_t shape[4] = {1, 3, side, side};
    const size_t count = size_t(3) * side * side;
    OrtValue* in = nullptr;
    std::string why = failed(api->CreateTensorWithDataAsOrtValue(matte->memory, const_cast<float*>(input), count * sizeof(float), shape, 4,
                                                                 ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in));
    if (!why.empty()) {
        say(error, capacity, why);
        return 2;
    }
    const char* inputs[] = {"image"};
    const char* outputs[] = {"matte"};
    OrtValue* out = nullptr;
    // On the processor, a session for each picture, let go once it is done (below): one kept from
    // picture to picture held on to the gigabytes the model needs there, and more with each picture.
    if (!matte->session) matte->session = session(matte->file, nullptr, why);
    if (!matte->session) {
        api->ReleaseValue(in);
        say(error, capacity, why);
        return 5;
    }
    why = failed(api->Run(matte->session, nullptr, inputs, &in, 1, outputs, 1, &out));
    if (!why.empty() && matte->onCard && !matte->alone) {
        // The graphics card gave up on it (its memory too small for the model at 2,048 pixels, as
        // Windows' software adapter's is, or the card lost): from now on on the processor. Not
        // where it was opened for the card alone: the error below is the answer then.
        std::string again;
        if (OrtSession* cpu = session(matte->file, nullptr, again)) {
            api->ReleaseSession(matte->session);
            matte->session = cpu;
            matte->onCard = false;
            matte->where = "processor (" + matte->where + " gave up: " + why.substr(0, 160) + ")";
            why = failed(api->Run(matte->session, nullptr, inputs, &in, 1, outputs, 1, &out));
        }
    }
    api->ReleaseValue(in);
    if (!why.empty()) {
        say(error, capacity, why);
        return 3;
    }
    OrtTensorTypeAndShapeInfo* info = nullptr;
    size_t dimensions = 0;
    int64_t got[4] = {0, 0, 0, 0};
    why = failed(api->GetTensorTypeAndShape(out, &info));
    if (why.empty()) why = failed(api->GetDimensionsCount(info, &dimensions));
    if (why.empty() && dimensions == 4) why = failed(api->GetDimensions(info, got, 4));
    if (info) api->ReleaseTensorTypeAndShapeInfo(info);
    float* values = nullptr;
    if (why.empty() && (dimensions != 4 || got[2] != side || got[3] != side)) why = "The matte came out another size.";
    if (why.empty()) why = failed(api->GetTensorMutableData(out, reinterpret_cast<void**>(&values)));
    if (why.empty()) std::memcpy(output, values, size_t(side) * side * sizeof(float));
    api->ReleaseValue(out);
    if (!matte->onCard) {
        api->ReleaseSession(matte->session);
        matte->session = nullptr;
    }
    if (!why.empty()) {
        say(error, capacity, why);
        return 4;
    }
    return 0;
}

extern "C" int32_t bz_matte_side(void* handle) {
    const auto* matte = static_cast<const Matte*>(handle);
    return matte ? matte->side : 0;
}

extern "C" int32_t bz_matte_device(void* handle, char* out, int32_t capacity) {
    auto* matte = static_cast<Matte*>(handle);
    if (!matte) return 0;
    std::lock_guard<std::mutex> guard(lock);
    say(out, capacity, matte->where);
    return matte->onCard ? 1 : 0;
}

extern "C" void bz_matte_close(void* handle) {
    auto* matte = static_cast<Matte*>(handle);
    if (!matte) return;
    std::lock_guard<std::mutex> guard(lock);
    if (matte->session) api->ReleaseSession(matte->session);
    if (matte->memory) api->ReleaseMemoryInfo(matte->memory);
    delete matte;
}

#endif
