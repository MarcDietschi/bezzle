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
            _ = try program.pipeline(vertexLayout(draw, program).key(pixelFormat: .rgba8Unorm, samples: samples,
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

    /// What maps the drawing buffer onto the output.
    private struct Geometry {
        var size: (width: Double, height: Double)        // the drawing buffer
        var region: (x: Double, y: Double, width: Double, height: Double) // of it, top-left origin
        var output: (width: Double, height: Double)
    }

    private func encode(_ frame: ShaderFrame, into target: MTLTexture, region: CGRect?, commands: MTLCommandBuffer) throws {
        let size = (width: Double(frame.size.width), height: Double(frame.size.height))
        guard size.width > 0, size.height > 0 else { throw ShaderError("The drawing buffer is empty.") }
        let area = (region ?? CGRect(x: 0, y: 0, width: size.width, height: size.height)).standardized
        guard area.width > 0, area.height > 0 else { throw ShaderError("The region to draw is empty.") }
        let geometry = Geometry(size: size,
                                region: (Double(area.minX), Double(area.minY), Double(area.width), Double(area.height)),
                                output: (Double(target.width), Double(target.height)))
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

    /// The vertex buffers and their layout for a draw: arrays per vertex, disabled arrays and
    /// attributes the page never set as constants (WebGL's default is 0, 0, 0, 1).
    private struct VertexLayout {
        var attributes: [Program.AttributeLayout] = []
        var buffers: [(Int, [UInt8])] = []
        /// How many vertices the arrays hold; nil without arrays.
        var vertices: Int?

        func key(pixelFormat: MTLPixelFormat, samples: Int, blend: ShaderDraw.Blend?) -> Program.PipelineKey {
            Program.PipelineKey(attributes: attributes, pixelFormat: pixelFormat.rawValue, sampleCount: samples,
                                blend: blend.map(Program.BlendKey.init))
        }
    }

    private func vertexLayout(_ draw: ShaderDraw, _ program: Program) -> VertexLayout {
        var layout = VertexLayout()
        for (i, input) in program.inputs.enumerated() {
            let buffer = Program.firstVertexBuffer + i
            let columns = max(1, input.columns), rows = max(1, min(4, input.rows))
            if let attribute = draw.attributes[input.name], attribute.constant == nil, attribute.components > 0 {
                let components = attribute.components
                let vertices = attribute.values.count / components
                layout.vertices = min(layout.vertices ?? vertices, vertices)
                let width = columns > 1 ? rows : min(4, components)
                for column in 0..<columns {
                    layout.attributes.append(Program.AttributeLayout(
                        location: input.location + column, format: Self.format(input.base, width).rawValue,
                        buffer: buffer, offset: column * rows * 4, stride: components * 4, constant: false))
                }
                layout.buffers.append((buffer, Self.bytes(attribute.values, input.base)))
            } else {
                // Each column its own four numbers, defaults filling what the constant leaves out.
                let given = draw.attributes[input.name]?.constant ?? []
                var values: [Float] = []
                for column in 0..<columns {
                    var value: [Float] = [0, 0, 0, 1]
                    let per = columns > 1 ? rows : 4
                    for k in 0..<min(per, 4) where column * per + k < given.count { value[k] = given[column * per + k] }
                    values += value
                    layout.attributes.append(Program.AttributeLayout(
                        location: input.location + column, format: Self.format(input.base, 4).rawValue,
                        buffer: buffer, offset: column * 16, stride: 16 * columns, constant: true))
                }
                layout.buffers.append((buffer, Self.bytes(values, input.base)))
            }
        }
        return layout
    }

    private static func format(_ base: Program.Base, _ width: Int) -> MTLVertexFormat {
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

    private static func bytes(_ values: [Float], _ base: Program.Base) -> [UInt8] {
        switch base {
        case .float:
            return values.withUnsafeBytes { Array($0) }
        case .int:
            return values.map { Int32(clamping: Int64($0.isFinite ? $0.rounded(.towardZero) : 0)) }.withUnsafeBytes { Array($0) }
        case .uint:
            return values.map(Self.unsigned).withUnsafeBytes { Array($0) }
        }
    }

    static func unsigned(_ value: Float) -> UInt32 {
        guard value.isFinite else { return 0 }
        if value < 0 { return UInt32(bitPattern: Int32(clamping: Int64(value.rounded(.towardZero)))) }
        return UInt32(clamping: Int64(value.rounded(.towardZero)))
    }

    private func prepare(_ draw: ShaderDraw, geometry: Geometry, pixelFormat: MTLPixelFormat,
                         samples: Int) throws -> Prepared? {
        let program = try program(draw.vertex, draw.fragment)
        let layout = vertexLayout(draw, program)
        let pipeline = try program.pipeline(layout.key(pixelFormat: pixelFormat, samples: samples, blend: draw.blend),
                                            device: device)
        guard draw.count > 0, draw.first >= 0 else { return nil }

        // What WebGL would refuse to draw (reading past an array) draws nothing.
        let primitive: MTLPrimitiveType
        let call: Call
        if let indices = draw.indices {
            guard draw.first + draw.count <= indices.count else { return nil }
            let used = indices[draw.first..<(draw.first + draw.count)]
            if let vertices = layout.vertices, let top = used.lazy.filter({ $0 != .max }).max(), Int(top) >= vertices {
                return nil
            }
        } else if let vertices = layout.vertices, draw.first + draw.count > vertices {
            return nil
        }
        func indexBuffer(_ indices: [UInt32]) throws -> MTLBuffer {
            guard !indices.isEmpty,
                  let buffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            else { throw ShaderError("Metal: no index buffer.") }
            return buffer
        }
        /// The vertices drawn, in order: for fans and loops, which Metal does not draw.
        var vertexList: [UInt32] {
            if let indices = draw.indices { return Array(indices[draw.first..<(draw.first + draw.count)]) }
            return (0..<draw.count).map { UInt32(draw.first + $0) }
        }
        switch draw.mode {
        case .triangleFan:
            let vertexList = vertexList
            guard vertexList.count >= 3 else { return nil }
            var fan: [UInt32] = []
            fan.reserveCapacity((vertexList.count - 2) * 3)
            for i in 1..<(vertexList.count - 1) { fan += [vertexList[0], vertexList[i], vertexList[i + 1]] }
            primitive = .triangle
            call = .indexed(try indexBuffer(fan), offset: 0, count: fan.count)
        case .lineLoop:
            let vertexList = vertexList
            guard vertexList.count >= 2 else { return nil }
            let loop = vertexList + [vertexList[0]]
            primitive = .lineStrip
            call = .indexed(try indexBuffer(loop), offset: 0, count: loop.count)
        default:
            switch draw.mode {
            case .triangles: primitive = .triangle
            case .triangleStrip: primitive = .triangleStrip
            case .lines: primitive = .line
            case .lineStrip: primitive = .lineStrip
            default: primitive = .point
            }
            if let indices = draw.indices {
                call = .indexed(try indexBuffer(indices), offset: draw.first * 4, count: draw.count)
            } else {
                call = .arrays(start: draw.first, count: draw.count)
            }
        }

        // The viewport, and the region of the drawing buffer the output shows.
        let (W, H) = geometry.size
        let (rx, ry, rw, rh) = geometry.region
        let (w, h) = geometry.output
        let viewport = draw.viewport.map { $0.standardized }
        let vx = Double(viewport?.minX ?? 0), vy = Double(viewport?.minY ?? 0)
        let vw = Double(viewport?.width ?? CGFloat(W)), vh = Double(viewport?.height ?? CGFloat(H))
        guard vw > 0, vh > 0 else { return nil }
        // Clip space of the viewport onto clip space of the output; outside the viewport is cut.
        let clip: [Float] = [Float(vw / rw), Float(vh / rh), Float((2 * (vx - rx) + vw) / rw - 1),
                             Float(1 + (2 * vy + vh - 2 * (H - ry)) / rh)]
        let x0 = max(0, min(w, ((vx - rx) * w / rw).rounded()))
        let x1 = max(0, min(w, ((vx + vw - rx) * w / rw).rounded()))
        let y0 = max(0, min(h, ((H - vy - vh - ry) * h / rh).rounded()))
        let y1 = max(0, min(h, ((H - vy - ry) * h / rh).rounded()))
        guard x1 > x0, y1 > y0 else { return nil }
        let scissor = MTLScissorRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
        // gl_FragCoord from the output's pixels, top-left origin, to the drawing buffer's, bottom-left.
        let own: [String: [Float]] = [
            "bezzle_clip": clip,
            "bezzle_fragCoord": [Float(rw / w), Float(-rh / h), Float(rx), Float(H - ry)],
            "bezzle_pointScale": [Float((w / rw + h / rh) / 2)],
        ]
        let values = Uniforms(draw.uniforms, own: own)

        var vertexBuffers: [(Int, VertexData)] = []
        for (index, bytes) in layout.buffers {
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
                        vertexUniforms: program.vertex.buffers.map { ($0.index, values.pack($0)) },
                        fragmentUniforms: program.fragment.buffers.map { ($0.index, values.pack($0)) },
                        vertexBuffers: vertexBuffers,
                        vertexTextures: try bind(program.vertex.textures, draw),
                        fragmentTextures: try bind(program.fragment.textures, draw),
                        scissor: scissor, primitive: primitive, call: call,
                        blendColor: draw.blend?.color)
    }

    private func bind(_ list: [Program.Texture], _ draw: ShaderDraw) throws -> [(Int, MTLTexture, MTLSamplerState)] {
        var bound: [(Int, MTLTexture, MTLSamplerState)] = []
        for texture in list {
            for element in 0..<max(1, texture.count) {
                let name = texture.count > 1 ? "\(texture.name)[\(element)]" : texture.name
                let image = draw.textures[name] ?? (element == 0 ? draw.textures[texture.name] ?? draw.textures["\(texture.name)[0]"] : nil)
                let sampling = draw.sampling[name] ?? draw.sampling[texture.name] ?? ShaderDraw.Sampling()
                let metal = try image.map {
                    try textures.texture($0, flip: draw.flipsTextures, premultiply: draw.premultipliesTextures,
                                         mipmaps: sampling.mipmap != nil, cube: texture.cube)
                } ?? textures.blank(cube: texture.cube)
                bound.append((texture.index + element, metal, try sampler(sampling)))
            }
        }
        return bound
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

/// A draw's uniform values, written into a uniform block as its layout says.
struct Uniforms {
    let values: [String: [Float]]
    let own: [String: [Float]]
    /// "u_colors[2]" and the like, by "u_colors": each element given on its own, in order.
    let elements: [String: [(Int, [Float])]]

    init(_ values: [String: [Float]], own: [String: [Float]] = [:]) {
        self.values = values
        self.own = own
        var elements: [String: [(Int, [Float])]] = [:]
        for (key, value) in values where key.hasSuffix("]") {
            guard let open = key.lastIndex(of: "["),
                  let index = Int(key[key.index(after: open)..<key.index(before: key.endIndex)]) else { continue }
            elements[String(key[..<open]), default: []].append((index, value))
        }
        self.elements = elements.mapValues { $0.sorted { $0.0 < $1.0 } }
    }

    func pack(_ buffer: Program.Buffer) -> [UInt8] {
        // Metal rounds a struct's size up to its alignment, which in a uniform block is at most 16.
        var bytes = [UInt8](repeating: 0, count: (max(16, buffer.size) + 15) / 16 * 16)
        bytes.withUnsafeMutableBytes { raw in
            for member in buffer.members { write(member, into: raw) }
        }
        return bytes
    }

    private func write(_ member: Program.Member, into raw: UnsafeMutableRawBufferPointer) {
        let size = max(1, member.rows * member.columns)
        func store(_ element: Int, _ numbers: ArraySlice<Float>) {
            guard element < member.count else { return }
            for (k, value) in numbers.prefix(size).enumerated() {
                let column = k / member.rows, row = k % member.rows
                var offset = member.offset + element * member.arrayStride
                if member.columns > 1 {
                    offset += member.rowMajor ? row * member.matrixStride + column * 4 : column * member.matrixStride + row * 4
                } else {
                    offset += k * 4
                }
                guard offset >= 0, offset + 4 <= raw.count else { continue }
                switch member.base {
                case .float: raw.storeBytes(of: value, toByteOffset: offset, as: Float.self)
                case .int:
                    raw.storeBytes(of: Int32(clamping: Int64(value.isFinite ? value.rounded(.towardZero) : 0)),
                                   toByteOffset: offset, as: Int32.self)
                case .uint: raw.storeBytes(of: ShaderRenderer.unsigned(value), toByteOffset: offset, as: UInt32.self)
                }
            }
        }
        /// Elements from `first` on, as many as `numbers` holds.
        func fill(from first: Int, _ numbers: [Float]) {
            var element = first, start = 0
            while start < numbers.count && element < member.count {
                store(element, numbers[start..<min(numbers.count, start + size)])
                start += size
                element += 1
            }
        }
        if let whole = own[member.name] ?? values[member.name] { fill(from: 0, whole) }
        for (index, numbers) in elements[member.name] ?? [] { fill(from: index, numbers) }
    }
}
