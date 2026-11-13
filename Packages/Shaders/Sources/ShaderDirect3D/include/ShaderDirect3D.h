// Bezzle's own: Direct3D 11 for the shader engine on Windows, behind a plain C face so Swift calls
// it without C++ interop or COM. Swift (Sources/Shaders/Direct3D) works out every draw as WebGL
// makes it, the same as for Metal on the Mac; this makes the objects and draws.

#ifndef BEZZLE_SHADER_DIRECT3D_H
#define BEZZLE_SHADER_DIRECT3D_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A Direct3D 11 device and its context, used by one call at a time.
typedef struct BZD3D BZD3D;

/// Opens Direct3D 11 on the graphics card, or on the processor (WARP) where there is none that
/// does feature level 11, or when `software`. NULL when neither opens. `adapter` receives the
/// device's name ("WARP" for the processor).
BZD3D *bz_d3d_open(int software, char *adapter, int capacity);

/// Lets go of a device; what was made with it keeps what it needs of it.
void bz_d3d_close(BZD3D *d3d);

/// Whether `count` samples a pixel can be drawn into RGBA8.
int bz_d3d_samples(BZD3D *d3d, int count);

/// Compiles a program's HLSL (entry `main`, shader model 5.0): the vertex and pixel stages, the
/// geometry shader that draws sized points when `points` is not NULL, and the one that draws lines
/// with antialias when `lines` is not NULL. NULL when one does not compile, with the compiler's
/// messages in `log` (let go with `bz_d3d_free`). `seconds` receives how long the compiler took.
void *bz_d3d_program(BZD3D *d3d, const char *vertex, const char *pixel, const char *points, const char *lines,
                     char **log, double *seconds);

/// One attribute of a vertex stage: read at `TEXCOORD<location>` from buffer `slot`.
typedef struct BZD3DElement {
    int32_t location;
    /// 0 float, 1 int, 2 uint.
    int32_t base;
    /// 1 to 4 numbers.
    int32_t width;
    int32_t slot;
    int32_t offset;
    /// The same value for every vertex (read once per instance, and one instance is drawn).
    int32_t constant;
} BZD3DElement;

/// The input layout of a program's vertex stage. NULL when it cannot be made, with why in `log`.
void *bz_d3d_layout(BZD3D *d3d, void *program, const BZD3DElement *elements, int32_t count, char **log);

/// A blend state: the colour's and alpha's source and destination factors and the two equations,
/// in the order of `ShaderDraw.Blend.Factor` and `.Equation`.
void *bz_d3d_blend(BZD3D *d3d, const int32_t *factors);

/// A sampler: wraps 0 repeat, 1 clamp, 2 mirrored; filters 0 nearest, 1 linear; `mipmap` -1 for
/// none, else its filter.
void *bz_d3d_sampler(BZD3D *d3d, int32_t wrapS, int32_t wrapT, int32_t magnify, int32_t minify, int32_t mipmap);

/// A texture of `width` by `height` RGBA8 pixels, rows top first, the first row t = 0; a cube
/// takes six faces one after the other (+X, -X, +Y, -Y, +Z, -Z). With `mipmaps`, its smaller
/// levels are made from the first. NULL when it cannot be made.
void *bz_d3d_texture(BZD3D *d3d, int32_t width, int32_t height, const void *rgba, int32_t cube, int32_t mipmaps);

/// Lets go of a program, layout, state or texture.
void bz_d3d_release(void *object);

/// Lets go of a message one of these wrote.
void bz_d3d_free(char *text);

/// Bytes for a slot: a constant buffer (a multiple of 16 bytes) or a vertex buffer (`stride` apart).
typedef struct BZD3DBytes {
    int32_t slot;
    const void *bytes;
    int32_t count;
    int32_t stride;
} BZD3DBytes;

typedef struct BZD3DTexture {
    int32_t slot;
    void *texture;
    void *sampler;
} BZD3DTexture;

typedef struct BZD3DDraw {
    void *program;
    /// NULL for a vertex stage that takes no attributes.
    void *layout;
    /// NULL for no blending.
    void *blend;
    float blendColor[4];
    /// 0 triangles, 1 a triangle strip, 2 lines, 3 a line strip, 4 points.
    int32_t topology;
    /// x, y, width, height in the output's pixels from its top left.
    int32_t scissor[4];
    const BZD3DBytes *vertices;
    int32_t vertexBufferCount;
    /// drawElements' indices, NULL for drawArrays; from `first` on, `count` of them or of the vertices.
    const uint32_t *indices;
    int32_t indexCount;
    int32_t first;
    int32_t count;
    const BZD3DBytes *vertexConstants;
    int32_t vertexConstantCount;
    const BZD3DBytes *pixelConstants;
    int32_t pixelConstantCount;
    const BZD3DTexture *vertexTextures;
    int32_t vertexTextureCount;
    const BZD3DTexture *pixelTextures;
    int32_t pixelTextureCount;
} BZD3DDraw;

typedef struct BZD3DFrame {
    int32_t width;
    int32_t height;
    int32_t samples;
    float clear[4];
    /// After the draws: 0 nothing, 1 alpha made 1, 2 the colours multiplied by alpha.
    int32_t finish;
    /// The largest point the geometry shader draws, in output pixels.
    float largestPoint;
    const BZD3DDraw *draws;
    int32_t drawCount;
} BZD3DFrame;

/// Draws a frame and reads it back into `pixels`: `width` times `height` RGBA8, rows top first.
/// Returns 1 when done; 0 with why in `log` (let go with `free`).
int bz_d3d_draw(BZD3D *d3d, const BZD3DFrame *frame, void *pixels, char **log);

#ifdef __cplusplus
}
#endif

#endif
