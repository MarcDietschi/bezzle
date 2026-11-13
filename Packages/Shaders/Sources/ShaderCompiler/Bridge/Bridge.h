// Bezzle's own: what the two halves of the bridge give each other. GLSL.cpp sees only glslang,
// MSL.cpp only SPIRV-Cross, since both bring a `spirv.hpp` of their own.

#pragma once

#include <cstdint>
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

/// `text` as a JSON string, quotes included.
std::string jsonString(const std::string &text);

} // namespace bezzle
