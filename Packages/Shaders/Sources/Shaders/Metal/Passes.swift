import Foundation
import Metal

/// A texture a pass drew into, given back to the pool it came from when nothing holds it any
/// more: a frame's passes make many, the same sizes again and again.
final class Held: @unchecked Sendable {
    let texture: MTLTexture
    private weak var pool: TexturePool?

    init(_ texture: MTLTexture, pool: TexturePool?) {
        self.texture = texture
        self.pool = pool
    }

    deinit { pool?.recycle(texture) }
}

/// Textures to draw into, kept for the next that asks for one alike.
final class TexturePool: @unchecked Sendable {
    struct Key: Hashable {
        var width: Int
        var height: Int
        var format: UInt
        var mipmapped: Bool
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var idle: [Key: [MTLTexture]] = [:]
    private var order: [Key] = []
    private var bytes = 0
    /// How much lies idle at most.
    private let budget = 256 << 20

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(width: Int, height: Int, format: MTLPixelFormat, mipmapped: Bool) throws -> Held {
        let key = Key(width: width, height: height, format: format.rawValue, mipmapped: mipmapped)
        let found: MTLTexture? = lock.withLock {
            guard let texture = idle[key]?.popLast() else { return nil }
            if let index = order.lastIndex(of: key) { order.remove(at: index) }
            bytes -= texture.allocatedSize
            return texture
        }
        if let found { return Held(found, pool: self) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: mipmapped)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Read and written by the processor too (a target's first contents), where it can be.
        descriptor.storageMode = format == Program.depthFormat ? .private : device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ShaderError("Metal: out of memory for a target of \(width) by \(height).")
        }
        return Held(texture, pool: self)
    }

    fileprivate func recycle(_ texture: MTLTexture) {
        let key = Key(width: texture.width, height: texture.height, format: texture.pixelFormat.rawValue,
                      mipmapped: texture.mipmapLevelCount > 1)
        lock.withLock {
            idle[key, default: []].append(texture)
            order.append(key)
            bytes += texture.allocatedSize
            while bytes > budget, let oldest = order.first {
                order.removeFirst()
                if let texture = idle[oldest]?.first {
                    idle[oldest]?.removeFirst()
                    bytes -= texture.allocatedSize
                }
            }
        }
    }
}

/// What a frame's passes into targets left: for each of its passes onto the canvas, what every
/// target held when the page drew that pass, and what the targets that keep hold for the frame
/// after. Nothing in it is drawn into again.
final class Drawn: @unchecked Sendable {
    /// By the pass's place among the frame's, for those onto the canvas: each target's texture then.
    let seen: [Int: [Held?]]
    /// Each target's texture after the last pass.
    let left: [Held?]
    /// The commands that draw them, to wait for where another queue reads them.
    let commands: MTLCommandBuffer?

    init(seen: [Int: [Held?]], left: [Held?], commands: MTLCommandBuffer?) {
        self.seen = seen
        self.left = left
        self.commands = commands
    }

    var cost: Int {
        var counted = Set<ObjectIdentifier>(), bytes = 0
        for held in left + seen.values.flatMap({ $0 }) {
            guard let held, counted.insert(ObjectIdentifier(held)).inserted else { continue }
            bytes += held.texture.allocatedSize
        }
        return bytes
    }
}

/// What the targets that keep held at the steps of each recording that were drawn: the step
/// asked for last, and one every so often before it, so that a film played on goes one step at a
/// time and one scrubbed back starts from near where it is wanted.
final class Timelines: @unchecked Sendable {
    /// One step in so many is kept, besides the latest.
    static let stride = Feedback.stride

    private final class Line {
        let lock = NSLock()
        var states: [Int: [Held?]] = [:]
        var bytes = 0
        var used = 0
    }

    private let lock = NSLock()
    private var lines: [Int: Line] = [:]
    private var clock = 0
    /// At most so many bytes of kept states, the recordings together.
    private let budget = 384 << 20
    /// And a recording's own.
    private let lineBudget = 192 << 20

    /// What a recording's targets hold before `step`, from the nearest step kept: `first` makes
    /// what they hold before step 0, `advance` what they hold after a step from what they held
    /// before it. One thread at a time works on a recording; the others wait for it.
    func state(recording: Int, step: Int, first: () throws -> [Held?],
               advance: (Int, [Held?]) throws -> [Held?]) throws -> [Held?] {
        let line = line(recording)
        return try line.lock.withLock {
            var at = line.states.keys.filter { $0 <= step }.max()
            var state: [Held?]
            if let at {
                state = line.states[at]!
            } else {
                state = try first()
                at = 0
                keep(state, at: 0, in: line)
            }
            var k = at!
            while k < step {
                state = try advance(k, state)
                k += 1
                if k % Self.stride == 0 || k == step { keep(state, at: k, in: line) }
            }
            return state
        }
    }

    /// Keeps what a recording's targets hold before `step`, which drawing the step before made.
    func keep(_ state: [Held?], recording: Int, step: Int) {
        let line = line(recording)
        line.lock.withLock { keep(state, at: step, in: line) }
    }

    private func line(_ recording: Int) -> Line {
        lock.withLock {
            clock += 1
            let line = lines[recording] ?? Line()
            line.used = clock
            lines[recording] = line
            // The recordings not drawn for longest give way.
            var total = lines.values.reduce(0) { $0 + $1.bytes }
            while total > budget, let oldest = lines.filter({ $0.value !== line }).min(by: { $0.value.used < $1.value.used }) {
                total -= oldest.value.bytes
                lines[oldest.key] = nil
            }
            return line
        }
    }

    /// Under the line's lock.
    private func keep(_ state: [Held?], at step: Int, in line: Line) {
        guard line.states[step] == nil else { return }
        line.states[step] = state
        let cost = Self.cost(state)
        line.bytes += cost
        // Steps between the kept ones give way first, the oldest of them, then the oldest kept.
        while line.bytes > lineBudget, line.states.count > 1 {
            let others = line.states.keys.filter { $0 != step }
            guard let gone = others.filter({ $0 % Self.stride != 0 }).min() ?? others.min() else { break }
            line.bytes -= Self.cost(line.states[gone] ?? [])
            line.states[gone] = nil
        }
        // Of the steps that are no one in so many, only the latest two stay.
        let loose = line.states.keys.filter { $0 % Self.stride != 0 && $0 != step }.sorted()
        for gone in loose.dropLast(1) {
            line.bytes -= Self.cost(line.states[gone] ?? [])
            line.states[gone] = nil
        }
    }

    private static func cost(_ state: [Held?]) -> Int {
        state.reduce(0) { $0 + ($1?.texture.allocatedSize ?? 0) }
    }
}
