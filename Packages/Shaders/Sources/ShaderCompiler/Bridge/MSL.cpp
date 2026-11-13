// Bezzle's own: one stage's SPIR-V to the Metal Shading Language with SPIRV-Cross, and the layout
// of what the MSL takes (Cross.cpp): uniform buffers member by member, textures, vertex inputs.
// Built on the Mac only.

#include "Cross.h"

#include "../SPIRV-Cross/spirv_msl.hpp"

#include <exception>

namespace bezzle {

using namespace spirv_cross;

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
        if (usesWhatWebGLLacks(resources, log))
            return false;

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

        // The layout with the names as the GLSL gave them, before the MSL makes some of them its own.
        layout = layoutJSON(compiler, resources, resourceNames(compiler, resources), textureIndices);
        msl = compiler.compile();
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

int bz_translate(const char *vertex, const char *fragment, BZTranslation *result)
{
    std::memset(result, 0, sizeof(*result));
    std::string log;
    try {
        std::lock_guard<std::mutex> lock(bezzle::translating());
        bezzle::SPIRVProgram program;
        std::string vertexMSL, fragmentMSL, vertexLayout, fragmentLayout;
        bool ok = bezzle::compileGLSL(vertex, fragment, program, log) &&
                  bezzle::translateToMSL(program.vertex, true, vertexMSL, vertexLayout, log) &&
                  bezzle::translateToMSL(program.fragment, false, fragmentMSL, fragmentLayout, log);
        if (ok) {
            result->vertex = bezzle::copyString(vertexMSL);
            result->fragment = bezzle::copyString(fragmentMSL);
            result->reflection = bezzle::copyString("{\"interface\":" + program.interface + ",\"vertex\":" +
                                                    vertexLayout + ",\"fragment\":" + fragmentLayout + "}");
        }
        result->log = bezzle::copyString(log);
        return ok ? 1 : 0;
    } catch (const std::exception &error) {
        result->log = bezzle::copyString(log + error.what() + "\n");
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
