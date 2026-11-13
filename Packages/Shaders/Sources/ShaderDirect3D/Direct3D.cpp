// Bezzle's own: Direct3D 11 for the shader engine on Windows (see include/ShaderDirect3D.h). The
// device is the graphics card's, or WARP, Windows' own on the processor, where there is none (as
// in a virtual machine). Its context is used by one call at a time; programs, layouts, states and
// textures may be made from any thread.

#include "ShaderDirect3D.h"

#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

template <typename T> void release(T *&object)
{
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

/// What Swift holds and lets go of with bz_d3d_release, and which of them it is.
struct Object {
    enum Kind { com, program, texture };
    const Kind kind;
    explicit Object(Kind kind) : kind(kind) {}
    virtual ~Object() = default;
};

/// A layout, state or sampler.
struct Com : Object {
    IUnknown *object = nullptr;
    explicit Com(IUnknown *object) : Object(Object::com), object(object) {}
    ~Com() override { release(object); }
};

struct Program : Object {
    Program() : Object(Object::program) {}
    ID3D11VertexShader *vertex = nullptr;
    ID3D11PixelShader *pixel = nullptr;
    ID3D11GeometryShader *points = nullptr;
    ID3D11GeometryShader *lines = nullptr;
    /// Kept to make input layouts against.
    ID3DBlob *vertexCode = nullptr;
    ~Program() override
    {
        release(vertex);
        release(pixel);
        release(points);
        release(lines);
        release(vertexCode);
    }
};

struct Texture : Object {
    Texture() : Object(Object::texture) {}
    ID3D11Texture2D *texture = nullptr;
    ID3D11ShaderResourceView *view = nullptr;
    ~Texture() override
    {
        release(view);
        release(texture);
    }
};

char *copyString(const std::string &text)
{
    char *result = static_cast<char *>(std::malloc(text.size() + 1));
    if (result != nullptr)
        std::memcpy(result, text.c_str(), text.size() + 1);
    return result;
}

void say(char **log, const std::string &text)
{
    if (log != nullptr)
        *log = copyString(text);
}

std::string hex(HRESULT result)
{
    char text[16];
    std::snprintf(text, sizeof text, "0x%08lX", static_cast<unsigned long>(result));
    return text;
}

/// HLSL to bytecode with Windows' own compiler (d3dcompiler_47), IEEE arithmetic kept as Metal's
/// safe math keeps it.
bool compile(const char *source, const char *target, ID3DBlob **code, std::string &log)
{
    ID3DBlob *errors = nullptr;
    const UINT flags = D3DCOMPILE_IEEE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL1;
    const HRESULT result =
        D3DCompile(source, std::strlen(source), nullptr, nullptr, nullptr, "main", target, flags, 0, code, &errors);
    if (errors != nullptr) {
        log.append(static_cast<const char *>(errors->GetBufferPointer()), errors->GetBufferSize());
        errors->Release();
    }
    if (FAILED(result)) {
        if (log.empty())
            log = "Direct3D: the " + std::string(target) + " stage did not compile (" + hex(result) + ").";
        return false;
    }
    return true;
}

const char *coverSource = "float4 main(uint id : SV_VertexID) : SV_Position {\n"
                          "    float2 p = float2(float((id << 1) & 2), float(id & 2));\n"
                          "    return float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
                          "}\n";
const char *blackSource = "float4 main() : SV_Target { return float4(0.0, 0.0, 0.0, 1.0); }\n";

DXGI_FORMAT format(int base, int width)
{
    static const DXGI_FORMAT formats[3][4] = {
        {DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT},
        {DXGI_FORMAT_R32_SINT, DXGI_FORMAT_R32G32_SINT, DXGI_FORMAT_R32G32B32_SINT, DXGI_FORMAT_R32G32B32A32_SINT},
        {DXGI_FORMAT_R32_UINT, DXGI_FORMAT_R32G32_UINT, DXGI_FORMAT_R32G32B32_UINT, DXGI_FORMAT_R32G32B32A32_UINT},
    };
    const int b = base < 0 || base > 2 ? 0 : base;
    const int w = width < 1 ? 1 : width > 4 ? 4 : width;
    return formats[b][w - 1];
}

/// A blend factor in the order of ShaderDraw.Blend.Factor. Direct3D takes no colour factor for
/// alpha, so there the colour's are its alpha's, which is what they come to; and it has one blend
/// constant, which Swift gives as the alpha for the constant alpha factors.
D3D11_BLEND factor(int value, bool alpha)
{
    switch (value) {
    case 0: return D3D11_BLEND_ZERO;
    case 1: return D3D11_BLEND_ONE;
    case 2: return alpha ? D3D11_BLEND_SRC_ALPHA : D3D11_BLEND_SRC_COLOR;
    case 3: return alpha ? D3D11_BLEND_INV_SRC_ALPHA : D3D11_BLEND_INV_SRC_COLOR;
    case 4: return alpha ? D3D11_BLEND_DEST_ALPHA : D3D11_BLEND_DEST_COLOR;
    case 5: return alpha ? D3D11_BLEND_INV_DEST_ALPHA : D3D11_BLEND_INV_DEST_COLOR;
    case 6: return D3D11_BLEND_SRC_ALPHA;
    case 7: return D3D11_BLEND_INV_SRC_ALPHA;
    case 8: return D3D11_BLEND_DEST_ALPHA;
    case 9: return D3D11_BLEND_INV_DEST_ALPHA;
    case 10:
    case 12: return D3D11_BLEND_BLEND_FACTOR;
    case 11:
    case 13: return D3D11_BLEND_INV_BLEND_FACTOR;
    case 14: return D3D11_BLEND_SRC_ALPHA_SAT;
    default: return D3D11_BLEND_ONE;
    }
}

D3D11_BLEND_OP operation(int value)
{
    switch (value) {
    case 1: return D3D11_BLEND_OP_SUBTRACT;
    case 2: return D3D11_BLEND_OP_REV_SUBTRACT;
    case 3: return D3D11_BLEND_OP_MIN;
    case 4: return D3D11_BLEND_OP_MAX;
    default: return D3D11_BLEND_OP_ADD;
    }
}

D3D11_TEXTURE_ADDRESS_MODE address(int wrap)
{
    return wrap == 0 ? D3D11_TEXTURE_ADDRESS_WRAP : wrap == 2 ? D3D11_TEXTURE_ADDRESS_MIRROR : D3D11_TEXTURE_ADDRESS_CLAMP;
}

} // namespace

struct BZD3D {
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    std::mutex lock;
    /// Without and with multisampling.
    ID3D11RasterizerState *raster[2] = {};
    ID3D11VertexShader *cover = nullptr;
    ID3D11PixelShader *black = nullptr;
    ID3D11BlendState *opaque = nullptr;
    ID3D11BlendState *premultiply = nullptr;
    /// The last frame's targets, kept for the next of the same size.
    int width = 0, height = 0, samples = 0;
    ID3D11Texture2D *target = nullptr;
    ID3D11Texture2D *multisampled = nullptr;
    ID3D11Texture2D *staging = nullptr;
    ID3D11RenderTargetView *view = nullptr;

    void dropTargets()
    {
        release(view);
        release(target);
        release(multisampled);
        release(staging);
        width = height = samples = 0;
    }

    bool targets(int w, int h, int count, std::string &why)
    {
        if (w == width && h == height && count == samples && view != nullptr)
            return true;
        dropTargets();
        D3D11_TEXTURE2D_DESC description = {};
        description.Width = static_cast<UINT>(w);
        description.Height = static_cast<UINT>(h);
        description.MipLevels = 1;
        description.ArraySize = 1;
        description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        description.SampleDesc.Count = 1;
        description.Usage = D3D11_USAGE_DEFAULT;
        description.BindFlags = D3D11_BIND_RENDER_TARGET;
        HRESULT result = device->CreateTexture2D(&description, nullptr, &target);
        if (SUCCEEDED(result) && count > 1) {
            D3D11_TEXTURE2D_DESC many = description;
            many.SampleDesc.Count = static_cast<UINT>(count);
            many.SampleDesc.Quality = D3D11_STANDARD_MULTISAMPLE_PATTERN;
            result = device->CreateTexture2D(&many, nullptr, &multisampled);
        }
        if (SUCCEEDED(result)) {
            D3D11_TEXTURE2D_DESC read = description;
            read.Usage = D3D11_USAGE_STAGING;
            read.BindFlags = 0;
            read.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            result = device->CreateTexture2D(&read, nullptr, &staging);
        }
        if (SUCCEEDED(result))
            result = device->CreateRenderTargetView(count > 1 ? multisampled : target, nullptr, &view);
        if (FAILED(result)) {
            dropTargets();
            why = "Direct3D: out of memory for a picture of " + std::to_string(w) + " by " + std::to_string(h) + " (" +
                  hex(result) + ").";
            return false;
        }
        width = w;
        height = h;
        samples = count;
        return true;
    }

    ~BZD3D()
    {
        dropTargets();
        release(raster[0]);
        release(raster[1]);
        release(cover);
        release(black);
        release(opaque);
        release(premultiply);
        release(context);
        release(device);
    }
};

extern "C" BZD3D *bz_d3d_open(int software, char *adapter, int capacity)
{
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    HRESULT result = E_FAIL;
    bool warp = false;
    if (!software) {
        result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels, 2, D3D11_SDK_VERSION, &device,
                                   &level, &context);
        if (result == E_INVALIDARG) // a runtime that knows no 11.1
            result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels + 1, 1, D3D11_SDK_VERSION,
                                       &device, &level, &context);
    }
    if (FAILED(result)) {
        warp = true;
        result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, levels, 2, D3D11_SDK_VERSION, &device,
                                   &level, &context);
        if (result == E_INVALIDARG)
            result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, levels + 1, 1, D3D11_SDK_VERSION,
                                       &device, &level, &context);
    }
    if (FAILED(result))
        return nullptr;

    BZD3D *d3d = new BZD3D;
    d3d->device = device;
    d3d->context = context;

    std::string name = warp ? "WARP" : "";
    IDXGIDevice *dxgi = nullptr;
    if (!warp && SUCCEEDED(device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgi)))) {
        IDXGIAdapter *card = nullptr;
        DXGI_ADAPTER_DESC description = {};
        if (SUCCEEDED(dxgi->GetAdapter(&card)) && SUCCEEDED(card->GetDesc(&description))) {
            char text[256] = {};
            WideCharToMultiByte(CP_UTF8, 0, description.Description, -1, text, sizeof text - 1, nullptr, nullptr);
            name = text;
        }
        release(card);
        release(dxgi);
    }
    if (adapter != nullptr && capacity > 0) {
        std::strncpy(adapter, name.c_str(), static_cast<size_t>(capacity - 1));
        adapter[capacity - 1] = 0;
    }

    for (int i = 0; i < 2; i++) {
        D3D11_RASTERIZER_DESC raster = {};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.FrontCounterClockwise = TRUE; // as WebGL: counter-clockwise faces the front
        raster.DepthClipEnable = TRUE;
        raster.ScissorEnable = TRUE;
        raster.MultisampleEnable = i == 1 ? TRUE : FALSE;
        device->CreateRasterizerState(&raster, &d3d->raster[i]);
    }
    std::string log;
    ID3DBlob *code = nullptr;
    if (compile(coverSource, "vs_5_0", &code, log)) {
        device->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &d3d->cover);
        release(code);
    }
    if (compile(blackSource, "ps_5_0", &code, log)) {
        device->CreatePixelShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &d3d->black);
        release(code);
    }
    // Alpha made 1, or the colours multiplied by it, by blending alone.
    D3D11_BLEND_DESC blend = {};
    blend.RenderTarget[0].BlendEnable = FALSE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_ZERO;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALPHA;
    device->CreateBlendState(&blend, &d3d->opaque);
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ZERO;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_DEST_ALPHA;
    blend.RenderTarget[0].RenderTargetWriteMask =
        D3D11_COLOR_WRITE_ENABLE_RED | D3D11_COLOR_WRITE_ENABLE_GREEN | D3D11_COLOR_WRITE_ENABLE_BLUE;
    device->CreateBlendState(&blend, &d3d->premultiply);
    if (d3d->raster[0] == nullptr || d3d->raster[1] == nullptr || d3d->cover == nullptr || d3d->black == nullptr ||
        d3d->opaque == nullptr || d3d->premultiply == nullptr) {
        delete d3d;
        return nullptr;
    }
    return d3d;
}

extern "C" void bz_d3d_close(BZD3D *d3d)
{
    delete d3d;
}

extern "C" int bz_d3d_samples(BZD3D *d3d, int count)
{
    UINT levels = 0;
    return SUCCEEDED(d3d->device->CheckMultisampleQualityLevels(DXGI_FORMAT_R8G8B8A8_UNORM, static_cast<UINT>(count),
                                                                 &levels)) &&
           levels > 0;
}

extern "C" void *bz_d3d_program(BZD3D *d3d, const char *vertex, const char *pixel, const char *points,
                                const char *lines, char **log, double *seconds)
{
    const auto start = std::chrono::steady_clock::now();
    std::string why;
    Program *program = new Program;
    ID3DBlob *pixelCode = nullptr, *pointsCode = nullptr, *linesCode = nullptr;
    bool ok = compile(vertex, "vs_5_0", &program->vertexCode, why) && compile(pixel, "ps_5_0", &pixelCode, why) &&
              (points == nullptr || compile(points, "gs_5_0", &pointsCode, why)) &&
              (lines == nullptr || compile(lines, "gs_5_0", &linesCode, why));
    if (ok) {
        HRESULT result = d3d->device->CreateVertexShader(program->vertexCode->GetBufferPointer(),
                                                         program->vertexCode->GetBufferSize(), nullptr, &program->vertex);
        if (SUCCEEDED(result))
            result = d3d->device->CreatePixelShader(pixelCode->GetBufferPointer(), pixelCode->GetBufferSize(), nullptr,
                                                    &program->pixel);
        if (SUCCEEDED(result) && pointsCode != nullptr)
            result = d3d->device->CreateGeometryShader(pointsCode->GetBufferPointer(), pointsCode->GetBufferSize(),
                                                       nullptr, &program->points);
        if (SUCCEEDED(result) && linesCode != nullptr)
            result = d3d->device->CreateGeometryShader(linesCode->GetBufferPointer(), linesCode->GetBufferSize(),
                                                       nullptr, &program->lines);
        if (FAILED(result)) {
            why = "Direct3D: the program does not build (" + hex(result) + ").";
            ok = false;
        }
    }
    release(pixelCode);
    release(pointsCode);
    release(linesCode);
    if (seconds != nullptr)
        *seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    if (!ok) {
        delete program;
        say(log, why);
        return nullptr;
    }
    return static_cast<Object *>(program);
}

extern "C" void *bz_d3d_layout(BZD3D *d3d, void *program, const BZD3DElement *elements, int32_t count, char **log)
{
    Object *object = static_cast<Object *>(program);
    Program *owner = object != nullptr && object->kind == Object::program ? static_cast<Program *>(object) : nullptr;
    if (owner == nullptr || count <= 0) {
        say(log, "Direct3D: no attributes to lay out.");
        return nullptr;
    }
    std::vector<D3D11_INPUT_ELEMENT_DESC> descriptions;
    for (int32_t i = 0; i < count; i++) {
        const BZD3DElement &element = elements[i];
        D3D11_INPUT_ELEMENT_DESC description = {};
        description.SemanticName = "TEXCOORD";
        description.SemanticIndex = static_cast<UINT>(element.location);
        description.Format = format(element.base, element.width);
        description.InputSlot = static_cast<UINT>(element.slot);
        description.AlignedByteOffset = static_cast<UINT>(element.offset);
        description.InputSlotClass = element.constant ? D3D11_INPUT_PER_INSTANCE_DATA : D3D11_INPUT_PER_VERTEX_DATA;
        description.InstanceDataStepRate = element.constant ? 1 : 0;
        descriptions.push_back(description);
    }
    ID3D11InputLayout *layout = nullptr;
    const HRESULT result = d3d->device->CreateInputLayout(descriptions.data(), static_cast<UINT>(descriptions.size()),
                                                          owner->vertexCode->GetBufferPointer(),
                                                          owner->vertexCode->GetBufferSize(), &layout);
    if (FAILED(result)) {
        say(log, "Direct3D: the attributes do not fit the vertex stage (" + hex(result) + ").");
        return nullptr;
    }
    return static_cast<Object *>(new Com(layout));
}

extern "C" void *bz_d3d_blend(BZD3D *d3d, const int32_t *factors)
{
    D3D11_BLEND_DESC description = {};
    D3D11_RENDER_TARGET_BLEND_DESC &target = description.RenderTarget[0];
    target.BlendEnable = TRUE;
    target.SrcBlend = factor(factors[0], false);
    target.DestBlend = factor(factors[1], false);
    target.SrcBlendAlpha = factor(factors[2], true);
    target.DestBlendAlpha = factor(factors[3], true);
    target.BlendOp = operation(factors[4]);
    target.BlendOpAlpha = operation(factors[5]);
    target.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    ID3D11BlendState *state = nullptr;
    if (FAILED(d3d->device->CreateBlendState(&description, &state)))
        return nullptr;
    return static_cast<Object *>(new Com(state));
}

extern "C" void *bz_d3d_sampler(BZD3D *d3d, int32_t wrapS, int32_t wrapT, int32_t magnify, int32_t minify,
                                int32_t mipmap)
{
    D3D11_SAMPLER_DESC description = {};
    description.Filter =
        static_cast<D3D11_FILTER>((minify == 1 ? 0x10 : 0) | (magnify == 1 ? 0x4 : 0) | (mipmap == 1 ? 0x1 : 0));
    description.AddressU = address(wrapS);
    description.AddressV = address(wrapT);
    description.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    description.MaxAnisotropy = 1;
    description.ComparisonFunc = D3D11_COMPARISON_NEVER;
    description.MinLOD = 0;
    // Without mipmaps only the first level is read, whatever the texture has.
    description.MaxLOD = mipmap < 0 ? 0 : D3D11_FLOAT32_MAX;
    ID3D11SamplerState *state = nullptr;
    if (FAILED(d3d->device->CreateSamplerState(&description, &state)))
        return nullptr;
    return static_cast<Object *>(new Com(state));
}

extern "C" void *bz_d3d_texture(BZD3D *d3d, int32_t width, int32_t height, const void *rgba, int32_t cube,
                                int32_t mipmaps)
{
    if (width <= 0 || height <= 0 || (cube && width != height))
        return nullptr;
    const UINT slices = cube ? 6 : 1;
    const UINT pitch = static_cast<UINT>(width) * 4;
    const UINT face = pitch * static_cast<UINT>(height);
    D3D11_TEXTURE2D_DESC description = {};
    description.Width = static_cast<UINT>(width);
    description.Height = static_cast<UINT>(height);
    description.MipLevels = mipmaps ? 0 : 1;
    description.ArraySize = slices;
    description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = mipmaps ? D3D11_USAGE_DEFAULT : D3D11_USAGE_IMMUTABLE;
    description.BindFlags = D3D11_BIND_SHADER_RESOURCE | (mipmaps ? D3D11_BIND_RENDER_TARGET : 0);
    description.MiscFlags = (cube ? D3D11_RESOURCE_MISC_TEXTURECUBE : 0) | (mipmaps ? D3D11_RESOURCE_MISC_GENERATE_MIPS : 0);
    std::vector<D3D11_SUBRESOURCE_DATA> data(slices);
    for (UINT slice = 0; slice < slices; slice++) {
        data[slice].pSysMem = static_cast<const uint8_t *>(rgba) + slice * face;
        data[slice].SysMemPitch = pitch;
        data[slice].SysMemSlicePitch = face;
    }
    Texture *texture = new Texture;
    HRESULT result = d3d->device->CreateTexture2D(&description, mipmaps ? nullptr : data.data(), &texture->texture);
    if (SUCCEEDED(result)) {
        D3D11_SHADER_RESOURCE_VIEW_DESC view = {};
        view.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        if (cube) {
            view.ViewDimension = D3D11_SRV_DIMENSION_TEXTURECUBE;
            view.TextureCube.MipLevels = static_cast<UINT>(-1);
        } else {
            view.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
            view.Texture2D.MipLevels = static_cast<UINT>(-1);
        }
        result = d3d->device->CreateShaderResourceView(texture->texture, &view, &texture->view);
    }
    if (FAILED(result)) {
        delete texture;
        return nullptr;
    }
    if (mipmaps) {
        D3D11_TEXTURE2D_DESC made = {};
        texture->texture->GetDesc(&made);
        std::lock_guard<std::mutex> guard(d3d->lock);
        for (UINT slice = 0; slice < slices; slice++)
            d3d->context->UpdateSubresource(texture->texture, D3D11CalcSubresource(0, slice, made.MipLevels), nullptr,
                                            data[slice].pSysMem, pitch, face);
        d3d->context->GenerateMips(texture->view);
    }
    return static_cast<Object *>(texture);
}

extern "C" void bz_d3d_release(void *object)
{
    delete static_cast<Object *>(object);
}

extern "C" void bz_d3d_free(char *text)
{
    std::free(text);
}

namespace {

/// What a handle Swift gave holds, when it is of that kind.
template <typename T> T *held(void *object, Object::Kind kind)
{
    Object *o = static_cast<Object *>(object);
    return o != nullptr && o->kind == kind ? static_cast<T *>(o) : nullptr;
}

template <typename T> T *com(void *object)
{
    Com *c = held<Com>(object, Object::com);
    return c == nullptr ? nullptr : static_cast<T *>(c->object);
}

ID3D11Buffer *buffer(ID3D11Device *device, UINT bind, const void *bytes, int32_t count)
{
    if (bytes == nullptr || count <= 0)
        return nullptr;
    D3D11_BUFFER_DESC description = {};
    description.ByteWidth = static_cast<UINT>(count);
    description.Usage = D3D11_USAGE_IMMUTABLE;
    description.BindFlags = bind;
    D3D11_SUBRESOURCE_DATA data = {};
    data.pSysMem = bytes;
    ID3D11Buffer *made = nullptr;
    device->CreateBuffer(&description, &data, &made);
    return made;
}

} // namespace

extern "C" int bz_d3d_draw(BZD3D *d3d, const BZD3DFrame *frame, void *pixels, char **log)
{
    std::lock_guard<std::mutex> guard(d3d->lock);
    std::string why;
    const int width = frame->width, height = frame->height;
    if (width <= 0 || height <= 0 || !d3d->targets(width, height, frame->samples, why)) {
        say(log, why.empty() ? "Direct3D: no picture can be that size." : why);
        return 0;
    }
    ID3D11DeviceContext *context = d3d->context;
    context->ClearState();
    context->OMSetRenderTargets(1, &d3d->view, nullptr);
    D3D11_VIEWPORT viewport = {0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1};
    context->RSSetViewports(1, &viewport);
    context->RSSetState(d3d->raster[frame->samples > 1 ? 1 : 0]);
    context->ClearRenderTargetView(d3d->view, frame->clear);

    std::vector<ID3D11Buffer *> made;
    auto keep = [&made](ID3D11Buffer *b) {
        if (b != nullptr)
            made.push_back(b);
        return b;
    };
    bool ok = true;
    for (int32_t d = 0; d < frame->drawCount && ok; d++) {
        const BZD3DDraw &draw = frame->draws[d];
        Program *program = held<Program>(draw.program, Object::program);
        if (program == nullptr) {
            why = "Direct3D: a draw without its program.";
            ok = false;
            break;
        }
        context->IASetInputLayout(draw.layout != nullptr ? com<ID3D11InputLayout>(draw.layout) : nullptr);
        static const D3D11_PRIMITIVE_TOPOLOGY topologies[] = {
            D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
            D3D11_PRIMITIVE_TOPOLOGY_LINELIST, D3D11_PRIMITIVE_TOPOLOGY_LINESTRIP, D3D11_PRIMITIVE_TOPOLOGY_POINTLIST};
        const int topology = draw.topology < 0 || draw.topology > 4 ? 0 : draw.topology;
        context->IASetPrimitiveTopology(topologies[topology]);
        for (int32_t i = 0; i < draw.vertexBufferCount; i++) {
            const BZD3DBytes &vertices = draw.vertices[i];
            ID3D11Buffer *b = keep(buffer(d3d->device, D3D11_BIND_VERTEX_BUFFER, vertices.bytes, vertices.count));
            const UINT stride = static_cast<UINT>(vertices.stride), offset = 0;
            if (b != nullptr)
                context->IASetVertexBuffers(static_cast<UINT>(vertices.slot), 1, &b, &stride, &offset);
        }
        if (draw.indices != nullptr) {
            ID3D11Buffer *b =
                keep(buffer(d3d->device, D3D11_BIND_INDEX_BUFFER, draw.indices, draw.indexCount * 4));
            if (b == nullptr) {
                why = "Direct3D: no index buffer.";
                ok = false;
                break;
            }
            context->IASetIndexBuffer(b, DXGI_FORMAT_R32_UINT, 0);
        }
        for (int32_t i = 0; i < draw.vertexConstantCount; i++) {
            const BZD3DBytes &constants = draw.vertexConstants[i];
            ID3D11Buffer *b = keep(buffer(d3d->device, D3D11_BIND_CONSTANT_BUFFER, constants.bytes, constants.count));
            context->VSSetConstantBuffers(static_cast<UINT>(constants.slot), 1, &b);
        }
        for (int32_t i = 0; i < draw.pixelConstantCount; i++) {
            const BZD3DBytes &constants = draw.pixelConstants[i];
            ID3D11Buffer *b = keep(buffer(d3d->device, D3D11_BIND_CONSTANT_BUFFER, constants.bytes, constants.count));
            context->PSSetConstantBuffers(static_cast<UINT>(constants.slot), 1, &b);
        }
        for (int32_t i = 0; i < draw.vertexTextureCount; i++) {
            const BZD3DTexture &t = draw.vertexTextures[i];
            Texture *texture = held<Texture>(t.texture, Object::texture);
            ID3D11SamplerState *sampler = com<ID3D11SamplerState>(t.sampler);
            ID3D11ShaderResourceView *view = texture != nullptr ? texture->view : nullptr;
            context->VSSetShaderResources(static_cast<UINT>(t.slot), 1, &view);
            context->VSSetSamplers(static_cast<UINT>(t.slot), 1, &sampler);
        }
        for (int32_t i = 0; i < draw.pixelTextureCount; i++) {
            const BZD3DTexture &t = draw.pixelTextures[i];
            Texture *texture = held<Texture>(t.texture, Object::texture);
            ID3D11SamplerState *sampler = com<ID3D11SamplerState>(t.sampler);
            ID3D11ShaderResourceView *view = texture != nullptr ? texture->view : nullptr;
            context->PSSetShaderResources(static_cast<UINT>(t.slot), 1, &view);
            context->PSSetSamplers(static_cast<UINT>(t.slot), 1, &sampler);
        }
        context->VSSetShader(program->vertex, nullptr, 0);
        context->PSSetShader(program->pixel, nullptr, 0);
        // Points by Bezzle's geometry shader, and lines with antialias as Metal draws them.
        ID3D11GeometryShader *geometry = topology == 4 ? program->points
                                         : (topology == 2 || topology == 3) && frame->samples > 1 ? program->lines
                                                                                                    : nullptr;
        context->GSSetShader(geometry, nullptr, 0);
        if (geometry != nullptr) {
            const float sizes[4] = {static_cast<float>(width), static_cast<float>(height), frame->largestPoint, 0};
            ID3D11Buffer *b = keep(buffer(d3d->device, D3D11_BIND_CONSTANT_BUFFER, sizes, sizeof sizes));
            context->GSSetConstantBuffers(0, 1, &b);
        }
        context->OMSetBlendState(draw.blend != nullptr ? com<ID3D11BlendState>(draw.blend) : nullptr, draw.blendColor,
                                 0xFFFFFFFF);
        const D3D11_RECT scissor = {draw.scissor[0], draw.scissor[1], draw.scissor[0] + draw.scissor[2],
                                    draw.scissor[1] + draw.scissor[3]};
        context->RSSetScissorRects(1, &scissor);
        if (draw.indices != nullptr)
            context->DrawIndexed(static_cast<UINT>(draw.count), static_cast<UINT>(draw.first), 0);
        else
            context->Draw(static_cast<UINT>(draw.count), static_cast<UINT>(draw.first));
    }

    if (ok && frame->finish != 0) {
        context->IASetInputLayout(nullptr);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(d3d->cover, nullptr, 0);
        context->GSSetShader(nullptr, nullptr, 0);
        context->PSSetShader(d3d->black, nullptr, 0);
        context->OMSetBlendState(frame->finish == 1 ? d3d->opaque : d3d->premultiply, nullptr, 0xFFFFFFFF);
        const D3D11_RECT all = {0, 0, width, height};
        context->RSSetScissorRects(1, &all);
        context->Draw(3, 0);
    }
    if (ok) {
        if (frame->samples > 1)
            context->ResolveSubresource(d3d->target, 0, d3d->multisampled, 0, DXGI_FORMAT_R8G8B8A8_UNORM);
        context->CopyResource(d3d->staging, d3d->target);
        D3D11_MAPPED_SUBRESOURCE mapped = {};
        const HRESULT result = context->Map(d3d->staging, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(result)) {
            for (int y = 0; y < height; y++)
                std::memcpy(static_cast<uint8_t *>(pixels) + static_cast<size_t>(y) * width * 4,
                            static_cast<const uint8_t *>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch,
                            static_cast<size_t>(width) * 4);
            context->Unmap(d3d->staging, 0);
        } else {
            why = "Direct3D: the frame did not draw (" + hex(d3d->device->GetDeviceRemovedReason()) + ").";
            ok = false;
        }
    }
    context->ClearState();
    for (ID3D11Buffer *b : made)
        b->Release();
    if (!ok)
        say(log, why);
    return ok ? 1 : 0;
}
