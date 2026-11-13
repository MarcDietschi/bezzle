import Foundation

/// One draw worked out as WebGL would make it, for either back end to encode: its vertex
/// buffers, the call (fans and loops, which neither Metal nor Direct3D draws, as indices), the
/// viewport's cut, the uniforms packed into each stage's blocks with Bezzle's own (clip space
/// and gl_FragCoord mapped onto the region drawn), and which picture each sampler reads.
struct DrawPlan {
    enum Primitive { case triangle, triangleStrip, line, lineStrip, point }

    enum Call {
        case arrays(start: Int, count: Int)
        /// From the index `first` of `indices` on.
        case indexed([UInt32], first: Int, count: Int)
    }

    struct Scissor: Equatable {
        var x: Int, y: Int, width: Int, height: Int
    }

    /// A sampler's slot, its picture (nil: none bound, which reads opaque black) and how it reads it.
    struct Texture {
        var slot: Int
        var picture: ShaderPicture?
        var sampling: ShaderDraw.Sampling
        var cube: Bool
    }

    var vertexBuffers: [(Int, [UInt8])]
    var primitive: Primitive
    var call: Call
    var scissor: Scissor
    var vertexUniforms: [(Int, [UInt8])]
    var fragmentUniforms: [(Int, [UInt8])]
    var vertexTextures: [Texture]
    var fragmentTextures: [Texture]
    var flipsTextures: Bool
    var premultipliesTextures: Bool
    var blendColor: [Float]?
}

/// What maps the drawing buffer onto the output.
struct Geometry {
    var size: (width: Double, height: Double)        // the drawing buffer
    var region: (x: Double, y: Double, width: Double, height: Double) // of it, top-left origin
    var output: (width: Double, height: Double)

    /// `region` of a frame (nil: all of it) drawn into an output `width` by `height` pixels.
    init(_ frame: ShaderFrame, region: CGRect?, output width: Int, _ height: Int) throws {
        let size = (width: Double(frame.size.width), height: Double(frame.size.height))
        guard size.width > 0, size.height > 0 else { throw ShaderError("The drawing buffer is empty.") }
        let area = (region ?? CGRect(x: 0, y: 0, width: size.width, height: size.height)).standardized
        guard area.width > 0, area.height > 0 else { throw ShaderError("The region to draw is empty.") }
        self.size = size
        self.region = (Double(area.minX), Double(area.minY), Double(area.width), Double(area.height))
        output = (Double(width), Double(height))
    }
}

/// One attribute's place in a vertex buffer, by location.
struct AttributeLayout: Hashable {
    var location: Int
    var base: ProgramLayout.Base
    /// How many numbers it reads, 1 to 4.
    var width: Int
    var buffer: Int
    var offset: Int
    var stride: Int
    /// The same value for every vertex: a disabled array, or an attribute never given.
    var constant: Bool
}

/// The vertex buffers and their layout for a draw: arrays per vertex, disabled arrays and
/// attributes the page never set as constants (WebGL's default is 0, 0, 0, 1).
struct VertexLayout {
    var attributes: [AttributeLayout] = []
    var buffers: [(Int, [UInt8])] = []
    /// How many vertices the arrays hold; nil without arrays.
    var vertices: Int?

    /// The buffers from `firstBuffer` on, one an input in the order of their locations.
    init(_ draw: ShaderDraw, _ program: ProgramLayout, firstBuffer: Int) {
        for (i, input) in program.inputs.enumerated() {
            let buffer = firstBuffer + i
            let columns = max(1, input.columns), rows = max(1, min(4, input.rows))
            if let attribute = draw.attributes[input.name], attribute.constant == nil, attribute.components > 0 {
                let components = attribute.components
                let vertices = attribute.values.count / components
                self.vertices = min(self.vertices ?? vertices, vertices)
                let width = columns > 1 ? rows : min(4, components)
                for column in 0..<columns {
                    attributes.append(AttributeLayout(location: input.location + column, base: input.base, width: width,
                                                      buffer: buffer, offset: column * rows * 4, stride: components * 4,
                                                      constant: false))
                }
                buffers.append((buffer, Packing.bytes(attribute.values, input.base)))
            } else {
                // Each column its own four numbers, defaults filling what the constant leaves out.
                let given = draw.attributes[input.name]?.constant ?? []
                var values: [Float] = []
                for column in 0..<columns {
                    var value: [Float] = [0, 0, 0, 1]
                    let per = columns > 1 ? rows : 4
                    for k in 0..<min(per, 4) where column * per + k < given.count { value[k] = given[column * per + k] }
                    values += value
                    attributes.append(AttributeLayout(location: input.location + column, base: input.base, width: 4,
                                                      buffer: buffer, offset: column * 16, stride: 16 * columns,
                                                      constant: true))
                }
                buffers.append((buffer, Packing.bytes(values, input.base)))
            }
        }
    }
}

extension DrawPlan {
    /// A draw worked out, or nil for one WebGL would draw nothing of: none to draw, reading past
    /// an array, or a viewport that misses the region. `layout` is its vertex layout, made first
    /// so that a back end could make what the program needs before.
    init?(_ draw: ShaderDraw, program: ProgramLayout, layout: VertexLayout, geometry: Geometry) {
        guard draw.count > 0, draw.first >= 0 else { return nil }

        // What WebGL would refuse to draw (reading past an array) draws nothing.
        if let indices = draw.indices {
            guard draw.first + draw.count <= indices.count else { return nil }
            let used = indices[draw.first..<(draw.first + draw.count)]
            if let vertices = layout.vertices, let top = used.lazy.filter({ $0 != .max }).max(), Int(top) >= vertices {
                return nil
            }
        } else if let vertices = layout.vertices, draw.first + draw.count > vertices {
            return nil
        }
        /// The vertices drawn, in order: for fans and loops, which Metal and Direct3D do not draw.
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
            call = .indexed(fan, first: 0, count: fan.count)
        case .lineLoop:
            let vertexList = vertexList
            guard vertexList.count >= 2 else { return nil }
            let loop = vertexList + [vertexList[0]]
            primitive = .lineStrip
            call = .indexed(loop, first: 0, count: loop.count)
        default:
            switch draw.mode {
            case .triangles: primitive = .triangle
            case .triangleStrip: primitive = .triangleStrip
            case .lines: primitive = .line
            case .lineStrip: primitive = .lineStrip
            default: primitive = .point
            }
            if let indices = draw.indices {
                call = .indexed(indices, first: draw.first, count: draw.count)
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
        scissor = Scissor(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
        // gl_FragCoord from the output's pixels, top-left origin, to the drawing buffer's, bottom-left.
        let own: [String: [Float]] = [
            "bezzle_clip": clip,
            "bezzle_fragCoord": [Float(rw / w), Float(-rh / h), Float(rx), Float(H - ry)],
            "bezzle_pointScale": [Float((w / rw + h / rh) / 2)],
        ]
        let values = Uniforms(draw.uniforms, own: own)
        vertexBuffers = layout.buffers
        vertexUniforms = program.vertex.buffers.map { ($0.index, values.pack($0)) }
        fragmentUniforms = program.fragment.buffers.map { ($0.index, values.pack($0)) }
        vertexTextures = Self.textures(program.vertex.textures, draw)
        fragmentTextures = Self.textures(program.fragment.textures, draw)
        flipsTextures = draw.flipsTextures
        premultipliesTextures = draw.premultipliesTextures
        blendColor = draw.blend?.color
    }

    /// Each sampler's picture by its name, or an array's element's, and how it is read.
    private static func textures(_ list: [ProgramLayout.Texture], _ draw: ShaderDraw) -> [Texture] {
        var bound: [Texture] = []
        for texture in list {
            for element in 0..<max(1, texture.count) {
                let name = texture.count > 1 ? "\(texture.name)[\(element)]" : texture.name
                let image = draw.textures[name] ?? (element == 0 ? draw.textures[texture.name] ?? draw.textures["\(texture.name)[0]"] : nil)
                let sampling = draw.sampling[name] ?? draw.sampling[texture.name] ?? ShaderDraw.Sampling()
                bound.append(Texture(slot: texture.index + element, picture: image, sampling: sampling, cube: texture.cube))
            }
        }
        return bound
    }
}

/// Numbers as the stages read them.
enum Packing {
    static func bytes(_ values: [Float], _ base: ProgramLayout.Base) -> [UInt8] {
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

    /// Premultiplied RGBA made straight again, as WebGL uploads a picture without
    /// UNPACK_PREMULTIPLY_ALPHA_WEBGL: each colour divided by its alpha, rounded.
    static func straighten(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            if alpha == 0 || alpha == 255 { continue }
            for c in 0..<3 {
                pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + alpha / 2) / alpha))
            }
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

    func pack(_ buffer: ProgramLayout.Buffer) -> [UInt8] {
        // A struct's size rounded up to its alignment, which in a uniform block is at most 16, as
        // Metal and Direct3D's constant buffers both take it.
        var bytes = [UInt8](repeating: 0, count: (max(16, buffer.size) + 15) / 16 * 16)
        bytes.withUnsafeMutableBytes { raw in
            for member in buffer.members { write(member, into: raw) }
        }
        return bytes
    }

    private func write(_ member: ProgramLayout.Member, into raw: UnsafeMutableRawBufferPointer) {
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
                case .uint: raw.storeBytes(of: Packing.unsigned(value), toByteOffset: offset, as: UInt32.self)
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
