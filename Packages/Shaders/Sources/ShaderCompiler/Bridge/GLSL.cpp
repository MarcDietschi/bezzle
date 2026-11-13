// Bezzle's own: GLSL ES 3.10 to SPIR-V with glslang, the way `glslangValidator -V -R
// --auto-map-locations --auto-map-bindings` does it for a linked pair of stages.

#include "Bridge.h"

#include "glslang/Include/Types.h"
#include "glslang/Public/ResourceLimits.h"
#include "glslang/Public/ShaderLang.h"
#include "SPIRV/GlslangToSpv.h"
#include "SPIRV/Logger.h"

#include <memory>
#include <mutex>

namespace bezzle {

static void initialize()
{
    static std::once_flag once;
    std::call_once(once, [] { glslang::InitializeProcess(); });
}

static void append(std::string &log, const char *text)
{
    if (text == nullptr || *text == 0)
        return;
    log += text;
    if (log.back() != '\n')
        log += '\n';
}

static std::string interfaceJSON(const glslang::TProgram &program)
{
    std::string json = "{\"uniforms\":[";
    for (int i = 0; i < program.getNumUniformVariables(); i++) {
        const glslang::TObjectReflection &uniform = program.getUniform(i);
        if (i > 0)
            json += ",";
        json += "{\"name\":" + jsonString(uniform.name) + ",\"glType\":" + std::to_string(uniform.glDefineType) +
                ",\"size\":" + std::to_string(uniform.size) + "}";
    }
    json += "],\"attributes\":[";
    for (int i = 0; i < program.getNumPipeInputs(); i++) {
        const glslang::TObjectReflection &input = program.getPipeInput(i);
        if (i > 0)
            json += ",";
        json += "{\"name\":" + jsonString(input.name) + ",\"glType\":" + std::to_string(input.glDefineType) +
                ",\"size\":" + std::to_string(input.size) + "}";
    }
    json += "]}";
    return json;
}

bool compileGLSL(const char *vertex, const char *fragment, SPIRVProgram &result, std::string &log)
{
    initialize();
    const EShMessages messages = EShMessages(EShMsgSpvRules | EShMsgVulkanRules);
    glslang::TShader vertexShader(EShLangVertex), fragmentShader(EShLangFragment);
    glslang::TShader *shaders[2] = {&vertexShader, &fragmentShader};
    const char *sources[2] = {vertex, fragment};
    const char *names[2] = {"vertex", "fragment"};
    bool parsed = true;
    for (int i = 0; i < 2; i++) {
        glslang::TShader &shader = *shaders[i];
        const EShLanguage stage = i == 0 ? EShLangVertex : EShLangFragment;
        shader.setStringsWithLengthsAndNames(&sources[i], nullptr, &names[i], 1);
        shader.setAutoMapLocations(true);
        shader.setAutoMapBindings(true);
        shader.setEnvInput(glslang::EShSourceGlsl, stage, glslang::EShClientVulkan, 100);
        shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
        shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
        shader.setEnvInputVulkanRulesRelaxed();
        if (!shader.parse(GetDefaultResources(), 310, false, messages))
            parsed = false;
        append(log, shader.getInfoLog());
    }
    if (!parsed)
        return false;

    glslang::TProgram program;
    program.addShader(&vertexShader);
    program.addShader(&fragmentShader);
    if (!program.link(messages)) {
        append(log, program.getInfoLog());
        return false;
    }
    // Varyings get one location in both stages by name; uniforms one binding across stages.
    std::unique_ptr<glslang::TIoMapResolver> resolver(program.getGlslIoResolver(EShLangVertex));
    std::unique_ptr<glslang::TIoMapper> mapper(glslang::GetGlslIoMapper());
    if (!program.mapIO(resolver.get(), mapper.get())) {
        append(log, program.getInfoLog());
        return false;
    }
    program.buildReflection(EShReflectionStrictArraySuffix);
    result.interface = interfaceJSON(program);

    for (int i = 0; i < 2; i++) {
        glslang::TIntermediate *intermediate = program.getIntermediate(i == 0 ? EShLangVertex : EShLangFragment);
        if (intermediate == nullptr) {
            log += "Nothing to translate.\n";
            return false;
        }
        spv::SpvBuildLogger logger;
        glslang::SpvOptions options;
        options.disableOptimizer = true;
        options.validate = false;
        glslang::GlslangToSpv(*intermediate, i == 0 ? result.vertex : result.fragment, &logger, &options);
        append(log, logger.getAllMessages().c_str());
    }
    return !result.vertex.empty() && !result.fragment.empty();
}

bool parsesGLSL(const char *source, bool fragment, std::string &log)
{
    initialize();
    glslang::TShader shader(fragment ? EShLangFragment : EShLangVertex);
    shader.setStrings(&source, 1);
    const bool parsed = shader.parse(GetDefaultResources(), 100, false, EShMsgDefault);
    append(log, shader.getInfoLog());
    return parsed;
}

} // namespace bezzle
