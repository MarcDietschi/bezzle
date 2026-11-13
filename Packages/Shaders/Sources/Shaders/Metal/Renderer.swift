import CoreGraphics
import Foundation
import Metal

/// Draws recorded WebGL frames with Metal, at any size and in tiles, from any thread.
///
/// Programs (their translation, Metal functions and pipeline states), pictures uploaded as
/// textures and sampler states are kept by what they are made of, so the tiles of one frame
/// and the frames after it make each once.
public final class ShaderRenderer: @unchecked Sendable {
    /// nil where Metal is not available.
    public static let shared: ShaderRenderer? = ShaderRenderer()

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let programs = OnceCache<ProgramKey, Program>(capacity: 64)
    private let samplers = OnceCache<ShaderDraw.Sampling, MTLSamplerState>(capacity: 64)
    private let finishers = OnceCache<FinisherKey, MTLRenderPipelineState>(capacity: 16)
    private let textures: Textures
    private let memoryless: Bool

    private struct ProgramKey: Hashable {
        var vertex: String
        var fragment: String
    }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        textures = Textures(device: device, queue: queue)
        memoryless = device.hasUnifiedMemory && device.supportsFamily(.apple1)
    }

    // MARK: The API

    /// What the program takes, as WebGL names it. Throws when it does not translate or build.
    public func interface(of vertex: String, _ fragment: String) throws -> ShaderInterface {
        try program(vertex, fragment).interface
    }

    /// Throws when a program does not translate or build.
    public func check(_ frame: ShaderFrame) throws {
        let samples = sampleCount(frame)
        for draw in frame.draws {
            let program = try program(draw.vertex, draw.fragment)
            _ = try program.pipeline(pipelineKey(vertexLayout(draw, program), pixelFormat: .rgba8Unorm, samples: samples,
                                                 blend: draw.blend), device: device)
        }
    }

    /// `region` (drawing-buffer pixels, top-left origin; nil: all of it) drawn `pixels` big.
    /// Top row first, RGBA premultiplied as the canvas composites it, in sRGB.
    public func image(of frame: ShaderFrame, pixels: CGSize, region: CGRect? = nil) throws -> CGImage {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw ShaderError("No picture can be \(width) by \(height) pixels.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let target = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else {
            throw ShaderError("Metal: out of memory for a picture of \(width) by \(height).")
        }
        try encode(frame, into: target, region: region, commands: commands)
        guard let blit = commands.makeBlitCommandEncoder() else { throw ShaderError("Metal: no blit encoder.") }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw ShaderError("Metal: the frame did not draw: \(error.localizedDescription)")
        }
        // The picture reads the buffer's memory where it is, and lets go of it when it goes.
        let info = Unmanaged.passRetained(buffer as AnyObject).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: buffer.contents(), size: bytesPerRow * height,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
                                            }),
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ShaderError("The frame's picture could not be made.") }
        return image
    }

    /// The same into a texture the caller owns (a 2D render target, BGRA8 or RGBA8 and not sRGB,
    /// from `device`), for the film's stage and movies. Encodes into `commandBuffer`; the caller
    /// commits it. Throws before encoding anything when a program does not translate or build.
    public func draw(_ frame: ShaderFrame, into texture: MTLTexture, region: CGRect? = nil,
                     commandBuffer: MTLCommandBuffer) throws {
        guard texture.textureType == .type2D, texture.usage.contains(.renderTarget) else {
            throw ShaderError("The texture to draw into is not a 2D render target.")
        }
        try encode(frame, into: texture, region: region, commands: commandBuffer)
    }

    // MARK: Encoding

    private func sampleCount(_ frame: ShaderFrame) -> Int {
        frame.antialias && device.supportsTextureSampleCount(4) ? 4 : 1
    }

    private func program(_ vertex: String, _ fragment: String) throws -> Program {
        try programs.value(ProgramKey(vertex: vertex, fragment: fragment)) {
            try Program(device: device, vertex: vertex, fragment: fragment)
        }
    }

    private func encode(_ frame: ShaderFrame, into target: MTLTexture, region: CGRect?, commands: MTLCommandBuffer) throws {
        let geometry = try Geometry(frame, region: region, output: target.width, target.height)
        let samples = sampleCount(frame)
        // Everything made first, so a program that does not build throws before anything is encoded.
        var prepared: [Prepared] = []
        for draw in frame.draws {
            if let ready = try prepare(draw, geometry: geometry, pixelFormat: target.pixelFormat, samples: samples) {
                prepared.append(ready)
            }
        }
        let finishing: [MTLRenderPipelineState] = try {
            if !frame.alpha { return [try finisher(.opaque, target.pixelFormat, samples)] }
            if !frame.premultipliedAlpha { return [try finisher(.premultiply, target.pixelFormat, samples)] }
            return []
        }()

        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        var keep: [AnyObject] = []
        if samples > 1 {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DMultisample
            descriptor.pixelFormat = target.pixelFormat
            descriptor.width = target.width
            descriptor.height = target.height
            descriptor.sampleCount = samples
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = memoryless ? .memoryless : .private
            guard let multisampled = device.makeTexture(descriptor: descriptor) else {
                throw ShaderError("Metal: out of memory for the frame's samples.")
            }
            color.texture = multisampled
            color.resolveTexture = target
            color.storeAction = .multisampleResolve
            keep.append(multisampled)
        } else {
            color.texture = target
            color.storeAction = .store
        }
        color.loadAction = .clear
        let clear = (frame.clear ?? []) + [0, 0, 0, 0]
        color.clearColor = MTLClearColor(red: Double(clear[0]), green: Double(clear[1]), blue: Double(clear[2]),
                                         alpha: Double(clear[3]))
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw ShaderError("Metal: no render encoder.")
        }
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: geometry.output.width,
                                        height: geometry.output.height, znear: 0, zfar: 1))
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        for draw in prepared {
            draw.encode(encoder)
            keep.append(contentsOf: draw.resources)
        }
        if !finishing.isEmpty {
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
            for pipeline in finishing {
                encoder.setRenderPipelineState(pipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        encoder.endEncoding()
        // Keeps what the encoder points at until the GPU is done, whatever the caller's buffer retains.
        let kept = Kept(keep)
        commands.addCompletedHandler { _ in withExtendedLifetime(kept) {} }
    }

    /// Metal objects held until a command buffer is done; only held, never used, on any thread.
    private final class Kept: @unchecked Sendable {
        let objects: [AnyObject]
        init(_ objects: [AnyObject]) { self.objects = objects }
    }

    // MARK: One draw

    private enum VertexData {
        case bytes([UInt8])
        case buffer(MTLBuffer)
    }

    private enum Call {
        case arrays(start: Int, count: Int)
        case indexed(MTLBuffer, offset: Int, count: Int)
    }

    private struct Prepared {
        var pipeline: MTLRenderPipelineState
        var vertexUniforms: [(Int, [UInt8])]
        var fragmentUniforms: [(Int, [UInt8])]
        var vertexBuffers: [(Int, VertexData)]
        var vertexTextures: [(Int, MTLTexture, MTLSamplerState)]
        var fragmentTextures: [(Int, MTLTexture, MTLSamplerState)]
        var scissor: MTLScissorRect
        var primitive: MTLPrimitiveType
        var call: Call
        var blendColor: [Float]?

        var resources: [AnyObject] {
            var objects: [AnyObject] = [pipeline]
            for (_, data) in vertexBuffers { if case .buffer(let buffer) = data { objects.append(buffer) } }
            if case .indexed(let buffer, _, _) = call { objects.append(buffer) }
            for (_, texture, sampler) in vertexTextures + fragmentTextures { objects += [texture, sampler] }
            return objects
        }

        func encode(_ encoder: MTLRenderCommandEncoder) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setScissorRect(scissor)
            if let blendColor {
                let c = blendColor + [0, 0, 0, 0]
                encoder.setBlendColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
            }
            for (index, bytes) in vertexUniforms {
                bytes.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: index) }
            }
            for (index, bytes) in fragmentUniforms {
                bytes.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: index) }
            }
            for (index, data) in vertexBuffers {
                switch data {
                case .bytes(let bytes):
                    bytes.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: index) }
                case .buffer(let buffer):
                    encoder.setVertexBuffer(buffer, offset: 0, index: index)
                }
            }
            for (index, texture, sampler) in vertexTextures {
                encoder.setVertexTexture(texture, index: index)
                encoder.setVertexSamplerState(sampler, index: index)
            }
            for (index, texture, sampler) in fragmentTextures {
                encoder.setFragmentTexture(texture, index: index)
                encoder.setFragmentSamplerState(sampler, index: index)
            }
            switch call {
            case .arrays(let start, let count):
                encoder.drawPrimitives(type: primitive, vertexStart: start, vertexCount: count)
            case .indexed(let buffer, let offset, let count):
                encoder.drawIndexedPrimitives(type: primitive, indexCount: count, indexType: .uint32, indexBuffer: buffer,
                                              indexBufferOffset: offset)
            }
        }
    }

    private func vertexLayout(_ draw: ShaderDraw, _ program: Program) -> VertexLayout {
        VertexLayout(draw, program.layout, firstBuffer: Program.firstVertexBuffer)
    }

    private func pipelineKey(_ layout: VertexLayout, pixelFormat: MTLPixelFormat, samples: Int,
                             blend: ShaderDraw.Blend?) -> Program.PipelineKey {
        Program.PipelineKey(attributes: layout.attributes, pixelFormat: pixelFormat.rawValue, sampleCount: samples,
                            blend: blend.map(Program.BlendKey.init))
    }

    private func prepare(_ draw: ShaderDraw, geometry: Geometry, pixelFormat: MTLPixelFormat,
                         samples: Int) throws -> Prepared? {
        let program = try program(draw.vertex, draw.fragment)
        let layout = vertexLayout(draw, program)
        let pipeline = try program.pipeline(pipelineKey(layout, pixelFormat: pixelFormat, samples: samples, blend: draw.blend),
                                            device: device)
        guard let plan = DrawPlan(draw, program: program.layout, layout: layout, geometry: geometry) else { return nil }

        let primitive: MTLPrimitiveType = switch plan.primitive {
        case .triangle: .triangle
        case .triangleStrip: .triangleStrip
        case .line: .line
        case .lineStrip: .lineStrip
        case .point: .point
        }
        let call: Call
        switch plan.call {
        case .arrays(let start, let count):
            call = .arrays(start: start, count: count)
        case .indexed(let indices, let first, let count):
            guard !indices.isEmpty,
                  let buffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            else { throw ShaderError("Metal: no index buffer.") }
            call = .indexed(buffer, offset: first * 4, count: count)
        }
        let scissor = MTLScissorRect(x: plan.scissor.x, y: plan.scissor.y, width: plan.scissor.width,
                                     height: plan.scissor.height)

        var vertexBuffers: [(Int, VertexData)] = []
        for (index, bytes) in plan.vertexBuffers {
            if bytes.count <= 4096 {
                vertexBuffers.append((index, .bytes(bytes)))
            } else {
                guard let buffer = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared) else {
                    throw ShaderError("Metal: no vertex buffer.")
                }
                vertexBuffers.append((index, .buffer(buffer)))
            }
        }
        return Prepared(pipeline: pipeline,
                        vertexUniforms: plan.vertexUniforms,
                        fragmentUniforms: plan.fragmentUniforms,
                        vertexBuffers: vertexBuffers,
                        vertexTextures: try bind(plan.vertexTextures, plan),
                        fragmentTextures: try bind(plan.fragmentTextures, plan),
                        scissor: scissor, primitive: primitive, call: call,
                        blendColor: plan.blendColor)
    }

    private func bind(_ list: [DrawPlan.Texture], _ plan: DrawPlan) throws -> [(Int, MTLTexture, MTLSamplerState)] {
        try list.map { texture in
            let metal = try texture.picture.map {
                try textures.texture($0, flip: plan.flipsTextures, premultiply: plan.premultipliesTextures,
                                     mipmaps: texture.sampling.mipmap != nil, cube: texture.cube)
            } ?? textures.blank(cube: texture.cube)
            return (texture.slot, metal, try sampler(texture.sampling))
        }
    }

    private func sampler(_ sampling: ShaderDraw.Sampling) throws -> MTLSamplerState {
        try samplers.value(sampling) {
            func address(_ wrap: ShaderDraw.Sampling.Wrap) -> MTLSamplerAddressMode {
                switch wrap {
                case .repeat: .repeat
                case .clampToEdge: .clampToEdge
                case .mirroredRepeat: .mirrorRepeat
                }
            }
            func filter(_ filter: ShaderDraw.Sampling.Filter) -> MTLSamplerMinMagFilter {
                filter == .nearest ? .nearest : .linear
            }
            let descriptor = MTLSamplerDescriptor()
            descriptor.sAddressMode = address(sampling.wrapS)
            descriptor.tAddressMode = address(sampling.wrapT)
            descriptor.rAddressMode = .clampToEdge
            descriptor.magFilter = filter(sampling.magnify)
            descriptor.minFilter = filter(sampling.minify)
            switch sampling.mipmap {
            case nil: descriptor.mipFilter = .notMipmapped
            case .nearest?: descriptor.mipFilter = .nearest
            case .linear?: descriptor.mipFilter = .linear
            }
            guard let state = device.makeSamplerState(descriptor: descriptor) else {
                throw ShaderError("Metal: no sampler state.")
            }
            return state
        }
    }

    // MARK: Finishing

    private enum Finishing: Hashable { case opaque, premultiply }

    private struct FinisherKey: Hashable {
        var kind: Finishing
        var pixelFormat: UInt
        var samples: Int
    }

    private static let finishingSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct Cover { float4 position [[position]]; };
        vertex Cover bezzle_cover(uint id [[vertex_id]]) {
            float2 p = float2(float((id << 1) & 2), float(id & 2));
            Cover cover;
            cover.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return cover;
        }
        fragment float4 bezzle_opaque() { return float4(0.0, 0.0, 0.0, 1.0); }
        """

    /// A pass over the whole output after the draws: alpha made 1 (`alpha: false`), or the
    /// colours multiplied by it (`premultipliedAlpha: false`), by blending alone.
    private func finisher(_ kind: Finishing, _ pixelFormat: MTLPixelFormat, _ samples: Int) throws -> MTLRenderPipelineState {
        try finishers.value(FinisherKey(kind: kind, pixelFormat: pixelFormat.rawValue, samples: samples)) {
            let library = try device.makeLibrary(source: Self.finishingSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "bezzle_cover")
            descriptor.fragmentFunction = library.makeFunction(name: "bezzle_opaque")
            descriptor.rasterSampleCount = samples
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = pixelFormat
            switch kind {
            case .opaque:
                color.writeMask = .alpha
            case .premultiply:
                color.writeMask = [.red, .green, .blue]
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.sourceRGBBlendFactor = .zero
                color.destinationRGBBlendFactor = .destinationAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
    }
}
