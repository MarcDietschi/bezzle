// Bezzle's own: one stage's SPIR-V to HLSL for Direct3D 11 (shader model 5.0) with SPIRV-Cross,
// with the layout of what it takes in the same shape as the MSL's (Cross.cpp). Built on Windows,
// where Direct3D draws what Metal draws on the Mac.

#include "Cross.h"

#include "../SPIRV-Cross/spirv_hlsl.hpp"

#include <cctype>
#include <exception>

namespace bezzle {

using namespace spirv_cross;

bool translateToHLSL(const std::vector<uint32_t> &words, bool vertex, std::string &hlsl, std::string &layout,
                     std::string &log)
{
    try {
        CompilerHLSL compiler(words);
        const spv::ExecutionModel model = vertex ? spv::ExecutionModelVertex : spv::ExecutionModelFragment;

        CompilerHLSL::Options options = compiler.get_hlsl_options();
        options.shader_model = 50;
        // Bezzle draws sized points itself (a geometry shader), so these built-ins never reach here;
        // were one to, it is left out rather than refused.
        options.point_size_compat = true;
        options.point_coord_compat = true;
        // A matrix attribute's columns at locations of their own, as Metal takes them.
        options.flatten_matrix_vertex_input_semantics = true;
        compiler.set_hlsl_options(options);
        CompilerGLSL::Options common = compiler.get_common_options();
        common.vertex.fixup_clipspace = true; // OpenGL's clip space z runs from -w to w, Direct3D's from 0 to w
        common.vertex.flip_vert_y = false;    // Direct3D's NDC have +y up, as OpenGL's
        compiler.set_common_options(common);

        ShaderResources resources = compiler.get_shader_resources();
        if (usesWhatWebGLLacks(resources, log))
            return false;

        // Uniform buffers at b0 on; textures and their samplers at t0 and s0 on.
        uint32_t buffer = 0;
        for (const Resource &resource : resources.uniform_buffers) {
            HLSLResourceBinding binding;
            binding.stage = model;
            binding.desc_set = compiler.get_decoration(resource.id, spv::DecorationDescriptorSet);
            binding.binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
            binding.cbv.register_binding = buffer++;
            compiler.add_hlsl_resource_binding(binding);
        }
        uint32_t texture = 0;
        std::vector<uint32_t> textureIndices;
        for (const Resource &resource : resources.sampled_images) {
            const SPIRType &type = compiler.get_type(resource.type_id);
            HLSLResourceBinding binding;
            binding.stage = model;
            binding.desc_set = compiler.get_decoration(resource.id, spv::DecorationDescriptorSet);
            binding.binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
            binding.srv.register_binding = texture;
            binding.sampler.register_binding = texture;
            textureIndices.push_back(texture);
            texture += elements(compiler, type);
            compiler.add_hlsl_resource_binding(binding);
        }
        // As Metal's limits, which Direct3D 11's (14 constant buffers, 16 samplers) also are.
        if (buffer > 14 || texture > 16) {
            log += "The shader takes more uniform blocks or textures than Direct3D binds.\n";
            return false;
        }

        // The layout with the names as the GLSL gave them, before the HLSL makes some of them its own.
        layout = layoutJSON(compiler, resources, resourceNames(compiler, resources), textureIndices);
        hlsl = compiler.compile();
        return true;
    } catch (const std::exception &error) {
        log += std::string("SPIRV-Cross: ") + error.what() + "\n";
        return false;
    }
}

// MARK: Linking the stages

/// One member of a struct SPIRV-Cross wrote, one a line: `    nointerpolation int v_i : TEXCOORD2;`.
struct Field {
    std::string line;
    std::string modifiers; // interpolation qualifiers, with a space after each
    std::string type;
    std::string name;
    std::string semantic;
};

static std::string trimmed(const std::string &text)
{
    const size_t begin = text.find_first_not_of(" \t");
    if (begin == std::string::npos)
        return "";
    const size_t end = text.find_last_not_of(" \t\r");
    return text.substr(begin, end - begin + 1);
}

/// The members of `struct <name>` in `hlsl`, and where its body lies (from the line after `{` to
/// the line `};`). False when there is no such struct or a line does not read as a member.
static bool fields(const std::string &hlsl, const std::string &name, size_t &begin, size_t &end,
                   std::vector<Field> &out)
{
    const std::string head = "struct " + name + "\n{\n";
    const size_t at = hlsl.find(head);
    if (at == std::string::npos)
        return false;
    begin = at + head.size();
    end = hlsl.find("};", begin);
    if (end == std::string::npos)
        return false;
    size_t line = begin;
    while (line < end) {
        size_t next = hlsl.find('\n', line);
        if (next == std::string::npos || next > end)
            next = end;
        const std::string text = trimmed(hlsl.substr(line, next - line));
        line = next + 1;
        if (text.empty())
            continue;
        const size_t colon = text.rfind(" : ");
        if (colon == std::string::npos || text.back() != ';')
            return false;
        Field field;
        field.line = "    " + text;
        field.semantic = text.substr(colon + 3, text.size() - colon - 4);
        std::vector<std::string> words;
        size_t word = 0;
        const std::string left = text.substr(0, colon);
        while (word < left.size()) {
            size_t space = left.find(' ', word);
            if (space == std::string::npos)
                space = left.size();
            if (space > word)
                words.push_back(left.substr(word, space - word));
            word = space + 1;
        }
        if (words.size() < 2)
            return false;
        field.name = words.back();
        static const char *qualifiers[] = {"nointerpolation", "noperspective", "centroid", "sample", "linear"};
        size_t w = 0;
        for (; w + 1 < words.size(); w++) {
            bool qualifier = false;
            for (const char *q : qualifiers)
                qualifier = qualifier || words[w] == q;
            if (!qualifier)
                break;
            field.modifiers += words[w] + " ";
        }
        for (size_t t = w; t + 1 < words.size(); t++)
            field.type += (t > w ? " " : "") + words[t];
        out.push_back(field);
    }
    return true;
}

static bool isSystemValue(const std::string &semantic)
{
    return semantic.size() > 3 && (semantic.compare(0, 3, "SV_") == 0 || semantic.compare(0, 3, "sv_") == 0);
}

/// Direct3D 11 links a pixel shader's inputs to what the stage before it gives by register, which
/// the HLSL compiler packs in the order the members are declared, by their types and how they are
/// interpolated: so the fragment stage's inputs are declared as the vertex stage's outputs are,
/// each under the fragment stage's own name, with a member of no use where it reads nothing, as
/// WebGL links varyings by name. An input the vertex stage does not give (declared and never
/// written) reads nought. False when the HLSL does not read as SPIRV-Cross writes it.
static bool linkStages(const std::string &vertex, std::string &fragment)
{
    size_t vertexBegin, vertexEnd, begin, end;
    std::vector<Field> outputs, inputs;
    if (!fields(fragment, "SPIRV_Cross_Input", begin, end, inputs))
        return fragment.find("struct SPIRV_Cross_Input\n") == std::string::npos; // takes nothing
    if (!fields(vertex, "SPIRV_Cross_Output", vertexBegin, vertexEnd, outputs))
        return false;
    std::string body;
    std::vector<bool> used(inputs.size(), false);
    int unused = 0;
    for (const Field &output : outputs) {
        std::string name;
        for (size_t i = 0; i < inputs.size() && name.empty(); i++) {
            if (!used[i] && inputs[i].semantic == output.semantic) {
                name = inputs[i].name;
                used[i] = true;
            }
        }
        if (name.empty())
            name = "bezzle_unused_" + std::to_string(unused++);
        body += "    " + output.modifiers + output.type + " " + name + " : " + output.semantic + ";\n";
    }
    std::vector<std::string> unwritten;
    for (size_t i = 0; i < inputs.size(); i++) {
        if (used[i])
            continue;
        if (isSystemValue(inputs[i].semantic))
            body += inputs[i].line + "\n"; // made by the rasterizer, as SV_IsFrontFace
        else
            unwritten.push_back(inputs[i].name);
    }
    std::string linked = fragment.substr(0, begin) + body + fragment.substr(end);
    // An input nothing gives is no longer one: the static variable it was read into stays nought.
    for (const std::string &name : unwritten) {
        const std::string read = " = stage_input." + name + ";";
        const size_t at = linked.find(read);
        if (at == std::string::npos)
            return false;
        const size_t lineBegin = linked.rfind('\n', at) + 1;
        const size_t lineEnd = linked.find('\n', at);
        linked.erase(lineBegin, lineEnd - lineBegin + 1);
    }
    fragment = linked;
    return true;
}

/// Calls of `name` in `text` made calls of `with`, where `name` is a whole word.
static void replaceCalls(std::string &text, const std::string &name, const std::string &with)
{
    const std::string call = name + "(";
    size_t at = 0;
    while ((at = text.find(call, at)) != std::string::npos) {
        const char before = at > 0 ? text[at - 1] : ' ';
        if (std::isalnum(static_cast<unsigned char>(before)) || before == '_') {
            at += call.size();
            continue;
        }
        text.replace(at, name.size(), with);
        at += with.size();
    }
}

/// WebGL leaves fine or coarse derivatives to the GPU; Metal takes them fine, each pixel's from
/// its own row and column of the 2 by 2 it is drawn in, so Direct3D does too, which for `ddx` and
/// `fwidth` takes coarse ones on some (WARP among them).
static void fineDerivatives(std::string &fragment)
{
    replaceCalls(fragment, "ddx", "ddx_fine");
    replaceCalls(fragment, "ddy", "ddy_fine");
    if (fragment.find("fwidth(") == std::string::npos)
        return;
    replaceCalls(fragment, "fwidth", "bezzle_fwidth");
    std::string helpers;
    for (const char *type : {"float", "float2", "float3", "float4"})
        helpers += std::string(type) + " bezzle_fwidth(" + type + " v) { return abs(ddx_fine(v)) + abs(ddy_fine(v)); }\n";
    fragment = helpers + "\n" + fragment;
}

/// A geometry shader that draws each point the vertex stage gives as a square `gl_PointSize`
/// output pixels across round its centre, with `gl_PointCoord` running from the top left, and
/// none whose centre is outside, as WebGL draws points; empty when the vertex stage sets no point size (Upgrade.swift gives it as
/// the output `bezzle_PointSize`). `b0` holds the output's width and height in pixels and the
/// largest point.
static std::string pointShader(const std::string &vertex)
{
    size_t begin, end;
    std::vector<Field> outputs;
    if (!fields(vertex, "SPIRV_Cross_Output", begin, end, outputs))
        return "";
    bool sized = false, coordinates = false;
    std::string position;
    for (const Field &output : outputs) {
        sized = sized || output.name == "bezzle_PointSize";
        coordinates = coordinates || output.name == "bezzle_PointCoord";
        if (output.semantic == "SV_Position")
            position = output.name;
    }
    if (!sized || position.empty())
        return "";
    std::string shader = "struct BezzlePoint\n{\n";
    for (const Field &output : outputs)
        shader += output.line + "\n";
    shader += "};\n\n"
              "cbuffer BezzlePoints : register(b0)\n{\n    float4 bezzle_points;\n};\n\n"
              "[maxvertexcount(4)]\n"
              "void main(point BezzlePoint input[1], inout TriangleStream<BezzlePoint> stream)\n{\n"
              "    BezzlePoint p = input[0];\n"
              "    float4 c = p." + position + ";\n"
              "    // A point whose centre is outside clip space is not drawn at all, as in WebGL and Metal.\n"
              "    if (abs(c.x) > c.w || abs(c.y) > c.w || c.z < 0.0 || c.z > c.w)\n"
              "        return;\n"
              "    float size = clamp(p.bezzle_PointSize, 1.0, bezzle_points.z);\n"
              "    float2 extent = size / bezzle_points.xy * c.w;\n"
              "    const float2 corners[4] = { float2(-1.0, 1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, -1.0) };\n"
              "    [unroll] for (int i = 0; i < 4; i++)\n    {\n"
              "        BezzlePoint v = p;\n"
              "        v." + position + ".xy = c.xy + corners[i] * extent;\n";
    if (coordinates)
        shader += "        v.bezzle_PointCoord = corners[i] * float2(0.5, -0.5) + 0.5;\n";
    shader += "        stream.Append(v);\n    }\n}\n";
    return shader;
}

/// A geometry shader that draws each line as a rectangle one output pixel wide, as Metal draws
/// lines with four samples a pixel (Direct3D's own are wider); for lines with antialias. `b0`
/// holds the output's width and height in pixels.
static std::string lineShader(const std::string &vertex)
{
    size_t begin, end;
    std::vector<Field> outputs;
    if (!fields(vertex, "SPIRV_Cross_Output", begin, end, outputs))
        return "";
    std::string position;
    for (const Field &output : outputs)
        if (output.semantic == "SV_Position")
            position = output.name;
    if (position.empty())
        return "";
    std::string shader = "struct BezzleLine\n{\n";
    for (const Field &output : outputs)
        shader += output.line + "\n";
    shader += "};\n\n"
              "cbuffer BezzleLines : register(b0)\n{\n    float4 bezzle_lines;\n};\n\n"
              "[maxvertexcount(4)]\n"
              "void main(line BezzleLine input[2], inout TriangleStream<BezzleLine> stream)\n{\n"
              "    float4 a = input[0]." + position + ", b = input[1]." + position + ";\n"
              "    float2 half_ = bezzle_lines.xy * 0.5;\n"
              "    float2 d = (b.xy / b.w - a.xy / a.w) * half_;\n"
              "    float l = length(d);\n"
              "    if (!(l > 0.0))\n"
              "        return;\n"
              "    float2 across = float2(-d.y, d.x) / l * 0.5 / half_;\n"
              "    BezzleLine v = input[0];\n"
              "    v." + position + ".xy = a.xy + across * a.w;\n"
              "    stream.Append(v);\n"
              "    v." + position + ".xy = a.xy - across * a.w;\n"
              "    stream.Append(v);\n"
              "    v = input[1];\n"
              "    v." + position + ".xy = b.xy + across * b.w;\n"
              "    stream.Append(v);\n"
              "    v." + position + ".xy = b.xy - across * b.w;\n"
              "    stream.Append(v);\n"
              "}\n";
    return shader;
}

} // namespace bezzle

// The C face.

#include "ShaderCompiler.h"

#include <cstdlib>
#include <cstring>

int bz_translate_hlsl(const char *vertex, const char *fragment, BZHLSLTranslation *result)
{
    std::memset(result, 0, sizeof(*result));
    std::string log;
    try {
        std::lock_guard<std::mutex> lock(bezzle::translating());
        bezzle::SPIRVProgram program;
        std::string vertexHLSL, fragmentHLSL, vertexLayout, fragmentLayout;
        bool ok = bezzle::compileGLSL(vertex, fragment, program, log) &&
                  bezzle::translateToHLSL(program.vertex, true, vertexHLSL, vertexLayout, log) &&
                  bezzle::translateToHLSL(program.fragment, false, fragmentHLSL, fragmentLayout, log);
        if (ok && !bezzle::linkStages(vertexHLSL, fragmentHLSL)) {
            log += "The two stages' HLSL could not be linked for Direct3D.\n";
            ok = false;
        }
        if (ok) {
            bezzle::fineDerivatives(fragmentHLSL);
            const std::string points = bezzle::pointShader(vertexHLSL);
            const std::string lines = bezzle::lineShader(vertexHLSL);
            result->vertex = bezzle::copyString(vertexHLSL);
            result->fragment = bezzle::copyString(fragmentHLSL);
            result->points = points.empty() ? nullptr : bezzle::copyString(points);
            result->lines = lines.empty() ? nullptr : bezzle::copyString(lines);
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

void bz_hlsl_translation_free(BZHLSLTranslation *result)
{
    std::free(result->vertex);
    std::free(result->fragment);
    std::free(result->points);
    std::free(result->lines);
    std::free(result->reflection);
    std::free(result->log);
    std::memset(result, 0, sizeof(*result));
}
