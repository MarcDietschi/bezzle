import Foundation

/// A WebGL program as the compilers laid it out, every name as the page wrote it: what it takes,
/// and where each thing goes in either stage. The same for Metal and Direct3D, which read one
/// reflection (Bridge/Cross.cpp).
struct ProgramLayout: Sendable {
    enum Base: Sendable { case float, int, uint }

    /// One value of a uniform block, or an array of them: where its numbers go in the buffer.
    struct Member: Sendable {
        var name: String
        var base: Base
        var rows: Int
        var columns: Int
        var count: Int
        var offset: Int
        var arrayStride: Int
        var matrixStride: Int
        var rowMajor: Bool
    }

    struct Buffer: Sendable {
        var index: Int
        var size: Int
        var members: [Member]
    }

    struct Texture: Sendable {
        var name: String
        var index: Int
        var count: Int
        var cube: Bool
    }

    struct Input: Sendable {
        var name: String
        var location: Int
        var base: Base
        var rows: Int
        var columns: Int
    }

    struct Stage: Sendable {
        var buffers: [Buffer]
        var textures: [Texture]
    }

    let interface: ShaderInterface
    let inputs: [Input]
    let vertex: Stage
    let fragment: Stage
    /// Which of drawBuffers' outputs the fragment stage writes: 0 alone for gl_FragColor.
    let outputs: Set<Int>

    /// From the translation's reflection, `original` naming back what the upgrade renamed.
    init(reflection json: String, original: [String: String]) throws {
        let reflection: Reflection
        do {
            reflection = try JSONDecoder().decode(Reflection.self, from: Data(json.utf8))
        } catch {
            throw ShaderError("The program's reflection did not read: \(error)")
        }
        func name(_ text: String) -> String { Upgrade.pageName(text, original) }

        // What it takes, as WebGL lists it.
        var uniforms: [ShaderUniform] = []
        for uniform in reflection.interface.uniforms where !Upgrade.ownUniforms.contains(uniform.name) {
            guard let type = ShaderType(glType: uniform.glType) else {
                throw ShaderError("The uniform \(name(uniform.name)) is of a kind Bezzle does not draw (GL type 0x\(String(uniform.glType, radix: 16))).")
            }
            uniforms.append(ShaderUniform(name: name(uniform.name), type: type, count: max(1, uniform.size)))
        }
        var attributes: [ShaderAttribute] = []
        for attribute in reflection.interface.attributes where !attribute.name.hasPrefix("gl_") {
            guard let type = ShaderType(glType: attribute.glType) else {
                throw ShaderError("The attribute \(name(attribute.name)) is of a kind Bezzle does not draw.")
            }
            attributes.append(ShaderAttribute(name: name(attribute.name), type: type))
        }
        interface = ShaderInterface(uniforms: uniforms, attributes: attributes)

        func base(_ text: String) throws -> Base {
            switch text {
            case "float": return .float
            case "int": return .int
            case "uint", "bool": return .uint
            default: throw ShaderError("A value of a kind Bezzle does not draw: \(text).")
            }
        }
        func stage(_ layout: Reflection.Stage) throws -> Stage {
            let buffers = try layout.buffers.map { buffer in
                Buffer(index: buffer.index, size: buffer.size, members: try buffer.members.map { member in
                    Member(name: name(member.name), base: try base(member.base), rows: member.rows,
                           columns: member.columns, count: member.count, offset: member.offset,
                           arrayStride: member.arrayStride, matrixStride: member.matrixStride,
                           rowMajor: member.rowMajor)
                })
            }
            let textures = try layout.textures.map { texture in
                guard (texture.kind == "2d" || texture.kind == "cube") && !texture.shadow && texture.base == "float" else {
                    throw ShaderError("The sampler \(name(texture.name)) is of a kind Bezzle does not draw yet (\(texture.kind)\(texture.shadow ? " shadow" : "")).")
                }
                return Texture(name: name(texture.name), index: texture.texture, count: texture.count,
                               cube: texture.kind == "cube")
            }
            return Stage(buffers: buffers, textures: textures)
        }
        vertex = try stage(reflection.vertex)
        fragment = try stage(reflection.fragment)
        var outputs = Set<Int>()
        for output in reflection.fragment.outputs where output.location >= 0 {
            for element in 0..<max(1, output.count) { outputs.insert(output.location + element) }
        }
        self.outputs = outputs
        inputs = try reflection.vertex.inputs.sorted { $0.location < $1.location }.map { input in
            Input(name: name(input.name), location: input.location, base: try base(input.base), rows: input.rows,
                  columns: input.columns)
        }
    }
}

/// The JSON the C++ side writes (see Bridge/Cross.cpp and Bridge/GLSL.cpp).
struct Reflection: Decodable {
    struct Entry: Decodable {
        var name: String
        var glType: Int
        var size: Int
    }

    struct Interface: Decodable {
        var uniforms: [Entry]
        var attributes: [Entry]
    }

    struct Member: Decodable {
        var name: String
        var base: String
        var rows: Int
        var columns: Int
        var count: Int
        var offset: Int
        var arrayStride: Int
        var matrixStride: Int
        var rowMajor: Bool
    }

    struct Buffer: Decodable {
        var block: String
        var index: Int
        var size: Int
        var members: [Member]
    }

    struct Texture: Decodable {
        var name: String
        var texture: Int
        var count: Int
        var kind: String
        var shadow: Bool
        var base: String
    }

    struct Variable: Decodable {
        var name: String
        var location: Int
        var base: String
        var rows: Int
        var columns: Int
        var count: Int
    }

    struct Stage: Decodable {
        var buffers: [Buffer]
        var textures: [Texture]
        var inputs: [Variable]
        var outputs: [Variable]
    }

    var interface: Interface
    var vertex: Stage
    var fragment: Stage
}
