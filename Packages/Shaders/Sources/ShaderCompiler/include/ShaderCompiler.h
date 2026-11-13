// Bezzle's own: the C face of the shader compiler, so Swift calls it without C++ interop.
// glslang turns GLSL into SPIR-V, SPIRV-Cross turns SPIR-V into the Metal Shading Language on the
// Mac and into HLSL for Direct3D on Windows. Swift (`Sources/Shaders`) first upgrades a page's
// WebGL GLSL to the GLSL ES 3.10 these take.

#ifndef BEZZLE_SHADER_COMPILER_H
#define BEZZLE_SHADER_COMPILER_H

#ifdef __cplusplus
extern "C" {
#endif

/// A vertex and a fragment shader translated to Metal, or why they were not. Every string is
/// owned by the result: give it back with `bz_translation_free`.
typedef struct BZTranslation {
    /// The vertex stage in MSL, its function `bezzle_vertex`; NULL when the translation failed.
    char *vertex;
    /// The fragment stage in MSL, its function `bezzle_fragment`.
    char *fragment;
    /// JSON: what the program takes as WebGL names it (glslang's reflection, active ones only),
    /// and each stage's buffers, textures and vertex inputs as the MSL lays them out.
    char *reflection;
    /// The compilers' messages; when the translation failed, why.
    char *log;
} BZTranslation;

/// Compiles and links two GLSL ES 3.10 shaders with glslang under relaxed Vulkan rules (loose
/// uniforms in one default uniform block, locations and bindings mapped automatically, varyings
/// matched by name) and translates each stage to MSL with SPIRV-Cross. Returns 1 on success.
/// Calls are serialised inside; any thread may make them.
int bz_translate(const char *vertex, const char *fragment, BZTranslation *result);

/// Frees the strings of a translation and clears it.
void bz_translation_free(BZTranslation *result);

/// A vertex and a fragment shader translated to HLSL for Direct3D 11, shader model 5.0, each with
/// its entry point `main`, or why they were not. Every string is owned by the result: give it
/// back with `bz_hlsl_translation_free`. Windows only.
typedef struct BZHLSLTranslation {
    char *vertex;
    char *fragment;
    /// A geometry shader that draws each point as a square `gl_PointSize` pixels across, with
    /// `gl_PointCoord`, which Direct3D 11 does not do itself; NULL when the vertex stage sets no
    /// point size. It takes the output's size in pixels and the largest point from `b0`.
    char *points;
    /// A geometry shader that draws each line as a rectangle one pixel wide, as Metal draws lines
    /// with four samples a pixel. It takes the output's size in pixels from `b0`.
    char *lines;
    /// JSON in the same shape as `BZTranslation`'s: buffers at `b`, textures and samplers at `t`
    /// and `s`, vertex inputs at `TEXCOORD` and their location.
    char *reflection;
    char *log;
} BZHLSLTranslation;

/// As `bz_translate`, to HLSL. The fragment stage takes what the vertex stage gives in the same
/// order, as Direct3D links them. Windows only.
int bz_translate_hlsl(const char *vertex, const char *fragment, BZHLSLTranslation *result);

/// Frees the strings of an HLSL translation and clears it.
void bz_hlsl_translation_free(BZHLSLTranslation *result);

/// Only parses one shader, at the version it declares, under OpenGL ES rules and without making
/// SPIR-V: for checking which words a version takes. `stage` is 0 for vertex, 1 for fragment.
/// Returns 1 when it parses. `log`, when given, receives glslang's messages (free with `free`).
int bz_parses(const char *source, int stage, char **log);

#ifdef __cplusplus
}
#endif

#endif
