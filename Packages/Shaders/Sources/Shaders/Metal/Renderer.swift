import CoreGraphics
import Foundation
import Metal

/// Draws recorded WebGL frames with Metal, at any size and in tiles, from any thread.
///
/// Programs (their translation, Metal functions and pipeline states), pictures uploaded as
/// textures and sampler states are kept by what they are made of, so the tiles of one frame
/// and the frames after it make each once. What a frame's passes draw into targets is drawn once
/// for all its tiles (`Drawn`), and what its targets keep for the frame after is kept step by
/// step (`Timelines`).
public final class ShaderRenderer: @unchecked Sendable {
    /// nil where Metal is not available.
    public static let shared: ShaderRenderer? = ShaderRenderer()

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let programs = OnceCache<ProgramKey, Program>(capacity: 256)
    private let samplers = OnceCache<ShaderDraw.Sampling, MTLSamplerState>(capacity: 64)
    private let finishers = OnceCache<FinisherKey, MTLRenderPipelineState>(capacity: 16)
    private let depthStates = OnceCache<DepthKey, MTLDepthStencilState>(capacity: 128)
    private let textures: Textures
    private let pool: TexturePool
    private let timelines = Timelines()
    /// What the passes of the frames drawn last left in their targets, at most 512 MB of it.
    private let drawn = OnceCache<DrawnKey, Drawn>(capacity: 32, budget: 512 << 20, keepsFailures: false, cost: { $0.cost })
    private let memoryless: Bool

    private struct ProgramKey: Hashable {
        var vertex: String
        var fragment: String
    }

    private struct DrawnKey: Hashable {
        var identity: ShaderFrame.Identity
        var scale: Int
    }

    private struct DepthKey: Hashable {
        var depth: ShaderDraw.Depth?
        var stencil: ShaderDraw.Stencil?
    }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        textures = Textures(device: device, queue: queue)
        pool = TexturePool(device: device)
        memoryless = device.hasUnifiedMemory && device.supportsFamily(.apple1)
    }

    // MARK: The API

    /// What the program takes, as WebGL names it. Throws when it does not translate or build.
    public func interface(of vertex: String, _ fragment: String) throws -> ShaderInterface {
        try program(vertex, fragment).interface
    }

    /// Throws when a program does not translate or build, or the frame's passes name what it
    /// does not have.
    public func check(_ frame: ShaderFrame) throws {
        if let fault = frame.fault() { throw ShaderError(fault) }
        let samples = sampleCount(frame)
        let canvasDepth = frame.canvasTestsDepth
        for pass in frame.everyPass {
            let formats: [MTLPixelFormat] = pass.ontoCanvas ? [.rgba8Unorm] : pass.colors.map { Textures.format(frame.targets[$0].format).0 }
            let opaque = pass.ontoCanvas ? [false] : pass.colors.map { frame.targets[$0].opaque }
            for draw in pass.draws {
                let program = try program(draw.vertex, draw.fragment)
                let key = pipelineKey(vertexLayout(draw, program), program, draw, formats: formats, opaque: opaque,
                                      depth: pass.ontoCanvas ? canvasDepth : pass.depth != nil,
                                      samples: pass.ontoCanvas ? samples : 1)
                _ = try program.pipeline(key, device: device)
            }
        }
    }

    /// `region` (drawing-buffer pixels, top-left origin; nil: all of it) drawn `pixels` big.
    /// Top row first, RGBA premultiplied as the canvas composites it, in sRGB. `deep`, with
    /// sixteen bits to a colour and not eight, for a picture a movie is made of: a glow then
    /// keeps what lies between eight bits' steps. Drawn as a canvas draws in every other way,
    /// each value kept between none and one as it is written.
    ///
    /// A frame whose targets keep is step `identity.moment` of its recording: `earlier` gives the
    /// frame of a step before it, for the steps between the nearest one kept and this to be
    /// drawn first (their passes into targets alone). Without it, every step is taken to draw
    /// as this one does.
    public func image(of frame: ShaderFrame, pixels: CGSize, region: CGRect? = nil, deep: Bool = false,
                      earlier: ((Int) throws -> ShaderFrame)? = nil) throws -> CGImage {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw ShaderError("No picture can be \(width) by \(height) pixels.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: deep ? .rgba16Unorm : .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let bytesPerRow = width * (deep ? 8 : 4)
        guard let target = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else {
            throw ShaderError("Metal: out of memory for a picture of \(width) by \(height).")
        }
        try encode(frame, into: target, region: region, commands: commands, earlier: earlier)
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
            let image = CGImage(width: width, height: height, bitsPerComponent: deep ? 16 : 8, bitsPerPixel: deep ? 64 : 32,
                                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ShaderError("The frame's picture could not be made.") }
        return image
    }

    /// The same into a texture the caller owns (a 2D render target, BGRA8 or RGBA8 and not sRGB,
    /// from `device`), for the film's stage and movies. Encodes into `commandBuffer`; the caller
    /// commits it. Throws before encoding anything when a program does not translate or build.
    public func draw(_ frame: ShaderFrame, into texture: MTLTexture, region: CGRect? = nil,
                     commandBuffer: MTLCommandBuffer, earlier: ((Int) throws -> ShaderFrame)? = nil) throws {
        guard texture.textureType == .type2D, texture.usage.contains(.renderTarget) else {
            throw ShaderError("The texture to draw into is not a 2D render target.")
        }
        try encode(frame, into: texture, region: region, commands: commandBuffer, earlier: earlier)
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

    /// What a pass draws into and reads, for its draws to be made ready.
    private struct Setting {
        var geometry: Geometry
        var formats: [MTLPixelFormat]
        /// For each thing drawn into: its alpha is never written (an RGB target).
        var opaque: [Bool]
        var depth: Bool
        var samples: Int
        /// What each of the frame's targets holds now.
        var seen: [Held?]
        /// The targets being drawn into, which a draw cannot read meanwhile.
        var written: Set<Int> = []
    }

    private func encode(_ frame: ShaderFrame, into target: MTLTexture, region: CGRect?, commands: MTLCommandBuffer,
                        earlier: ((Int) throws -> ShaderFrame)?) throws {
        if let fault = frame.fault() { throw ShaderError(fault) }
        let geometry = try Geometry(frame, region: region, output: target.width, target.height)
        let samples = sampleCount(frame)
        let passes = frame.everyPass
        let depth = frame.canvasTestsDepth

        // What the passes into targets left, drawn once for every tile of the frame.
        var seen: [Int: [Held?]] = [:]
        var keep: [AnyObject] = []
        if !frame.targets.isEmpty {
            let across = max(geometry.output.width / geometry.region.width, geometry.output.height / geometry.region.height)
            let drawn = try targets(of: frame, scale: targetScale(across, for: frame), earlier: earlier)
            seen = drawn.seen
            keep.append(drawn)
            // Another queue's commands may run before ours have drawn them.
            if commands.commandQueue !== queue { drawn.commands?.waitUntilCompleted() }
        }

        // Everything made first, so a program that does not build throws before anything is encoded.
        var canvas: [(pass: ShaderPass, draws: [Prepared])] = []
        for (index, pass) in passes.enumerated() where pass.ontoCanvas {
            let setting = Setting(geometry: geometry, formats: [target.pixelFormat], opaque: [false], depth: depth,
                                  samples: samples, seen: seen[index] ?? [])
            canvas.append((pass, try pass.draws.compactMap { try prepare($0, in: setting) }))
        }
        let finishing: [MTLRenderPipelineState] = try {
            if !frame.alpha { return [try finisher(.opaque, target.pixelFormat, samples, depth)] }
            if !frame.premultipliedAlpha { return [try finisher(.premultiply, target.pixelFormat, samples, depth)] }
            return []
        }()
        if canvas.isEmpty { canvas = [(ShaderPass(clearColor: [0, 0, 0, 0], draws: []), [])] }
        let single = canvas.count == 1

        var multisampled: MTLTexture?
        if samples > 1 {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DMultisample
            descriptor.pixelFormat = target.pixelFormat
            descriptor.width = target.width
            descriptor.height = target.height
            descriptor.sampleCount = samples
            descriptor.usage = [.renderTarget]
            // Kept from one pass to the next where the canvas is drawn onto in several.
            descriptor.storageMode = memoryless && single ? .memoryless : .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw ShaderError("Metal: out of memory for the frame's samples.")
            }
            multisampled = texture
            keep.append(texture)
        }
        var depthBuffer: MTLTexture?
        if depth {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
            descriptor.pixelFormat = Program.depthFormat
            descriptor.width = target.width
            descriptor.height = target.height
            descriptor.sampleCount = samples
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = memoryless && single ? .memoryless : .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw ShaderError("Metal: out of memory for the frame's depth.")
            }
            depthBuffer = texture
            keep.append(texture)
        }

        for (index, (pass, draws)) in canvas.enumerated() {
            let first = index == 0, last = index == canvas.count - 1
            let descriptor = MTLRenderPassDescriptor()
            let color = descriptor.colorAttachments[0]!
            if let multisampled {
                color.texture = multisampled
                if last {
                    color.resolveTexture = target
                    color.storeAction = .multisampleResolve
                } else {
                    color.storeAction = .store
                }
            } else {
                color.texture = target
                color.storeAction = .store
            }
            // The canvas starts every frame with nothing on it.
            if let clear = pass.clearColor ?? (first ? [0, 0, 0, 0] : nil) {
                let c = clear + [0, 0, 0, 0]
                color.loadAction = .clear
                color.clearColor = MTLClearColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
            } else {
                color.loadAction = .load
            }
            if let depthBuffer {
                descriptor.depthAttachment.texture = depthBuffer
                descriptor.stencilAttachment.texture = depthBuffer
                if let clear = pass.clearDepth ?? (first ? 1 : nil) {
                    descriptor.depthAttachment.loadAction = .clear
                    descriptor.depthAttachment.clearDepth = Double(clear)
                } else {
                    descriptor.depthAttachment.loadAction = .load
                }
                if let clear = pass.clearStencil ?? (first ? 0 : nil) {
                    descriptor.stencilAttachment.loadAction = .clear
                    descriptor.stencilAttachment.clearStencil = UInt32(truncatingIfNeeded: clear)
                } else {
                    descriptor.stencilAttachment.loadAction = .load
                }
                descriptor.depthAttachment.storeAction = last ? .dontCare : .store
                descriptor.stencilAttachment.storeAction = last ? .dontCare : .store
            }
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw ShaderError("Metal: no render encoder.")
            }
            for draw in draws {
                draw.encode(encoder)
                keep.append(contentsOf: draw.resources)
            }
            if last, !finishing.isEmpty {
                encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: geometry.output.width,
                                                height: geometry.output.height, znear: 0, zfar: 1))
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
                encoder.setCullMode(.none)
                encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
                if depth { encoder.setDepthStencilState(try depthState(nil, nil)) }
                for pipeline in finishing {
                    encoder.setRenderPipelineState(pipeline)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
            encoder.endEncoding()
        }
        // Keeps what the encoders point at until the GPU is done, whatever the caller's buffer retains.
        let kept = Kept(keep)
        commands.addCompletedHandler { _ in withExtendedLifetime(kept) {} }
    }

    /// Metal objects held until a command buffer is done; only held, never used, on any thread.
    private final class Kept: @unchecked Sendable {
        let objects: [AnyObject]
        init(_ objects: [AnyObject]) { self.objects = objects }
    }

    // MARK: Passes into targets

    /// What a frame's passes into targets leave, drawn once for a frame that says which it is.
    private func targets(of frame: ShaderFrame, scale: Int, earlier: ((Int) throws -> ShaderFrame)?) throws -> Drawn {
        let make: () throws -> Drawn = { [self] in
            var held = [Held?](repeating: nil, count: frame.targets.count)
            let step = max(0, frame.identity?.moment ?? 0)
            if frame.keeps {
                if let identity = frame.identity {
                    held = try timelines.state(recording: identity.recording, step: step, first: { try first(frame) }) { k, state in
                        let before = try earlier?(k) ?? frame
                        guard before.targets.count == frame.targets.count, before.fault() == nil else {
                            throw ShaderError("Step \(k) of the recording draws into other targets than step \(step).")
                        }
                        let left = try run(before, from: state, scale: 1, shows: false)
                        // The graphics card is not given more steps than it has drawn a few of.
                        if k % 16 == 15 { left.commands?.waitUntilCompleted() }
                        return Self.kept(left.left, of: frame)
                    }
                } else {
                    held = try first(frame)
                }
            }
            let result = try run(frame, from: held, scale: scale, shows: true)
            if frame.keeps, let identity = frame.identity {
                timelines.keep(Self.kept(result.left, of: frame), recording: identity.recording, step: step + 1)
            }
            return result
        }
        guard let identity = frame.identity else { return try make() }
        return try drawn.value(DrawnKey(identity: identity, scale: scale), make: make)
    }

    /// Of what a frame left in its targets, what the frame after finds there.
    private static func kept(_ left: [Held?], of frame: ShaderFrame) -> [Held?] {
        left.enumerated().map { frame.targets[$0.offset].keeps ? $0.element : nil }
    }

    /// What the targets that keep hold before the first step.
    private func first(_ frame: ShaderFrame) throws -> [Held?] {
        try frame.targets.map { target in
            guard target.keeps, let contents = target.contents else { return nil }
            let held = try pool.texture(width: target.width, height: target.height, format: Textures.format(target.format).0,
                                        mipmapped: target.mipmapped)
            let bytes = contents.bytes(as: target.format)
            bytes.withUnsafeBytes { raw in
                held.texture.replace(region: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0,
                                     withBytes: raw.baseAddress!, bytesPerRow: target.width * target.format.bytesPerTexel)
            }
            return held
        }
    }

    /// Draws a frame's passes into targets, in order, from what the targets hold; what they held
    /// is left as it was, each pass drawing into a texture of its own unless it made it itself.
    private func run(_ frame: ShaderFrame, from held: [Held?], scale: Int, shows: Bool) throws -> Drawn {
        var current = held
        // Made here and seen by no pass onto the canvas yet: these may be drawn into again.
        var own = Set<ObjectIdentifier>()
        var seen: [Int: [Held?]] = [:]
        var depths: [Int: Held] = [:]
        var keep: [AnyObject] = held.compactMap { $0 }
        var commands: MTLCommandBuffer?

        for (index, pass) in frame.everyPass.enumerated() {
            if pass.ontoCanvas {
                if shows {
                    seen[index] = current
                    own.removeAll()
                }
                continue
            }
            let first = frame.targets[pass.colors[0]]
            let factor = first.scales ? scale : 1
            let width = first.width * factor, height = first.height * factor
            let setting = Setting(geometry: Geometry(target: first.width, first.height, scale: factor),
                                  formats: pass.colors.map { Textures.format(frame.targets[$0].format).0 },
                                  opaque: pass.colors.map { frame.targets[$0].opaque }, depth: pass.depth != nil, samples: 1,
                                  seen: current, written: Set(pass.colors))
            let draws = try pass.draws.compactMap { try prepare($0, in: setting) }
            if commands == nil { commands = queue.makeCommandBuffer() }
            guard let commands else { throw ShaderError("Metal: no command buffer.") }

            let descriptor = MTLRenderPassDescriptor()
            for (slot, number) in pass.colors.enumerated() {
                let target = frame.targets[number]
                let attachment = descriptor.colorAttachments[slot]!
                let old = current[number].flatMap { $0.texture.width == width && $0.texture.height == height ? $0 : nil }
                let mine = old.map { own.contains(ObjectIdentifier($0)) } ?? false
                let texture: Held
                if let old, mine {
                    texture = old
                } else {
                    texture = try pool.texture(width: width, height: height, format: setting.formats[slot],
                                               mipmapped: target.mipmapped)
                }
                if let clear = pass.clearColor {
                    let c = clear + [0, 0, 0, 0]
                    attachment.loadAction = .clear
                    attachment.clearColor = MTLClearColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]),
                                                          alpha: target.opaque ? 1 : Double(c[3]))
                } else if let old {
                    if !mine {
                        // What it held stays for those who read it; this pass draws over a copy.
                        guard let blit = commands.makeBlitCommandEncoder() else { throw ShaderError("Metal: no blit encoder.") }
                        blit.copy(from: old.texture, to: texture.texture)
                        blit.endEncoding()
                    }
                    attachment.loadAction = .load
                } else {
                    attachment.loadAction = .clear
                    attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: target.opaque ? 1 : 0)
                }
                attachment.texture = texture.texture
                attachment.storeAction = .store
                current[number] = texture
                own.insert(ObjectIdentifier(texture))
                keep.append(texture)
            }
            if let number = pass.depth {
                let old = depths[number].flatMap { $0.texture.width == width && $0.texture.height == height ? $0 : nil }
                let buffer = try old ?? pool.texture(width: width, height: height, format: Program.depthFormat, mipmapped: false)
                depths[number] = buffer
                keep.append(buffer)
                descriptor.depthAttachment.texture = buffer.texture
                descriptor.stencilAttachment.texture = buffer.texture
                if let clear = pass.clearDepth ?? (old == nil ? 1 : nil) {
                    descriptor.depthAttachment.loadAction = .clear
                    descriptor.depthAttachment.clearDepth = Double(clear)
                } else {
                    descriptor.depthAttachment.loadAction = .load
                }
                if let clear = pass.clearStencil ?? (old == nil ? 0 : nil) {
                    descriptor.stencilAttachment.loadAction = .clear
                    descriptor.stencilAttachment.clearStencil = UInt32(truncatingIfNeeded: clear)
                } else {
                    descriptor.stencilAttachment.loadAction = .load
                }
                descriptor.depthAttachment.storeAction = .store
                descriptor.stencilAttachment.storeAction = .store
            }
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw ShaderError("Metal: no render encoder.")
            }
            for draw in draws {
                draw.encode(encoder)
                keep.append(contentsOf: draw.resources)
            }
            encoder.endEncoding()
            let copies = pass.mipmaps.compactMap { current[$0] }.filter { $0.texture.mipmapLevelCount > 1 }
            if !copies.isEmpty {
                guard let blit = commands.makeBlitCommandEncoder() else { throw ShaderError("Metal: no blit encoder.") }
                for texture in copies { blit.generateMipmaps(for: texture.texture) }
                blit.endEncoding()
            }
        }
        if let commands {
            let kept = Kept(keep)
            commands.addCompletedHandler { _ in withExtendedLifetime(kept) {} }
            commands.commit()
        }
        return Drawn(seen: seen, left: current, commands: commands)
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
        var viewport: MTLViewport
        var scissor: MTLScissorRect
        var primitive: MTLPrimitiveType
        var call: Call
        var instances: Int
        var blendColor: [Float]?
        var winding: MTLWinding
        var cull: MTLCullMode
        var depthState: MTLDepthStencilState?
        var references: (front: UInt32, back: UInt32)
        var offset: ShaderDraw.Offset?
        /// What the textures it reads are held by, where a pass drew them.
        var held: [AnyObject]

        var resources: [AnyObject] {
            var objects: [AnyObject] = [pipeline]
            for (_, data) in vertexBuffers { if case .buffer(let buffer) = data { objects.append(buffer) } }
            if case .indexed(let buffer, _, _) = call { objects.append(buffer) }
            for (_, texture, sampler) in vertexTextures + fragmentTextures { objects += [texture, sampler] }
            if let depthState { objects.append(depthState) }
            return objects + held
        }

        func encode(_ encoder: MTLRenderCommandEncoder) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setViewport(viewport)
            encoder.setScissorRect(scissor)
            encoder.setFrontFacing(winding)
            encoder.setCullMode(cull)
            encoder.setDepthBias(offset?.units ?? 0, slopeScale: offset?.factor ?? 0, clamp: 0)
            if let depthState {
                encoder.setDepthStencilState(depthState)
                encoder.setStencilReferenceValues(front: references.front, back: references.back)
            }
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
                encoder.drawPrimitives(type: primitive, vertexStart: start, vertexCount: count, instanceCount: instances)
            case .indexed(let buffer, let offset, let count):
                encoder.drawIndexedPrimitives(type: primitive, indexCount: count, indexType: .uint32, indexBuffer: buffer,
                                              indexBufferOffset: offset, instanceCount: instances)
            }
        }
    }

    private func vertexLayout(_ draw: ShaderDraw, _ program: Program) -> VertexLayout {
        VertexLayout(draw, program.layout, firstBuffer: Program.firstVertexBuffer)
    }

    private func pipelineKey(_ layout: VertexLayout, _ program: Program, _ draw: ShaderDraw, formats: [MTLPixelFormat],
                             opaque: [Bool], depth: Bool, samples: Int) -> Program.PipelineKey {
        var mask: MTLColorWriteMask = []
        if draw.channels.contains(.red) { mask.insert(.red) }
        if draw.channels.contains(.green) { mask.insert(.green) }
        if draw.channels.contains(.blue) { mask.insert(.blue) }
        if draw.channels.contains(.alpha) { mask.insert(.alpha) }
        // An output the fragment stage does not write leaves what is there.
        let writes = formats.indices.map { slot -> UInt in
            guard program.layout.outputs.contains(slot) else { return 0 }
            return (opaque[slot] ? mask.subtracting(.alpha) : mask).rawValue
        }
        return Program.PipelineKey(attributes: layout.attributes, pixelFormats: formats.map(\.rawValue), writes: writes,
                                   depth: depth, sampleCount: samples, blend: draw.blend.map(Program.BlendKey.init))
    }

    private func prepare(_ draw: ShaderDraw, in setting: Setting) throws -> Prepared? {
        let program = try program(draw.vertex, draw.fragment)
        let layout = vertexLayout(draw, program)
        let key = pipelineKey(layout, program, draw, formats: setting.formats, opaque: setting.opaque, depth: setting.depth,
                              samples: setting.samples)
        let pipeline = try program.pipeline(key, device: device)
        guard let plan = DrawPlan(draw, program: program.layout, layout: layout, geometry: setting.geometry) else { return nil }

        let primitive: MTLPrimitiveType = switch plan.primitive {
        case .triangle: .triangle
        case .triangleStrip: .triangleStrip
        case .line: .line
        case .lineStrip: .lineStrip
        case .point: .point
        }
        // With both faces left out, no triangle is drawn; lines and points still are.
        if draw.cull == .both, primitive == .triangle || primitive == .triangleStrip { return nil }
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
        var held: [AnyObject] = []
        let vertexTextures = try bind(plan.vertexTextures, plan, setting, &held)
        let fragmentTextures = try bind(plan.fragmentTextures, plan, setting, &held)
        // A target is drawn the other way up, so its triangles turn the other way round.
        let clockwise = draw.clockwiseFront != setting.geometry.flipped
        let cull: MTLCullMode = switch draw.cull {
        case .front: .front
        case .back: .back
        default: .none
        }
        let near = Double(max(0, min(1, draw.depth?.near ?? 0))), far = Double(max(0, min(1, draw.depth?.far ?? 1)))
        return Prepared(pipeline: pipeline,
                        vertexUniforms: plan.vertexUniforms,
                        fragmentUniforms: plan.fragmentUniforms,
                        vertexBuffers: vertexBuffers,
                        vertexTextures: vertexTextures,
                        fragmentTextures: fragmentTextures,
                        viewport: MTLViewport(originX: 0, originY: 0, width: setting.geometry.output.width,
                                              height: setting.geometry.output.height, znear: near, zfar: far),
                        scissor: scissor, primitive: primitive, call: call, instances: plan.instances,
                        blendColor: plan.blendColor,
                        winding: clockwise ? .clockwise : .counterClockwise, cull: cull,
                        depthState: setting.depth ? try depthState(draw.depth, draw.stencil) : nil,
                        references: (UInt32(truncatingIfNeeded: draw.stencil?.front.reference ?? 0),
                                     UInt32(truncatingIfNeeded: draw.stencil?.back.reference ?? 0)),
                        offset: draw.offset, held: held)
    }

    private func bind(_ list: [DrawPlan.Texture], _ plan: DrawPlan, _ setting: Setting,
                      _ held: inout [AnyObject]) throws -> [(Int, MTLTexture, MTLSamplerState)] {
        try list.map { texture in
            let metal: MTLTexture
            switch texture.source {
            case .none:
                metal = try textures.blank(cube: texture.cube)
            case .picture(let picture):
                metal = try textures.texture(picture, flip: plan.flipsTextures, premultiply: plan.premultipliesTextures,
                                             mipmaps: texture.sampling.mipmap != nil, cube: texture.cube, decodes: texture.decodes)
            case .data(let data):
                metal = try textures.texture(data, mipmaps: texture.sampling.mipmap != nil, decodes: texture.decodes)
            case .target(let number):
                // A target cannot be read while it is drawn into; one nothing drew into reads nought.
                if setting.written.contains(number) {
                    metal = try textures.blank(cube: false)
                } else if setting.seen.indices.contains(number), let target = setting.seen[number] {
                    metal = target.texture
                    held.append(target)
                } else {
                    metal = try textures.empty()
                }
            }
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

    /// The depth and stencil tests of a draw in a pass that has the buffer; with neither, every
    /// fragment passes and nothing is written.
    private func depthState(_ depth: ShaderDraw.Depth?, _ stencil: ShaderDraw.Stencil?) throws -> MTLDepthStencilState {
        var key = DepthKey(depth: depth, stencil: stencil)
        // The range is the viewport's, not the test's.
        key.depth?.near = 0
        key.depth?.far = 1
        return try depthStates.value(key) {
            func compare(_ compare: ShaderDraw.Compare) -> MTLCompareFunction {
                switch compare {
                case .never: .never
                case .less: .less
                case .equal: .equal
                case .lessEqual: .lessEqual
                case .greater: .greater
                case .notEqual: .notEqual
                case .greaterEqual: .greaterEqual
                case .always: .always
                }
            }
            func operation(_ operation: ShaderDraw.Stencil.Operation) -> MTLStencilOperation {
                switch operation {
                case .keep: .keep
                case .zero: .zero
                case .replace: .replace
                case .increment: .incrementClamp
                case .incrementWrap: .incrementWrap
                case .decrement: .decrementClamp
                case .decrementWrap: .decrementWrap
                case .invert: .invert
                }
            }
            func face(_ face: ShaderDraw.Stencil.Face) -> MTLStencilDescriptor {
                let descriptor = MTLStencilDescriptor()
                descriptor.stencilCompareFunction = compare(face.compare)
                descriptor.stencilFailureOperation = operation(face.fail)
                descriptor.depthFailureOperation = operation(face.depthFail)
                descriptor.depthStencilPassOperation = operation(face.pass)
                descriptor.readMask = face.readMask
                descriptor.writeMask = face.writeMask
                return descriptor
            }
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = depth.map { compare($0.compare) } ?? .always
            descriptor.isDepthWriteEnabled = depth?.writes ?? false
            if let stencil {
                descriptor.frontFaceStencil = face(stencil.front)
                descriptor.backFaceStencil = face(stencil.back)
            }
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw ShaderError("Metal: no depth state.")
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
        var depth: Bool
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
    private func finisher(_ kind: Finishing, _ pixelFormat: MTLPixelFormat, _ samples: Int,
                          _ depth: Bool) throws -> MTLRenderPipelineState {
        try finishers.value(FinisherKey(kind: kind, pixelFormat: pixelFormat.rawValue, samples: samples, depth: depth)) {
            let library = try device.makeLibrary(source: Self.finishingSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "bezzle_cover")
            descriptor.fragmentFunction = library.makeFunction(name: "bezzle_opaque")
            descriptor.rasterSampleCount = samples
            if depth {
                descriptor.depthAttachmentPixelFormat = Program.depthFormat
                descriptor.stencilAttachmentPixelFormat = Program.depthFormat
            }
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
