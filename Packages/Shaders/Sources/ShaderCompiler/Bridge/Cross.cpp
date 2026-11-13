// Bezzle's own: the layout of what a stage takes, from SPIRV-Cross's reflection, for either back
// end: uniform buffers member by member, textures, vertex inputs.

#include "Cross.h"

namespace bezzle {

using namespace spirv_cross;

std::string jsonString(const std::string &text)
{
    std::string json = "\"";
    for (char c : text) {
        switch (c) {
        case '"': json += "\\\""; break;
        case '\\': json += "\\\\"; break;
        case '\n': json += "\\n"; break;
        case '\t': json += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20)
                json += ' ';
            else
                json += c;
        }
    }
    return json + "\"";
}

static const char *baseName(SPIRType::BaseType base)
{
    switch (base) {
    case SPIRType::Float: return "float";
    case SPIRType::Int: return "int";
    case SPIRType::UInt: return "uint";
    case SPIRType::Boolean: return "bool";
    case SPIRType::Struct: return "struct";
    case SPIRType::SampledImage: return "sampler";
    default: return "other";
    }
}

uint32_t elements(const Compiler &compiler, const SPIRType &type)
{
    uint32_t count = 1;
    for (size_t i = 0; i < type.array.size(); i++) {
        uint32_t size = type.array[i];
        if (!type.array_size_literal[i])
            size = compiler.evaluate_constant_u32(size);
        count *= size == 0 ? 1 : size;
    }
    return count;
}

/// The members of a block, flattened to the names WebGL gives them: `u_light.color`,
/// `u_lights[1].color`, `u_colors` (an array of plain values, whole).
static void members(const Compiler &compiler, const SPIRType &block, uint32_t base, const std::string &prefix,
                    std::string &json, bool &first)
{
    for (uint32_t i = 0; i < block.member_types.size(); i++) {
        const SPIRType &type = compiler.get_type(block.member_types[i]);
        const std::string name = prefix + compiler.get_member_name(block.self, i);
        const uint32_t offset = base + compiler.type_struct_member_offset(block, i);
        const uint32_t count = elements(compiler, type);
        const uint32_t stride = type.array.empty() ? 0 : compiler.type_struct_member_array_stride(block, i);
        if (type.basetype == SPIRType::Struct) {
            const SPIRType &element = compiler.get_type(type.self);
            if (type.array.empty()) {
                members(compiler, element, offset, name + ".", json, first);
            } else {
                for (uint32_t e = 0; e < count; e++)
                    members(compiler, element, offset + e * stride, name + "[" + std::to_string(e) + "].", json,
                            first);
            }
            continue;
        }
        const bool matrix = type.columns > 1;
        const uint32_t matrixStride = matrix ? compiler.type_struct_member_matrix_stride(block, i) : 0;
        const bool rowMajor = compiler.has_member_decoration(block.self, i, spv::DecorationRowMajor);
        if (!first)
            json += ",";
        first = false;
        json += "{\"name\":" + jsonString(name) + ",\"base\":\"" + baseName(type.basetype) +
                "\",\"rows\":" + std::to_string(type.vecsize) + ",\"columns\":" + std::to_string(type.columns) +
                ",\"count\":" + std::to_string(count) + ",\"offset\":" + std::to_string(offset) +
                ",\"arrayStride\":" + std::to_string(stride) + ",\"matrixStride\":" + std::to_string(matrixStride) +
                ",\"rowMajor\":" + (rowMajor ? "true" : "false") + "}";
    }
}

static const char *dimension(const SPIRType &type)
{
    switch (type.image.dim) {
    case spv::Dim2D: return type.image.arrayed ? "2dArray" : "2d";
    case spv::DimCube: return type.image.arrayed ? "cubeArray" : "cube";
    case spv::Dim3D: return "3d";
    default: return "other";
    }
}

static std::string variables(const Compiler &compiler, const SmallVector<Resource> &resources)
{
    std::string json = "[";
    bool first = true;
    for (const Resource &resource : resources) {
        const SPIRType &type = compiler.get_type(resource.type_id);
        if (!first)
            json += ",";
        first = false;
        const bool builtIn = compiler.has_decoration(resource.id, spv::DecorationBuiltIn);
        json += "{\"name\":" + jsonString(resource.name) + ",\"location\":" +
                std::to_string(builtIn ? -1 : int(compiler.get_decoration(resource.id, spv::DecorationLocation))) +
                ",\"base\":\"" + baseName(type.basetype) + "\",\"rows\":" + std::to_string(type.vecsize) +
                ",\"columns\":" + std::to_string(type.columns) + ",\"count\":" + std::to_string(elements(compiler, type)) +
                "}";
    }
    return json + "]";
}

ResourceNames resourceNames(const Compiler &compiler, const ShaderResources &resources)
{
    ResourceNames names;
    for (const Resource &resource : resources.uniform_buffers) {
        names.blocks.push_back(compiler.get_name(resource.base_type_id));
        names.instances.push_back(compiler.get_name(resource.id));
    }
    for (const Resource &resource : resources.sampled_images)
        names.textures.push_back(compiler.get_name(resource.id));
    return names;
}

bool usesWhatWebGLLacks(const ShaderResources &resources, std::string &log)
{
    if (!resources.storage_buffers.empty() || !resources.storage_images.empty() ||
        !resources.atomic_counters.empty() || !resources.separate_images.empty() ||
        !resources.separate_samplers.empty() || !resources.push_constant_buffers.empty()) {
        log += "The shader uses storage buffers, images or atomic counters, which WebGL does not have.\n";
        return true;
    }
    return false;
}

std::string layoutJSON(const Compiler &compiler, const ShaderResources &resources, const ResourceNames &names,
                       const std::vector<uint32_t> &textureIndices)
{
    std::string json = "{\"buffers\":[";
    for (size_t i = 0; i < resources.uniform_buffers.size(); i++) {
        const Resource &resource = resources.uniform_buffers[i];
        const SPIRType &block = compiler.get_type(resource.base_type_id);
        const std::string &blockName = names.blocks[i];
        const std::string &instance = names.instances[i];
        // WebGL names a member of a named block's instance "Block.member", any other plainly.
        const std::string prefix =
            (blockName == "gl_DefaultUniformBlock" || instance.empty() || instance.rfind("_", 0) == 0)
                ? ""
                : blockName + ".";
        if (i > 0)
            json += ",";
        json += "{\"block\":" + jsonString(blockName) + ",\"index\":" + std::to_string(i) +
                ",\"size\":" + std::to_string(compiler.get_declared_struct_size(block)) + ",\"members\":[";
        bool first = true;
        members(compiler, block, 0, prefix, json, first);
        json += "]}";
    }
    json += "],\"textures\":[";
    for (size_t i = 0; i < resources.sampled_images.size(); i++) {
        const Resource &resource = resources.sampled_images[i];
        const SPIRType &type = compiler.get_type(resource.type_id);
        const SPIRType &sampled = compiler.get_type(type.image.type);
        if (i > 0)
            json += ",";
        json += "{\"name\":" + jsonString(names.textures[i]) +
                ",\"texture\":" + std::to_string(textureIndices[i]) +
                ",\"count\":" + std::to_string(elements(compiler, type)) + ",\"kind\":\"" + dimension(type) +
                "\",\"shadow\":" + (type.image.depth ? "true" : "false") + ",\"base\":\"" +
                baseName(sampled.basetype) + "\"}";
    }
    json += "],\"inputs\":" + variables(compiler, resources.stage_inputs);
    json += ",\"outputs\":" + variables(compiler, resources.stage_outputs) + "}";
    return json;
}

} // namespace bezzle
