import Foundation
import Metal
import ShaderCompiler

/// A WebGL program translated to Metal: its two functions, what it takes, and where each thing
/// goes, every name as the page wrote it.
final class Program: @unchecked Sendable {
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
    let vertexFunction: MTLFunction
    let fragmentFunction: MTLFunction
    /// How long glslang and SPIRV-Cross took, and the Metal compiler after them, in seconds.
    let translationTime: Double
    let buildTime: Double

    private let lock = NSLock()
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]

    /// Where vertex buffers start in Metal's buffer table; uniform blocks come before.
    static let firstVertexBuffer = 14

    init(device: MTLDevice, vertex vertexSource: String, fragment fragmentSource: String) throws {
        let start = Date()
        let vertexShader = Upgrade.upgrade(vertexSource, stage: .vertex)
        let fragmentShader = Upgrade.upgrade(fragmentSource, stage: .fragment)
        var translation = BZTranslation()
        let translated = bz_translate(vertexShader.source, fragmentShader.source, &translation)
        defer { bz_translation_free(&translation) }
        let log = translation.log.map { String(cString: $0) } ?? ""
        guard translated == 1, let vertexMSL = translation.vertex, let fragmentMSL = translation.fragment,
              let json = translation.reflection else {
            throw ShaderError(log.isEmpty ? "The program did not translate." : log)
        }
        let reflection: Reflection
        do {
            reflection = try JSONDecoder().decode(Reflection.self, from: Data(String(cString: json).utf8))
        } catch {
            throw ShaderError("The program's reflection did not read: \(error)")
        }
        translationTime = Date().timeIntervalSince(start)

        var original = vertexShader.original
        original.merge(fragmentShader.original) { first, _ in first }
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
        inputs = try reflection.vertex.inputs.sorted { $0.location < $1.location }.map { input in
            Input(name: name(input.name), location: input.location, base: try base(input.base), rows: input.rows,
                  columns: input.columns)
        }
        if inputs.count > 31 - Program.firstVertexBuffer {
            throw ShaderError("The program takes more attributes than Bezzle binds.")
        }

        // Metal.
        let built = Date()
        let options = MTLCompileOptions()
        options.languageVersion = .version2_3
        options.mathMode = .safe
        func function(_ source: UnsafeMutablePointer<CChar>, _ entry: String) throws -> MTLFunction {
            do {
                let library = try device.makeLibrary(source: String(cString: source), options: options)
                guard let function = library.makeFunction(name: entry) else {
                    throw ShaderError("Metal: no function \(entry).")
                }
                return function
            } catch let error as ShaderError {
                throw error
            } catch {
                throw ShaderError("Metal: \(error.localizedDescription)")
            }
        }
        vertexFunction = try function(vertexMSL, "bezzle_vertex")
        fragmentFunction = try function(fragmentMSL, "bezzle_fragment")
        buildTime = Date().timeIntervalSince(built)
    }

    // MARK: Pipelines

    struct AttributeLayout: Hashable {
        var location: Int
        var format: UInt
        var buffer: Int
        var offset: Int
        var stride: Int
        var constant: Bool
    }

    struct PipelineKey: Hashable {
        var attributes: [AttributeLayout]
        var pixelFormat: UInt
        var sampleCount: Int
        var blend: BlendKey?
    }

    struct BlendKey: Hashable {
        var source: UInt, destination: UInt, sourceAlpha: UInt, destinationAlpha: UInt
        var equation: UInt, equationAlpha: UInt

        init(_ blend: ShaderDraw.Blend) {
            source = Self.factor(blend.source).rawValue
            destination = Self.factor(blend.destination).rawValue
            sourceAlpha = Self.factor(blend.sourceAlpha).rawValue
            destinationAlpha = Self.factor(blend.destinationAlpha).rawValue
            equation = Self.operation(blend.equation).rawValue
            equationAlpha = Self.operation(blend.equationAlpha).rawValue
        }

        static func factor(_ factor: ShaderDraw.Blend.Factor) -> MTLBlendFactor {
            switch factor {
            case .zero: .zero
            case .one: .one
            case .sourceColor: .sourceColor
            case .oneMinusSourceColor: .oneMinusSourceColor
            case .destinationColor: .destinationColor
            case .oneMinusDestinationColor: .oneMinusDestinationColor
            case .sourceAlpha: .sourceAlpha
            case .oneMinusSourceAlpha: .oneMinusSourceAlpha
            case .destinationAlpha: .destinationAlpha
            case .oneMinusDestinationAlpha: .oneMinusDestinationAlpha
            case .constantColor: .blendColor
            case .oneMinusConstantColor: .oneMinusBlendColor
            case .constantAlpha: .blendAlpha
            case .oneMinusConstantAlpha: .oneMinusBlendAlpha
            case .sourceAlphaSaturate: .sourceAlphaSaturated
            }
        }

        static func operation(_ equation: ShaderDraw.Blend.Equation) -> MTLBlendOperation {
            switch equation {
            case .add: .add
            case .subtract: .subtract
            case .reverseSubtract: .reverseSubtract
            case .min: .min
            case .max: .max
            }
        }
    }

    func pipeline(_ key: PipelineKey, device: MTLDevice) throws -> MTLRenderPipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let pipeline = pipelines[key] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = key.sampleCount
        let vertexDescriptor = MTLVertexDescriptor()
        for attribute in key.attributes {
            vertexDescriptor.attributes[attribute.location].format = MTLVertexFormat(rawValue: attribute.format)!
            vertexDescriptor.attributes[attribute.location].bufferIndex = attribute.buffer
            vertexDescriptor.attributes[attribute.location].offset = attribute.offset
            let layout = vertexDescriptor.layouts[attribute.buffer]!
            layout.stride = attribute.stride
            layout.stepFunction = attribute.constant ? .constant : .perVertex
            layout.stepRate = attribute.constant ? 0 : 1
        }
        descriptor.vertexDescriptor = vertexDescriptor
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = MTLPixelFormat(rawValue: key.pixelFormat)!
        if let blend = key.blend {
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = MTLBlendFactor(rawValue: blend.source)!
            color.destinationRGBBlendFactor = MTLBlendFactor(rawValue: blend.destination)!
            color.sourceAlphaBlendFactor = MTLBlendFactor(rawValue: blend.sourceAlpha)!
            color.destinationAlphaBlendFactor = MTLBlendFactor(rawValue: blend.destinationAlpha)!
            color.rgbBlendOperation = MTLBlendOperation(rawValue: blend.equation)!
            color.alphaBlendOperation = MTLBlendOperation(rawValue: blend.equationAlpha)!
        }
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            throw ShaderError("Metal: the program does not build: \(error.localizedDescription)")
        }
    }
}

/// The JSON the C++ side writes (see Bridge/MSL.cpp and Bridge/GLSL.cpp).
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
