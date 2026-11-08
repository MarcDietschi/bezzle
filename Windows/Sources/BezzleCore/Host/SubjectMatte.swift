import Foundation
import CBezzleHost

// From Bezzle/Canvas/SubjectMatte.swift and Store/SubjectModel.swift: the same model the Mac runs,
// BiRefNet_HR at 2,048 pixels, exported to ONNX (Scripts/subject-matte/make-onnx.sh) and run with
// ONNX Runtime (CBezzleHost/matte.cpp): on the graphics card through DirectML where this PC has one
// Direct3D 12 runs on, else on the processor, as the Mac runs it with Core ML on its GPU. The Mac's
// weights are kept to 8 bits; these are half precision, but for sampling (as the Mac's).

/// A learned matte of what stands out in a picture, hair by hair: BiRefNet (Peng Zheng et al.,
/// MIT licence), its high-resolution model trained at 2,048 pixels. `CutoutMaker` keeps it to the
/// subject picked.
nonisolated final class SubjectMatte: CutoutMaker.Matting, @unchecked Sendable {
    /// The size the model sees a picture at, squeezed square.
    static let side = 2048
    /// Which model this is: the Mac's (`SubjectMatte.version` there), as it is the same model.
    /// Cutouts made with it are named for it (`cutoutName`), so a new one cuts pictures out afresh
    /// rather than finding the old one's, here and on a Mac sharing the design alike.
    static let version = 1

    private let handle: UnsafeMutableRawPointer
    /// Where it runs now, in words: "DirectML on …" or "processor" (where a graphics card gave up
    /// on it, the processor from then on, and why).
    var device: String {
        var on = [CChar](repeating: 0, count: 512)
        _ = bz_matte_device(handle, &on, Int32(on.count))
        return String(cString: on)
    }
    /// The last pictures' mattes, by what they are called (`remembered`), as placing a cutout asks
    /// for the parts of one just cut out.
    private var kept: [(key: String, matte: CutoutMaker.Plane)] = []
    private let keeping = NSLock()

    /// Where the model runs: `auto` on the graphics card if it can, else the processor; `processor`;
    /// `directML` on any adapter, Windows' software one too (for trying it where there is no other).
    enum Device: Int32 { case auto = 0, processor = 1, directML = 2 }

    /// The model at `url`, ready to run (DirectML compiles it for the card first: a few seconds).
    init(contentsOf url: URL, on device: Device = .auto) throws {
        var error = [CChar](repeating: 0, count: 1024), on = [CChar](repeating: 0, count: 512)
        guard let made = bz_matte_open(url.path, device.rawValue, &error, Int32(error.count), &on, Int32(on.count)) else {
            throw Trouble(description: String(cString: error))
        }
        handle = made
    }

    deinit { bz_matte_close(handle) }

    struct Trouble: Swift.Error, CustomStringConvertible { let description: String }

    /// How solid each pixel of `picture` is, `side` × `side`, for `CutoutMaker`.
    func matte(of picture: CutoutMaker.Pixels) throws -> CutoutMaker.Plane {
        let input = try Self.square(picture)
        let matte = CutoutMaker.Plane(Self.side, Self.side)
        var error = [CChar](repeating: 0, count: 1024)
        let done = input.withUnsafeBufferPointer { bz_matte_run(handle, $0.baseAddress, Int32(Self.side), matte.p, &error, Int32(error.count)) }
        guard done == 0 else { throw Trouble(description: String(cString: error)) }
        return matte
    }

    /// The matte of the picture called `key`, made once and kept for a while.
    func matte(of picture: CutoutMaker.Pixels, remembered key: String) throws -> CutoutMaker.Plane {
        if let found = keeping.withLock({ kept.first { $0.key == key }?.matte }) { return found }
        let made = try matte(of: picture)
        keeping.withLock {
            kept.removeAll { $0.key == key }
            kept.append((key, made))
            if kept.count > 3 { kept.removeFirst() }
        }
        return made
    }

    /// Whether the picture called `key` has its matte kept.
    func remembers(_ key: String) -> Bool { keeping.withLock { kept.contains { $0.key == key } } }

    /// `picture` squeezed into the square the model sees, as the Mac's draws it: red, green and
    /// blue planes, 0…1.
    static func square(_ picture: CutoutMaker.Pixels) throws -> [Float] {
        guard let square = picture.w == side && picture.h == side ? picture : picture.scaled(side, side) else {
            throw CutoutMaker.Failure.unreadable
        }
        let n = side * side
        var planes = [Float](repeating: 0, count: 3 * n)
        square.bytes.withUnsafeBufferPointer { px in
            planes.withUnsafeMutableBufferPointer { out in
                let o = out.baseAddress!
                CutoutMaker.par(n) { r in
                    for i in r {
                        // Over white where it is see-through, as the Mac's context is filled first.
                        let white = Float(255 - px[i * 4 + 3])
                        o[i] = (Float(px[i * 4]) + white) / 255
                        o[n + i] = (Float(px[i * 4 + 1]) + white) / 255
                        o[2 * n + i] = (Float(px[i * 4 + 2]) + white) / 255
                    }
                }
            }
        }
        return planes
    }
}

/// A picture's matte kept by name, as `CutoutMaker` asks for it: the same picture cut out again
/// (with other picks) or placed asks the model once.
nonisolated struct RememberedMatte: CutoutMaker.Matting {
    let matting: SubjectMatte
    let key: String
    func matte(of picture: CutoutMaker.Pixels) throws -> CutoutMaker.Plane { try matting.matte(of: picture, remembered: key) }
}

/// The learned subject matte, loaded the first time a background is taken away and kept while
/// Bezzle runs. It comes with Bezzle: BiRefNet.onnx in Bezzle.resources beside Bezzle.exe (the
/// installer puts it there, build.ps1 for a copy built here). BEZZLE_MATTE_MODEL takes another,
/// BEZZLE_MATTE_DEVICE=cpu runs it on the processor (gpu: DirectML on any adapter, a software one too).
///
/// Without it, nothing is cut out on Windows: the Mac's older way needs Apple's Vision.
public final class SubjectModel {
    public static let shared = SubjectModel()

    private var loading: Task<SubjectMatte?, Never>?
    /// Why the model could not be loaded, if it could not.
    public private(set) var trouble: String?

    private init() {}

    /// Where the model is, if Bezzle has one.
    nonisolated static var file: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["BEZZLE_MATTE_MODEL"], !path.isEmpty { return URL(fileURLWithPath: path) }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("BiRefNet.onnx"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether Bezzle can take backgrounds away here: the model, and ONNX Runtime beside Bezzle
    /// (looked for, not loaded: that waits until a background is taken away).
    public static var isAvailable: Bool {
        let runtime = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("onnxruntime.dll")
        return file != nil && FileManager.default.fileExists(atPath: runtime.path)
    }

    /// The matte, loaded first if need be (off the main thread); nil when there is none.
    func matte() async -> SubjectMatte? {
        let task = loading ?? Task.detached(priority: .userInitiated) { Self.load() }
        loading = task
        let matte = await task.value
        if matte == nil { trouble = Self.lastTrouble }
        return matte
    }

    nonisolated(unsafe) private static var lastTrouble: String?
    /// Hears where the model runs, or why it could not be loaded (the app's trace, a tool's output).
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    private nonisolated static func load() -> SubjectMatte? {
        guard let url = file else { return nil }
        let device: SubjectMatte.Device = switch ProcessInfo.processInfo.environment["BEZZLE_MATTE_DEVICE"]?.lowercased() {
        case "cpu", "processor": .processor
        case "gpu", "directml": .directML
        default: .auto
        }
        do {
            let matte = try SubjectMatte(contentsOf: url, on: device)
            log?("subject matte: \(url.lastPathComponent) on \(matte.device)")
            return matte
        } catch {
            lastTrouble = "\(error)"
            log?("Bezzle could not load the subject matte: \(error)")
            return nil
        }
    }
}
