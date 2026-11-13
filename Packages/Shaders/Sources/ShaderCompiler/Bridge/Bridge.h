// Bezzle's own: what the two halves of the bridge give each other. GLSL.cpp sees only glslang,
// Cross.cpp, MSL.cpp and HLSL.cpp only SPIRV-Cross, since both bring a `spirv.hpp` of their own.

#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace bezzle {

struct SPIRVProgram {
    std::vector<uint32_t> vertex;
    std::vector<uint32_t> fragment;
    /// JSON: {"uniforms": [...], "attributes": [...]}, from glslang's reflection.
    std::string interface;
};

/// GLSL ES 3.10 to SPIR-V, both stages linked. False with the reason in `log`.
bool compileGLSL(const char *vertex, const char *fragment, SPIRVProgram &program, std::string &log);

/// Parses one shader at the version it declares, OpenGL ES rules, no SPIR-V.
bool parsesGLSL(const char *source, bool fragment, std::string &log);

/// One stage's SPIR-V to MSL, with its layout as JSON. False with the reason in `log`.
bool translateToMSL(const std::vector<uint32_t> &words, bool vertex, std::string &msl, std::string &layout,
                    std::string &log);

/// One stage's SPIR-V to HLSL for Direct3D 11 (shader model 5.0), with its layout as JSON in
/// the same shape as the MSL's. False with the reason in `log`.
bool translateToHLSL(const std::vector<uint32_t> &words, bool vertex, std::string &hlsl, std::string &layout,
                     std::string &log);

/// `text` as a JSON string, quotes included.
std::string jsonString(const std::string &text);

/// `text` copied for C, to be let go with `free`.
char *copyString(const std::string &text);

/// Held around every call into glslang and SPIRV-Cross, which keep state of their own.
std::mutex &translating();

} // namespace bezzle
