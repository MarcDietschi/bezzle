import CoreGraphics
import Foundation
import ImageIO
import Shaders

/// Shader fills drawn (`ShaderFill`): the fill's frame, at a moment of its own time, handed to
/// Bezzle's engine (Packages/Shaders, Metal on the Mac, Direct3D on Windows) and drawn into the
/// part of the layer that a tile or a picture shows, as sharp as it shows there. What cannot be
/// drawn, on a computer without either or a program that does not build, gives way to the fill's
/// picture, which is how it came in. Bezzle for Windows compiles this same file, with
/// Windows/Sources/BezzleCore/Host/ShaderPictures.swift saying the engine's types in its core's.
///
/// A fill whose frames build on the frames before them (`ShaderFill.builds`) is drawn as the step
/// its moment falls in: the engine draws the steps between the nearest state it kept and that one
/// first, each with its inputs as they were at that step, so a moment always looks the same.
///
/// Thread-safe: the canvas's tiles are drawn on several threads at once (`Renderer`).
nonisolated enum ShaderPainting {
    /// Whether shaders can be drawn here at all.
    static var available: Bool { ShaderRenderer.shared != nil }

    /// Fills whose programs did not build, by what they draw: not tried again tile after tile.
    private static let broken = Broken()

    private final class Broken: @unchecked Sendable {
        private let lock = NSLock()
        private var known: Set<Int> = []
        func contains(_ key: Int) -> Bool { lock.withLock { known.contains(key) } }
        func insert(_ key: Int) { lock.withLock { _ = known.insert(key) } }
    }

    /// A fill's textures of numbers and what its targets held, as the engine takes them: each
    /// made once for the bytes the design holds, since the engine keeps a texture for each it
    /// is given.
    private static let numbers = Numbers()

    private final class Numbers: @unchecked Sendable {
        /// The bytes by where they lie (a design's copies share them), or, few as they are, by
        /// what they are: a few bytes lie in the value itself, nowhere of their own.
        private struct Key: Hashable {
            var address: Int
            var few: Data?
            var count: Int
            var width: Int
            var height: Int
            var format: String
        }

        private struct Entry {
            /// Held, so that nothing else comes to lie where these do.
            var bytes: Data
            var data: ShaderData
            var mark: Int
            var used: Int
        }

        private let lock = NSLock()
        private var kept: [Key: Entry] = [:]
        private var clock = 0
        private var size = 0

        /// The engine's numbers for a design's bytes, and what tells these bytes from all others:
        /// every one of them counts, where `Data`'s own hash looks at the first eighty.
        func data(_ bytes: Data, width: Int, height: Int, format: ShaderData.Format, name: String) -> (data: ShaderData, mark: Int)? {
            let few = bytes.count <= 64
            let address = few ? 0 : bytes.withUnsafeBytes { Int(bitPattern: $0.baseAddress) }
            let key = Key(address: address, few: few ? bytes : nil, count: bytes.count, width: width, height: height, format: name)
            lock.lock()
            defer { lock.unlock() }
            clock += 1
            if var entry = kept[key] {
                entry.used = clock
                kept[key] = entry
                return (entry.data, entry.mark)
            }
            guard let data = ShaderData(width: width, height: height, format: format, bytes: [UInt8](bytes)) else { return nil }
            var mark: UInt64 = 0xcbf2_9ce4_8422_2325
            bytes.withUnsafeBytes { raw in
                var at = 0
                while at + 8 <= raw.count {
                    mark = (mark ^ raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)) &* 0x0000_0100_0000_01b3
                    mark ^= mark >> 29
                    at += 8
                }
                while at < raw.count {
                    mark = (mark ^ UInt64(raw[at])) &* 0x0000_0100_0000_01b3
                    at += 1
                }
            }
            kept[key] = Entry(bytes: bytes, data: data, mark: Int(truncatingIfNeeded: mark), used: clock)
            size += bytes.count
            // At most 64 of them and 128 MB: the longest unused go first.
            while size > 128 << 20 || kept.count > 64, let oldest = kept.min(by: { $0.value.used < $1.value.used }), oldest.key != key {
                size -= oldest.value.bytes.count
                kept[oldest.key] = nil
            }
            return (data, Int(truncatingIfNeeded: mark))
        }
    }

    /// Draws a shader fill inside an outline, a layer of `size` with its top left at zero, at the
    /// film's moment `film` (the design's moment when nil): placed as its picture is, or in the
    /// whole box. Says whether it drew, so that the picture is drawn when it did not. Into a
    /// bitmap with sixteen bits to a colour, as a movie's pictures are on the Mac
    /// (`Renderer.bitmap(_:space:deep:)`), it is made as deep, so that its glows keep what lies
    /// between eight bits' steps.
    static func paint(_ shader: ShaderFill, picture: ImageFill?, in path: CGPath, size: CGSize, rule: CGPathFillRule,
                      in ctx: CGContext, film: Double?, assets: Assets?, box: CGRect? = nil) -> Bool {
        guard let renderer = ShaderRenderer.shared else { return false }
        let key = shader.hashValue
        guard !broken.contains(key) else { return false }
        let box = box ?? CGRect(origin: .zero, size: size)
        let drawn = picture.map { Renderer.imageRect($0, in: box.size).offsetBy(dx: box.minX, dy: box.minY) } ?? box
        guard drawn.width > 0, drawn.height > 0, shader.size.width >= 1, shader.size.height >= 1 else { return false }
        // Only what shows: the part of it inside the outline and in the tile being drawn.
        var part = drawn.intersection(path.boundingBoxOfPath)
        if ctx.width > 0 { part = part.intersection(ctx.boundingBoxOfClipPath) }
        guard !part.isNull, part.width > 0.01, part.height > 0.01 else { return true }
        // As sharp as it shows: a PDF, which has no pixels, gets it at twice its size in points.
        var scale = ctx.width > 0 ? Renderer.pixelScale(ctx) : 2
        while part.width * scale > 8192 || part.height * scale > 8192 { scale /= 2 }
        let pixels = CGSize(width: max(1, (part.width * scale).rounded(.up)), height: max(1, (part.height * scale).rounded(.up)))
        // That part of the drawing buffer, from its top left; across the other way where it was flipped.
        let across = shader.size.width / drawn.width, down = shader.size.height / drawn.height
        var region = CGRect(x: (part.minX - drawn.minX) * across, y: (part.minY - drawn.minY) * down,
                            width: part.width * across, height: part.height * down)
        if shader.flippedX == true { region.origin.x = shader.size.width - region.maxX }
        if shader.flippedY == true { region.origin.y = shader.size.height - region.maxY }
        let images: (String) -> CGImage? = { assets?.image($0, pixels: .infinity) }
        let t = shader.time(film: film)
        // Where it builds on the frames before: the step this moment falls in.
        let step = shader.builds ? shader.step(at: t) : nil
        guard let frame = frame(of: shader, at: step.map { shader.time(ofStep: $0) } ?? t, step: step, recording: key, images: images) else { return false }
        let image: CGImage
        do {
            // The frames of the steps before, for a fill that builds on them.
            let earlier: ((Int) throws -> ShaderFrame)? = step == nil ? nil : { before in
                guard let earlier = Self.frame(of: shader, at: shader.time(ofStep: before), step: before, recording: key, images: images) else {
                    throw ShaderError("Step \(before) of the fill cannot be put together.")
                }
                return earlier
            }
            #if canImport(Metal)
            image = try renderer.image(of: frame, pixels: pixels, region: region, deep: ctx.bitsPerComponent > 8, earlier: earlier)
            #else
            image = try renderer.image(of: frame, pixels: pixels, region: region, earlier: earlier)
            #endif
        } catch {
            broken.insert(key)
            return false
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: rule)
        ctx.interpolationQuality = .high
        // Upright, or turned over where it lies when its layer was flipped, as a picture is.
        ctx.translateBy(x: part.midX, y: part.midY)
        ctx.scaleBy(x: shader.flippedX == true ? -1 : 1, y: shader.flippedY == true ? 1 : -1)
        ctx.draw(image, in: CGRect(x: -part.width / 2, y: -part.height / 2, width: part.width, height: part.height))
        ctx.restoreGState()
        return true
    }

    private static func images(_ pictures: [String: Data]) -> [String: CGImage] {
        pictures.compactMapValues { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// Whether every program of a fill builds, its pictures given as files: for an import to keep
    /// only what Bezzle can draw again. True where shaders cannot be drawn at all, as nothing
    /// then says otherwise, and the picture stands in.
    static func builds(_ shader: ShaderFill, pictures: [String: Data]) -> Bool {
        guard let renderer = ShaderRenderer.shared else { return true }
        let images = images(pictures)
        guard let frame = frame(of: shader, at: 0, step: shader.builds ? 0 : nil, recording: 0, images: { images[$0] }) else { return false }
        do { try renderer.check(frame) } catch { return false }
        return true
    }

    /// The fill's frame at its own time `t`, as the engine takes it; of a fill that builds, the
    /// step that time falls in.
    static func frame(of shader: ShaderFill, at t: Double, assets: Assets?) -> ShaderFrame? {
        let step = shader.builds ? shader.step(at: t) : nil
        return frame(of: shader, at: step.map { shader.time(ofStep: $0) } ?? t, step: step, recording: shader.hashValue) { name in
            assets?.image(name, pixels: .infinity)
        }
    }

    /// The frame with its inputs as they are at `t`, and, for a fill that builds, its targets
    /// where they stand at `step`. `recording` tells the fill from every other, for the engine to
    /// keep what its passes drew and the states of its steps by.
    private static func frame(of shader: ShaderFill, at t: Double, step: Int?, recording: Int, images: (String) -> CGImage?) -> ShaderFrame? {
        let turned = step ?? 0
        var marks = Hasher()
        marks.combine(recording)
        var draws: [Shaders.ShaderDraw] = []
        for (place, d) in shader.draws.enumerated() {
            guard shader.programs.indices.contains(d.program) else { return nil }
            let program = shader.programs[d.program]
            var textures: [String: CGImage] = [:]
            for (name, texture) in d.textures ?? [:] {
                guard let image = images(texture.asset) else { return nil }
                textures[name] = image
            }
            let attributes = d.attributes.mapValues { a -> Shaders.ShaderDraw.Attribute in
                a.values != nil ? .init(components: a.components, values: a.floats, divisor: max(0, a.divisor ?? 0))
                    : .constant((a.constant ?? [0, 0, 0, 1]).map(Float.init))
            }
            var draw = Shaders.ShaderDraw(vertex: program.vertex, fragment: program.fragment,
                                          uniforms: shader.uniforms(of: d, at: t, place: place).mapValues { $0.map(Float.init) },
                                          attributes: attributes, indices: d.indexList, mode: mode(d.mode), first: d.first, count: d.count,
                                          textures: textures, flipsTextures: d.flipsTextures == true,
                                          premultipliesTextures: d.premultipliesTextures == true,
                                          sampling: (d.sampling ?? [:]).mapValues(sampling), blend: d.blend.map(blend), viewport: d.viewport)
            for (name, index) in d.targets ?? [:] { draw.targets[name] = shader.target(index, after: turned) }
            for (name, index) in d.texels ?? [:] {
                guard let texels = shader.texels, texels.indices.contains(index), let format = format(texels[index].format),
                      let made = numbers.data(texels[index].bytes, width: texels[index].width, height: texels[index].height, format: format,
                                              name: texels[index].format) else { return nil }
                draw.data[name] = made.data
                marks.combine(made.mark)
            }
            if let decodes = d.decodes { draw.decodes = Set(decodes) }
            if let depth = d.depth {
                let range = depth.range.flatMap { $0.count == 2 ? $0 : nil } ?? [0, 1]
                draw.depth = .init(compare: compare(depth.compare), writes: depth.writes ?? true, near: Float(range[0]), far: Float(range[1]))
            }
            if let stencil = d.stencil { draw.stencil = .init(front: face(stencil.front), back: stencil.back.map(face)) }
            if let cull = d.cull { draw.cull = cull == "front" ? .front : cull == "both" ? .both : .back }
            draw.clockwiseFront = d.clockwiseFront == true
            if let channels = d.channels { draw.channels = .init(rawValue: channels & 15) }
            if let box = d.scissor {
                draw.setScissor(x: Double(box.origin.x), y: Double(box.origin.y), width: Double(box.size.width), height: Double(box.size.height))
            }
            if let offset = d.offset, offset.count == 2 { draw.offset = .init(factor: Float(offset[0]), units: Float(offset[1])) }
            if let instances = d.instances { draw.instances = max(0, instances) }
            draws.append(draw)
        }
        let alpha = shader.alpha ?? true, premultiplied = shader.premultipliedAlpha ?? true, antialias = shader.antialias ?? true
        guard shader.targets != nil || shader.passes != nil else {
            return ShaderFrame(size: shader.size, clear: shader.clear?.map(Float.init), draws: draws, alpha: alpha,
                               premultipliedAlpha: premultiplied, antialias: antialias)
        }
        var frame = ShaderFrame(size: shader.size, clear: nil, draws: [], alpha: alpha, premultipliedAlpha: premultiplied, antialias: antialias)
        for target in shader.targets ?? [] {
            let name = target.format ?? "rgba8"
            guard let format = format(name), format.drawn else { return nil }
            var made = Shaders.ShaderTarget(width: target.width, height: target.height, format: format, opaque: target.opaque == true,
                                            mipmapped: target.mipmapped == true, keeps: target.keeps == true, scales: target.scales == true)
            if target.keeps == true, let contents = target.contents {
                guard let held = numbers.data(contents, width: target.width, height: target.height, format: format, name: name) else { return nil }
                made.contents = held.data
                marks.combine(held.mark)
            }
            frame.targets.append(made)
        }
        var from = 0
        let count = frame.targets.count
        for pass in shader.passes ?? [ShaderPass(clearColor: shader.clear ?? [0, 0, 0, 0], count: draws.count)] {
            let to = min(draws.count, from + max(0, pass.count))
            let colors = (pass.colors ?? []).map { shader.target($0, after: turned) }
            let mipmaps = (pass.mipmaps ?? []).map { shader.target($0, after: turned) }
            guard (colors + mipmaps).allSatisfy({ $0 >= 0 && $0 < count }) else { return nil }
            frame.passes.append(Shaders.ShaderPass(colors: colors, depth: pass.depth, clearColor: pass.clearColor?.map(Float.init),
                                                   clearDepth: pass.clearDepth.map(Float.init), clearStencil: pass.clearStencil,
                                                   draws: Array(draws[from..<to]), mipmaps: mipmaps))
            from = to
        }
        // Which frame of which fill: its tiles share what its passes drew, and a step finds what
        // the step before left.
        frame.identity = .init(recording: marks.finalize(), moment: step ?? Int(truncatingIfNeeded: t.bitPattern))
        return frame
    }

    // MARK: What an import keeps

    /// A fill as an import keeps it, its pictures given as files, or why its canvas stays a
    /// picture. What is found out here by drawing it:
    ///
    /// - whether it draws at all: every program builds, and the engine here draws what it has;
    /// - which of the textures the recorder saw it take over from the frame before it really
    ///   reads: those keep, and need what they held; the others are drawn anew every frame;
    /// - with none that keep, which textures are sized by the canvas, and so are drawn larger
    ///   where the fill is shown larger;
    /// - whether its draws' tests and masks change anything it shows: where they do not, they are
    ///   left out, and every Bezzle that draws shaders draws it.
    ///
    /// The fill as it is where shaders cannot be drawn at all, as nothing then says otherwise.
    static func settled(_ fill: ShaderFill, pictures: [String: Data]) -> (fill: ShaderFill?, why: String?) {
        guard let renderer = ShaderRenderer.shared else { return (fill, nil) }
        let images = images(pictures)
        let lookup: (String) -> CGImage? = { images[$0] }
        var fill = fill
        guard let first = frame(of: fill, at: 0, step: fill.builds ? 0 : nil, recording: 0, images: lookup) else {
            return (nil, "reads what it does not have")
        }
        do { try renderer.check(first) } catch {
            // Where tests and masks are not drawn yet, a rectangle's go without, as they did
            // before Bezzle knew them: they change nothing of one drawn alone.
            if let plain = withoutTests(fill), fill.draws.filter({ $0.depth != nil }).count <= 1,
               fill.draws.allSatisfy({ !$0.beyondPlain || ($0.count <= 6 && $0.stencil == nil && $0.scissor == nil && $0.channels == nil) }),
               let frame = frame(of: plain, at: 0, step: nil, recording: 0, images: lookup), (try? renderer.check(frame)) != nil {
                return (plain, nil)
            }
            return (nil, "is not drawn here: " + String("\(error)".prefix(300)))
        }
        // Compared small: what differs, differs there too.
        let shrink = min(1, 256 / max(fill.size.width, fill.size.height))
        let width = max(1, Int((fill.size.width * shrink).rounded())), height = max(1, Int((fill.size.height * shrink).rounded()))

        if fill.builds, var targets = fill.targets {
            let candidates = targets.indices.filter { targets[$0].keeps == true }
            var noises: [Int: Data] = [:]
            for i in candidates { noises[i] = noise(for: targets[i], seed: i + 1) }
            /// What it shows over its first steps, each candidate starting from what `held` gives.
            func shown(_ held: (Int) -> Data?) -> [[UInt8]]? {
                var test = fill
                for i in candidates { test.targets?[i].contents = held(i) }
                let recording = Int.random(in: Int.min...Int.max)
                var out: [[UInt8]] = []
                for step in 0..<3 {
                    guard let frame = frame(of: test, at: test.time(ofStep: step), step: step, recording: recording, images: lookup),
                          let bytes = try? renderer.pixels(of: frame, width: width, height: height, earlier: { before in
                              guard let earlier = Self.frame(of: test, at: test.time(ofStep: before), step: before, recording: recording, images: lookup) else {
                                  throw ShaderError("Step \(before) of the fill cannot be put together.")
                              }
                              return earlier
                          }) else { return nil }
                    out.append(bytes)
                }
                return out
            }
            guard let empty = shown({ _ in nil }), let full = shown({ noises[$0] }) else { return (nil, "its steps are not drawn here") }
            var reads = Set<Int>()
            if empty != full {
                if candidates.count > 1 {
                    for i in candidates {
                        guard let one = shown({ $0 == i ? noises[i] : nil }) else { return (nil, "its steps are not drawn here") }
                        if one != empty { reads.insert(i) }
                    }
                }
                // What shows only where several differ at once: all of them.
                if reads.isEmpty { reads = Set(candidates) }
            }
            // A texture read keeps, and so does what takes its place in the steps after.
            var keeps = reads
            if let turn = fill.turn, turn.count == targets.count {
                var grows = true
                while grows {
                    grows = false
                    for i in keeps where turn.indices.contains(i) && keeps.insert(turn[i]).inserted { grows = true }
                }
            }
            for i in reads where targets[i].contents == nil {
                return (nil, "builds on what it drew before, which could not be read back")
            }
            for i in targets.indices {
                if !keeps.contains(i) { targets[i].keeps = nil }
                if !reads.contains(i) { targets[i].contents = nil }
            }
            fill.targets = targets
            if keeps.isEmpty {
                fill.turn = nil
                fill.rate = nil
            }
        }

        if !fill.builds, var targets = fill.targets {
            // Read texel by texel, a texture is a table, and stays the size it is.
            var tables = Set<Int>()
            for d in fill.draws {
                for (name, index) in d.targets ?? [:] where d.sampling?[name]?.magnify == "nearest" { tables.insert(index) }
            }
            for i in targets.indices where !tables.contains(i) {
                let w = Double(targets[i].width), h = Double(targets[i].height)
                let canvasW = Double(fill.size.width), canvasH = Double(fill.size.height)
                if abs(w - canvasW * h / canvasH) <= 1.5, abs(h - canvasH * w / canvasW) <= 1.5 { targets[i].scales = true }
            }
            fill.targets = targets
        }

        if let plain = withoutTests(fill), plain != fill {
            let same = [0, 0.37, 1.1, 2.9, 7.3].allSatisfy { t in
                guard let tested = frame(of: fill, at: t, step: nil, recording: 0, images: lookup),
                      let untested = frame(of: plain, at: t, step: nil, recording: 0, images: lookup),
                      let a = try? renderer.pixels(of: tested, width: width, height: height),
                      let b = try? renderer.pixels(of: untested, width: width, height: height) else { return false }
                return a == b
            }
            if same { return (plain, nil) }
        }
        return (fill, nil)
    }

    /// The fill without its draws' tests and masks, when that leaves nothing Bezzle 1.7 does not
    /// know; nil when it has more than those (passes, textures of numbers, instances).
    private static func withoutTests(_ fill: ShaderFill) -> ShaderFill? {
        guard fill.targets == nil, fill.passes == nil, fill.texels == nil else { return nil }
        var plain = fill
        for i in plain.draws.indices {
            plain.draws[i].depth = nil
            plain.draws[i].stencil = nil
            plain.draws[i].cull = nil
            plain.draws[i].clockwiseFront = nil
            plain.draws[i].channels = nil
            plain.draws[i].scissor = nil
            plain.draws[i].offset = nil
        }
        return plain.beyondPlain ? nil : plain
    }

    /// Numbers of no meaning for a target to start from, to see whether what it holds shows:
    /// between nought and one, whatever its texels are.
    private static func noise(for target: ShaderTarget, seed: Int) -> Data? {
        let name = target.format ?? "rgba8"
        guard let per = ShaderTarget.bytesPerTexel(name), target.width > 0, target.height > 0 else { return nil }
        let count = target.width * target.height * per
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        // A stretch of them, over and over.
        var block = [UInt8](repeating: 0, count: min(count, 16 * 4099))
        if name.hasSuffix("32f") {
            for i in stride(from: 0, to: block.count - 3, by: 4) {
                let bits = Float(0.1 + 0.8 * Double(next() & 0xFFFF) / 65535).bitPattern
                for k in 0..<4 { block[i + k] = UInt8(truncatingIfNeeded: bits >> (8 * UInt32(k))) }
            }
        } else if name.hasSuffix("16f") {
            for i in stride(from: 0, to: block.count - 1, by: 2) {
                // A half float from a quarter up to one.
                let bits = UInt16(0x3400) + UInt16(next() & 0x7FF)
                block[i] = UInt8(bits & 0xFF)
                block[i + 1] = UInt8(bits >> 8)
            }
        } else {
            for i in block.indices { block[i] = UInt8(truncatingIfNeeded: next() >> 24) }
        }
        var data = Data(capacity: count)
        while data.count < count { data.append(contentsOf: block.prefix(count - data.count)) }
        return data
    }

    // MARK: The model's words in the engine's

    private static func format(_ name: String) -> ShaderData.Format? {
        switch name {
        case "rgba8": .rgba8
        case "rg8": .rg8
        case "r8": .r8
        case "l8": .luminance8
        case "a8": .alpha8
        case "la8": .luminanceAlpha8
        case "rgba16f": .rgba16Float
        case "rg16f": .rg16Float
        case "r16f": .r16Float
        case "rgba32f": .rgba32Float
        case "rg32f": .rg32Float
        case "r32f": .r32Float
        default: nil
        }
    }

    /// `ShaderDraw` unqualified is the model's, the module's own (Bezzle here, BezzleCore on
    /// Windows, which compiles this file too), found before the engine's.
    private static func mode(_ m: ShaderDraw.Mode) -> Shaders.ShaderDraw.Mode {
        switch m {
        case .triangles: .triangles
        case .triangleStrip: .triangleStrip
        case .triangleFan: .triangleFan
        case .lines: .lines
        case .lineStrip: .lineStrip
        case .lineLoop: .lineLoop
        case .points: .points
        }
    }

    private static func compare(_ name: String) -> Shaders.ShaderDraw.Compare {
        switch name {
        case "never": .never
        case "equal": .equal
        case "lequal": .lessEqual
        case "greater": .greater
        case "notequal": .notEqual
        case "gequal": .greaterEqual
        case "always": .always
        default: .less
        }
    }

    private static func face(_ f: ShaderStencil.Face) -> Shaders.ShaderDraw.Stencil.Face {
        func operation(_ name: String) -> Shaders.ShaderDraw.Stencil.Operation {
            switch name {
            case "zero": .zero
            case "replace": .replace
            case "incr": .increment
            case "incr-wrap": .incrementWrap
            case "decr": .decrement
            case "decr-wrap": .decrementWrap
            case "invert": .invert
            default: .keep
            }
        }
        return .init(compare: compare(f.compare), reference: f.reference, readMask: UInt32(truncatingIfNeeded: f.readMask) & 0xFF,
                     writeMask: UInt32(truncatingIfNeeded: f.writeMask) & 0xFF, fail: operation(f.fail), depthFail: operation(f.depthFail),
                     pass: operation(f.pass))
    }

    private static func sampling(_ s: ShaderSampling) -> Shaders.ShaderDraw.Sampling {
        func wrap(_ w: String) -> Shaders.ShaderDraw.Sampling.Wrap { w == "repeat" ? .repeat : w == "mirror" ? .mirroredRepeat : .clampToEdge }
        func filter(_ f: String) -> Shaders.ShaderDraw.Sampling.Filter { f == "nearest" ? .nearest : .linear }
        return Shaders.ShaderDraw.Sampling(wrapS: wrap(s.wrapS), wrapT: wrap(s.wrapT), magnify: filter(s.magnify), minify: filter(s.minify),
                                           mipmap: s.mipmap.map(filter))
    }

    private static func blend(_ b: ShaderBlend) -> Shaders.ShaderDraw.Blend {
        func factor(_ f: String) -> Shaders.ShaderDraw.Blend.Factor {
            switch f {
            case "zero": .zero
            case "src-color": .sourceColor
            case "one-minus-src-color": .oneMinusSourceColor
            case "dst-color": .destinationColor
            case "one-minus-dst-color": .oneMinusDestinationColor
            case "src-alpha": .sourceAlpha
            case "one-minus-src-alpha": .oneMinusSourceAlpha
            case "dst-alpha": .destinationAlpha
            case "one-minus-dst-alpha": .oneMinusDestinationAlpha
            case "constant-color": .constantColor
            case "one-minus-constant-color": .oneMinusConstantColor
            case "constant-alpha": .constantAlpha
            case "one-minus-constant-alpha": .oneMinusConstantAlpha
            case "src-alpha-saturate": .sourceAlphaSaturate
            default: .one
            }
        }
        func equation(_ e: String) -> Shaders.ShaderDraw.Blend.Equation {
            switch e {
            case "func-subtract": .subtract
            case "func-reverse-subtract": .reverseSubtract
            case "min": .min
            case "max": .max
            default: .add
            }
        }
        var out = Shaders.ShaderDraw.Blend(source: factor(b.source), destination: factor(b.destination),
                                           sourceAlpha: factor(b.sourceAlpha), destinationAlpha: factor(b.destinationAlpha))
        out.equation = equation(b.equation)
        out.equationAlpha = equation(b.equationAlpha)
        if let color = b.color, color.count == 4 { out.color = color.map(Float.init) }
        return out
    }
}
