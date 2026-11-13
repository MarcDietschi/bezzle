import Foundation
import Metal
import ShaderCompiler

/// A WebGL program translated to Metal: its two functions and its layout (`ProgramLayout`),
/// every name as the page wrote it.
final class Program: @unchecked Sendable {
    let layout: ProgramLayout
    let vertexFunction: MTLFunction
    let fragmentFunction: MTLFunction
    /// How long glslang and SPIRV-Cross took, and the Metal compiler after them, in seconds.
    let translationTime: Double
    let buildTime: Double

    var interface: ShaderInterface { layout.interface }

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
        var original = vertexShader.original
        original.merge(fragmentShader.original) { first, _ in first }
        layout = try ProgramLayout(reflection: String(cString: json), original: original)
        translationTime = Date().timeIntervalSince(start)
        if layout.inputs.count > 31 - Program.firstVertexBuffer {
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

    static func format(_ base: ProgramLayout.Base, _ width: Int) -> MTLVertexFormat {
        switch (base, width) {
        case (.float, 1): .float
        case (.float, 2): .float2
        case (.float, 3): .float3
        case (.float, _): .float4
        case (.int, 1): .int
        case (.int, 2): .int2
        case (.int, 3): .int3
        case (.int, _): .int4
        case (.uint, 1): .uint
        case (.uint, 2): .uint2
        case (.uint, 3): .uint3
        case (.uint, _): .uint4
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
            vertexDescriptor.attributes[attribute.location].format = Self.format(attribute.base, attribute.width)
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
