import Foundation
import ShaderDirect3D

/// Draws recorded WebGL frames with Direct3D 11, at any size and in tiles, from any thread: the
/// Mac's ShaderRenderer on Windows. Every draw is worked out as on the Mac (`DrawPlan`), so the
/// two draw the same; on a PC without a graphics card that does Direct3D 11, WARP, Windows' own
/// renderer on the processor, draws instead.
///
/// Programs (their translation, stages and input layouts), pictures uploaded as textures, blend
/// and sampler states are kept by what they are made of, so the tiles of one frame and the frames
/// after it make each once.
public final class ShaderRenderer: @unchecked Sendable {
    /// nil where Direct3D 11 is not available.
    public static let shared: ShaderRenderer? = ShaderRenderer()

    /// What draws: the graphics card's name, or "WARP" for the processor.
    public let adapter: String
    let device: OpaquePointer
    private let programs = OnceCache<ProgramKey, Program>(capacity: 64)
    private let samplers = OnceCache<ShaderDraw.Sampling, Handle>(capacity: 64)
    private let blends = OnceCache<BlendKey, Handle>(capacity: 64)
    private let textures: Textures
    private let multisamples: Bool

    /// Points no larger than Metal draws them, in output pixels.
    static let largestPoint: Float = 511

    private struct ProgramKey: Hashable {
        var vertex: String
        var fragment: String
    }

    private struct BlendKey: Hashable {
        var factors: [Int32]
    }

    /// With `software`, on the processor (WARP) even where there is a graphics card.
    public init?(software: Bool = false) {
        var name = [CChar](repeating: 0, count: 256)
        guard let device = bz_d3d_open(software ? 1 : 0, &name, Int32(name.count)) else { return nil }
        self.device = device
        adapter = String(cString: name)
        textures = Textures(device: device)
        multisamples = bz_d3d_samples(device, 4) != 0
    }

    deinit { bz_d3d_close(device) }

    // MARK: The API

    /// What the program takes, as WebGL names it. Throws when it does not translate or build.
    public func interface(of vertex: String, _ fragment: String) throws -> ShaderInterface {
        try program(vertex, fragment).interface
    }

    /// Throws when a program does not translate or build, or the frame has what Direct3D does
    /// not draw yet (README, What WebGL does that this does not): the caller shows its picture.
    public func check(_ frame: ShaderFrame) throws {
        try refuse(frame)
        for draw in frame.everyPass.flatMap(\.draws) {
            let program = try program(draw.vertex, draw.fragment)
            _ = try program.inputLayout(VertexLayout(draw, program.layout, firstBuffer: 0).attributes, device: device)
            if let blend = draw.blend { _ = try blendState(blend) }
        }
    }

    /// `region` (drawing-buffer pixels, top-left origin; nil: all of it) drawn `pixels` big.
    /// Top row first, RGBA premultiplied as the canvas composites it, in sRGB.
    ///
    /// `earlier` is the Mac's, for frames that build on the frames before them, which Direct3D
    /// does not draw yet.
    public func image(of frame: ShaderFrame, pixels: CGSize, region: CGRect? = nil,
                      earlier: ((Int) throws -> ShaderFrame)? = nil) throws -> ShaderPicture {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw ShaderError("No picture can be \(width) by \(height) pixels.")
        }
        try refuse(frame)
        let pass = frame.everyPass[0]
        let geometry = try Geometry(frame, region: region, output: width, height)
        // Everything made first, so a program that does not build throws before anything is drawn.
        var prepared: [Prepared] = []
        for draw in pass.draws {
            if let ready = try prepare(draw, geometry: geometry) { prepared.append(ready) }
        }
        let arena = Arena()
        let draws = prepared.map { $0.described(in: arena) }
        let clear = (pass.clearColor ?? []) + [0, 0, 0, 0]
        var description = BZD3DFrame(
            width: Int32(width), height: Int32(height), samples: frame.antialias && multisamples ? 4 : 1,
            clear: (clear[0], clear[1], clear[2], clear[3]),
            finish: !frame.alpha ? 1 : !frame.premultipliedAlpha ? 2 : 0,
            largestPoint: Self.largestPoint, draws: arena.copy(draws), drawCount: Int32(draws.count))
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var message: UnsafeMutablePointer<CChar>?
        // The description points into the arena, and at what the prepared draws hold.
        let done = withExtendedLifetime((arena, prepared)) {
            out.withUnsafeMutableBytes { bz_d3d_draw(device, &description, $0.baseAddress, &message) }
        }
        guard done == 1 else {
            let why = taken(message)
            throw ShaderError(why.isEmpty ? "Direct3D: the frame did not draw." : why)
        }
        return ShaderPicture(width: width, height: height, pixels: out)
    }

    /// Passes into textures, depth and stencil, instances and the rest of what the Mac draws
    /// since 2026-11-14 are not drawn here yet: refused by name, before anything is made.
    private func refuse(_ frame: ShaderFrame) throws {
        if let fault = frame.fault() { throw ShaderError(fault) }
        if let what = frame.beyondPlainDraws { throw ShaderError("Direct3D does not draw \(what) yet.") }
    }

    // MARK: One draw

    private func program(_ vertex: String, _ fragment: String) throws -> Program {
        try programs.value(ProgramKey(vertex: vertex, fragment: fragment)) {
            try Program(device: device, vertex: vertex, fragment: fragment)
        }
    }

    /// A draw with everything Direct3D needs made, held until it is drawn.
    private struct Prepared {
        var program: Program
        var layout: Handle?
        var blend: Handle?
        var blendColor: [Float]
        var topology: Int32
        var scissor: DrawPlan.Scissor
        var vertexBuffers: [(slot: Int, bytes: [UInt8], stride: Int)]
        var indices: [UInt32]?
        var first: Int
        var count: Int
        var vertexConstants: [(Int, [UInt8])]
        var pixelConstants: [(Int, [UInt8])]
        var vertexTextures: [(Int, Handle, Handle)]
        var pixelTextures: [(Int, Handle, Handle)]

        func described(in arena: Arena) -> BZD3DDraw {
            func bytes(_ list: [(Int, [UInt8])]) -> UnsafePointer<BZD3DBytes>? {
                arena.copy(list.map { BZD3DBytes(slot: Int32($0.0), bytes: arena.raw($0.1), count: Int32($0.1.count), stride: 0) })
            }
            func textures(_ list: [(Int, Handle, Handle)]) -> UnsafePointer<BZD3DTexture>? {
                arena.copy(list.map { BZD3DTexture(slot: Int32($0.0), texture: $0.1.pointer, sampler: $0.2.pointer) })
            }
            let vertices = vertexBuffers.map {
                BZD3DBytes(slot: Int32($0.slot), bytes: arena.raw($0.bytes), count: Int32($0.bytes.count), stride: Int32($0.stride))
            }
            let color = blendColor + [0, 0, 0, 0]
            return BZD3DDraw(
                program: program.handle.pointer, layout: layout?.pointer, blend: blend?.pointer,
                blendColor: (color[0], color[1], color[2], color[3]), topology: topology,
                scissor: (Int32(scissor.x), Int32(scissor.y), Int32(scissor.width), Int32(scissor.height)),
                vertices: arena.copy(vertices), vertexBufferCount: Int32(vertices.count),
                indices: indices.flatMap { arena.copy($0) }, indexCount: Int32(indices?.count ?? 0),
                first: Int32(first), count: Int32(count),
                vertexConstants: bytes(vertexConstants), vertexConstantCount: Int32(vertexConstants.count),
                pixelConstants: bytes(pixelConstants), pixelConstantCount: Int32(pixelConstants.count),
                vertexTextures: textures(vertexTextures), vertexTextureCount: Int32(vertexTextures.count),
                pixelTextures: textures(pixelTextures), pixelTextureCount: Int32(pixelTextures.count))
        }
    }

    private func prepare(_ draw: ShaderDraw, geometry: Geometry) throws -> Prepared? {
        let program = try program(draw.vertex, draw.fragment)
        let layout = VertexLayout(draw, program.layout, firstBuffer: 0)
        let inputLayout = try program.inputLayout(layout.attributes, device: device)
        let blend = try draw.blend.map(blendState)
        guard let plan = DrawPlan(draw, program: program.layout, layout: layout, geometry: geometry) else { return nil }

        let topology: Int32 = switch plan.primitive {
        case .triangle: 0
        case .triangleStrip: 1
        case .line: 2
        case .lineStrip: 3
        case .point: 4
        }
        var indices: [UInt32]?
        let first: Int, count: Int
        switch plan.call {
        case .arrays(let start, let n):
            first = start
            count = n
        case .indexed(let list, let start, let n):
            indices = list
            first = start
            count = n
        }
        var strides: [Int: Int] = [:]
        for attribute in layout.attributes { strides[attribute.buffer] = attribute.stride }
        let vertexBuffers = plan.vertexBuffers.map { (slot: $0.0, bytes: $0.1, stride: strides[$0.0] ?? 16) }
        return Prepared(program: program, layout: inputLayout, blend: blend, blendColor: Self.blendColor(draw.blend),
                        topology: topology, scissor: plan.scissor, vertexBuffers: vertexBuffers, indices: indices,
                        first: first, count: count, vertexConstants: plan.vertexUniforms,
                        pixelConstants: plan.fragmentUniforms,
                        vertexTextures: try bind(plan.vertexTextures, plan),
                        pixelTextures: try bind(plan.fragmentTextures, plan))
    }

    private func bind(_ list: [DrawPlan.Texture], _ plan: DrawPlan) throws -> [(Int, Handle, Handle)] {
        try list.map { texture in
            let made = try texture.picture.map {
                try textures.texture($0, flip: plan.flipsTextures, premultiply: plan.premultipliesTextures,
                                     mipmaps: texture.sampling.mipmap != nil, cube: texture.cube)
            } ?? textures.blank(cube: texture.cube)
            return (texture.slot, made, try sampler(texture.sampling))
        }
    }

    private func sampler(_ sampling: ShaderDraw.Sampling) throws -> Handle {
        try samplers.value(sampling) {
            func wrap(_ wrap: ShaderDraw.Sampling.Wrap) -> Int32 {
                switch wrap {
                case .repeat: 0
                case .clampToEdge: 1
                case .mirroredRepeat: 2
                }
            }
            func filter(_ filter: ShaderDraw.Sampling.Filter) -> Int32 { filter == .nearest ? 0 : 1 }
            guard let made = bz_d3d_sampler(device, wrap(sampling.wrapS), wrap(sampling.wrapT), filter(sampling.magnify),
                                            filter(sampling.minify), sampling.mipmap.map(filter) ?? -1) else {
                throw ShaderError("Direct3D: no sampler state.")
            }
            return Handle(made)
        }
    }

    private func blendState(_ blend: ShaderDraw.Blend) throws -> Handle {
        let factors = [Self.number(blend.source), Self.number(blend.destination), Self.number(blend.sourceAlpha),
                       Self.number(blend.destinationAlpha), Self.number(blend.equation), Self.number(blend.equationAlpha)]
        return try blends.value(BlendKey(factors: factors)) {
            guard let made = bz_d3d_blend(device, factors) else {
                throw ShaderError("Direct3D: the program does not build: no blend state.")
            }
            return Handle(made)
        }
    }

    /// blendColor as Direct3D takes it: it has one constant, so where the colour's factors take
    /// the constant's alpha (CONSTANT_ALPHA) and none its colour, it is the alpha four times.
    private static func blendColor(_ blend: ShaderDraw.Blend?) -> [Float] {
        guard let blend else { return [0, 0, 0, 0] }
        let color = blend.color + [0, 0, 0, 0]
        let factors = [blend.source, blend.destination, blend.sourceAlpha, blend.destinationAlpha]
        let takesColor = factors.contains { $0 == .constantColor || $0 == .oneMinusConstantColor }
        let takesAlpha = [blend.source, blend.destination].contains { $0 == .constantAlpha || $0 == .oneMinusConstantAlpha }
        return takesAlpha && !takesColor ? [color[3], color[3], color[3], color[3]] : Array(color.prefix(4))
    }

    /// As ShaderDirect3D.h numbers them: in the order of ShaderDraw.Blend.Factor and .Equation.
    private static func number(_ factor: ShaderDraw.Blend.Factor) -> Int32 {
        switch factor {
        case .zero: 0
        case .one: 1
        case .sourceColor: 2
        case .oneMinusSourceColor: 3
        case .destinationColor: 4
        case .oneMinusDestinationColor: 5
        case .sourceAlpha: 6
        case .oneMinusSourceAlpha: 7
        case .destinationAlpha: 8
        case .oneMinusDestinationAlpha: 9
        case .constantColor: 10
        case .oneMinusConstantColor: 11
        case .constantAlpha: 12
        case .oneMinusConstantAlpha: 13
        case .sourceAlphaSaturate: 14
        }
    }

    private static func number(_ equation: ShaderDraw.Blend.Equation) -> Int32 {
        switch equation {
        case .add: 0
        case .subtract: 1
        case .reverseSubtract: 2
        case .min: 3
        case .max: 4
        }
    }
}

/// Memory for the C description of a frame, let go of when the frame is drawn.
final class Arena {
    private var blocks: [UnsafeMutableRawPointer] = []

    func copy<T>(_ values: [T]) -> UnsafePointer<T>? {
        guard !values.isEmpty else { return nil }
        let block = UnsafeMutablePointer<T>.allocate(capacity: values.count)
        block.initialize(from: values, count: values.count)
        blocks.append(UnsafeMutableRawPointer(block))
        return UnsafePointer(block)
    }

    func raw(_ bytes: [UInt8]) -> UnsafeRawPointer? {
        copy(bytes).map(UnsafeRawPointer.init)
    }

    deinit {
        for block in blocks { block.deallocate() }
    }
}
