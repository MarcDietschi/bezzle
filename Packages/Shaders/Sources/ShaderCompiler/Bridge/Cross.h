// Bezzle's own: what the two back ends (MSL.cpp for Metal, HLSL.cpp for Direct3D) share of
// SPIRV-Cross: which resources a stage may have, and the layout of what it takes, as JSON in the
// same shape for both, so Swift reads one.

#pragma once

#include "Bridge.h"

#include "../SPIRV-Cross/spirv_cross.hpp"

namespace bezzle {

/// The names of a stage's uniform blocks, their instances and its textures as the GLSL gave
/// them, taken before a back end makes some of them its own.
struct ResourceNames {
    std::vector<std::string> blocks, instances, textures;
};

ResourceNames resourceNames(const spirv_cross::Compiler &compiler, const spirv_cross::ShaderResources &resources);

/// Storage buffers, images, atomic counters and the rest WebGL does not have: what neither back
/// end draws. Says why in `log`.
bool usesWhatWebGLLacks(const spirv_cross::ShaderResources &resources, std::string &log);

/// The number of elements of an array type, all its dimensions together; 1 for no array.
uint32_t elements(const spirv_cross::Compiler &compiler, const spirv_cross::SPIRType &type);

/// One stage's layout as JSON: its uniform blocks member by member (block `i` at index `i`), its
/// textures at `textureIndices`, and its inputs and outputs by location.
std::string layoutJSON(const spirv_cross::Compiler &compiler, const spirv_cross::ShaderResources &resources,
                       const ResourceNames &names, const std::vector<uint32_t> &textureIndices);

} // namespace bezzle
