// Bezzle's own: one stage's SPIR-V to the Metal Shading Language with SPIRV-Cross, and the layout
// of what the MSL takes: uniform buffers member by member, textures, vertex inputs.

#include "Bridge.h"

#include "../SPIRV-Cross/spirv_msl.hpp"

#include <exception>

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

/// The number of elements of an array type, all its dimensions together; 1 for no array.
static uint32_t elements(const CompilerMSL &compiler, const SPIRType &type)
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
static void members(const CompilerMSL &compiler, const SPIRType &block, uint32_t base, const std::string &prefix,
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

static std::string variables(const CompilerMSL &compiler, const SmallVector<Resource> &resources)
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

bool translateToMSL(const std::vector<uint32_t> &words, bool vertex, std::string &msl, std::string &layout,
                    std::string &log)
{
    try {
        CompilerMSL compiler(words);
        const spv::ExecutionModel model = vertex ? spv::ExecutionModelVertex : spv::ExecutionModelFragment;
        compiler.rename_entry_point("main", vertex ? "bezzle_vertex" : "bezzle_fragment", model);

        CompilerMSL::Options options = compiler.get_msl_options();
        options.platform = CompilerMSL::Options::macOS;
        options.set_msl_version(2, 3);
        options.enable_point_size_builtin = true;
        compiler.set_msl_options(options);
        CompilerGLSL::Options common = compiler.get_common_options();
        common.vertex.fixup_clipspace = true; // OpenGL's clip space z runs from -w to w, Metal's from 0 to w
        common.vertex.flip_vert_y = false;    // Metal's NDC have +y up, as OpenGL's
        compiler.set_common_options(common);

        ShaderResources resources = compiler.get_shader_resources();
        if (!resources.storage_buffers.empty() || !resources.storage_images.empty() ||
            !resources.atomic_counters.empty() || !resources.separate_images.empty() ||
            !resources.separate_samplers.empty() || !resources.push_constant_buffers.empty()) {
            log += "The shader uses storage buffers, images or atomic counters, which WebGL does not have.\n";
            return false;
        }

        // Uniform buffers at buffer(0) on; textures and their samplers at texture(0)/sampler(0) on.
        uint32_t buffer = 0;
        for (const Resource &resource : resources.uniform_buffers) {
            MSLResourceBinding binding;
            binding.stage = model;
            binding.desc_set = compiler.get_decoration(resource.id, spv::DecorationDescriptorSet);
            binding.binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
            binding.count = 1;
            binding.msl_buffer = buffer++;
            compiler.add_msl_resource_binding(binding);
        }
        uint32_t texture = 0;
        std::vector<uint32_t> textureIndices;
        for (const Resource &resource : resources.sampled_images) {
            const SPIRType &type = compiler.get_type(resource.type_id);
            MSLResourceBinding binding;
            binding.stage = model;
            binding.desc_set = compiler.get_decoration(resource.id, spv::DecorationDescriptorSet);
            binding.binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
            binding.count = elements(compiler, type);
            binding.msl_texture = texture;
            binding.msl_sampler = texture;
            textureIndices.push_back(texture);
            texture += binding.count;
            compiler.add_msl_resource_binding(binding);
        }
        if (buffer > 14 || texture > 16) {
            log += "The shader takes more uniform blocks or textures than Metal binds.\n";
            return false;
        }

        // The names as the GLSL gave them, before the MSL makes some of them its own.
        std::vector<std::string> blockNames, instanceNames, textureNames;
        for (const Resource &resource : resources.uniform_buffers) {
            blockNames.push_back(compiler.get_name(resource.base_type_id));
            instanceNames.push_back(compiler.get_name(resource.id));
        }
        for (const Resource &resource : resources.sampled_images)
            textureNames.push_back(compiler.get_name(resource.id));

        msl = compiler.compile();

        std::string json = "{\"buffers\":[";
        for (size_t i = 0; i < resources.uniform_buffers.size(); i++) {
            const Resource &resource = resources.uniform_buffers[i];
            const SPIRType &block = compiler.get_type(resource.base_type_id);
            const std::string &blockName = blockNames[i];
            const std::string &instance = instanceNames[i];
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
            json += "{\"name\":" + jsonString(textureNames[i]) +
                    ",\"texture\":" + std::to_string(textureIndices[i]) +
                    ",\"count\":" + std::to_string(elements(compiler, type)) + ",\"kind\":\"" + dimension(type) +
                    "\",\"shadow\":" + (type.image.depth ? "true" : "false") + ",\"base\":\"" +
                    baseName(sampled.basetype) + "\"}";
        }
        json += "],\"inputs\":" + variables(compiler, resources.stage_inputs);
        json += ",\"outputs\":" + variables(compiler, resources.stage_outputs) + "}";
        layout = json;
        return true;
    } catch (const std::exception &error) {
        log += std::string("SPIRV-Cross: ") + error.what() + "\n";
        return false;
    }
}

} // namespace bezzle

// The C face.

#include "ShaderCompiler.h"

#include <cstdlib>
#include <cstring>
#include <mutex>

static char *copy(const std::string &text)
{
    char *result = static_cast<char *>(std::malloc(text.size() + 1));
    if (result != nullptr)
        std::memcpy(result, text.c_str(), text.size() + 1);
    return result;
}

static std::mutex &translating()
{
    static std::mutex mutex;
    return mutex;
}

int bz_translate(const char *vertex, const char *fragment, BZTranslation *result)
{
    std::memset(result, 0, sizeof(*result));
    std::string log;
    try {
        std::lock_guard<std::mutex> lock(translating());
        bezzle::SPIRVProgram program;
        std::string vertexMSL, fragmentMSL, vertexLayout, fragmentLayout;
        bool ok = bezzle::compileGLSL(vertex, fragment, program, log) &&
                  bezzle::translateToMSL(program.vertex, true, vertexMSL, vertexLayout, log) &&
                  bezzle::translateToMSL(program.fragment, false, fragmentMSL, fragmentLayout, log);
        if (ok) {
            result->vertex = copy(vertexMSL);
            result->fragment = copy(fragmentMSL);
            result->reflection = copy("{\"interface\":" + program.interface + ",\"vertex\":" + vertexLayout +
                                      ",\"fragment\":" + fragmentLayout + "}");
        }
        result->log = copy(log);
        return ok ? 1 : 0;
    } catch (const std::exception &error) {
        result->log = copy(log + error.what() + "\n");
        return 0;
    }
}

void bz_translation_free(BZTranslation *result)
{
    std::free(result->vertex);
    std::free(result->fragment);
    std::free(result->reflection);
    std::free(result->log);
    std::memset(result, 0, sizeof(*result));
}

int bz_parses(const char *source, int stage, char **log)
{
    std::string messages;
    bool parsed;
    {
        std::lock_guard<std::mutex> lock(translating());
        parsed = bezzle::parsesGLSL(source, stage == 1, messages);
    }
    if (log != nullptr)
        *log = copy(messages);
    return parsed ? 1 : 0;
}
