import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// A learned matte of what stands out in a picture, hair by hair: BiRefNet (Peng Zheng et al.,
/// MIT licence), its high-resolution model, converted to Core ML with its weights kept to 8 bits
/// (Scripts/subject-matte). `CutoutMaker` keeps it to the subject picked.
///
/// The model comes at two sizes that share their weights, and runs on the GPU or on the processor:
/// a `Route` is one of the four. They differ a great deal in what they ask of a Mac (measured,
/// Scripts/subject-matte/README.md): the fine size on the GPU holds 20 GB, the light size on the
/// processor 1.1 GB. `SubjectModel` picks the one this Mac and this picture are best served by.
/// The Neural Engine gets this model wrong, and slowly.
nonisolated final class SubjectMatte: CutoutMaker.Matting, @unchecked Sendable {
    /// Which model this is. Cutouts made with it are named for it (`cutoutName`), so a new one
    /// cuts pictures out afresh rather than finding the old one's.
    static let version = 1

    /// How finely a picture was cut out: what its cutout is named for, so a finer one is never
    /// passed over for a plainer one made on another computer.
    enum Grade: Int, Comparable, CaseIterable, Sendable {
        /// Without the model: Vision's subject, its edge fitted to the photo.
        case plain
        /// The model at 1,024 pixels.
        case light
        /// The model at 2,048 pixels.
        case fine

        static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
    }

    /// One way of making a matte: the size the model sees the picture at, squeezed square, and
    /// where it runs.
    struct Route: Hashable, Sendable, CustomStringConvertible {
        var side: Int
        var onGPU: Bool

        static let fineOnGPU = Route(side: 2048, onGPU: true), fine = Route(side: 2048, onGPU: false)
        static let lightOnGPU = Route(side: 1024, onGPU: true), light = Route(side: 1024, onGPU: false)
        static let all = [fineOnGPU, fine, lightOnGPU, light]

        /// What it is called where it is remembered, and for trying one alone (BEZZLE_MATTE_ROUTE).
        var description: String { "\(onGPU ? "gpu" : "cpu")\(side)" }
        var grade: Grade { side >= 2048 ? .fine : .light }
        /// The model's function for this size.
        var function: String { "side\(side)" }

        /// The memory it holds while it runs, in bytes: on the GPU for as long as the model is
        /// kept, on the processor only during a run. Measured on an M5 Pro; four times the
        /// pixels take four times the memory, and the GPU over four times the processor's.
        var holds: UInt64 {
            let megabytes: UInt64 = switch (side >= 2048, onGPU) {
            case (true, true): 20_000
            case (true, false): 4_300
            case (false, true): 5_000
            case (false, false): 1_100
            }
            return megabytes * 1_000_000
        }

        /// How many seconds a matte takes on a Mac nothing is known of yet, from what an M5 Pro
        /// took: on the processor, longer the fewer fast cores there are.
        func seconds(fastCores: Int) -> Double {
            let slower = max(1, 18 / Double(max(fastCores, 1))) * 1.2
            return switch (side >= 2048, onGPU) {
            case (true, true): 1.2
            case (true, false): 6 * slower
            case (false, true): 0.4
            case (false, false): 1.5 * slower
            }
        }

        /// How many seconds the first matte ever takes on a Mac, loading the model and making
        /// the matte, as an M5 Pro took: Core ML fits the model to the processor or the GPU
        /// then, and keeps that. Every matte after it takes a fraction (`seconds`).
        var first: (load: Double, matte: Double) {
            switch (side >= 2048, onGPU) {
            case (true, true): (12.9, 23.1)
            case (true, false): (3.8, 6.9)
            case (false, true): (7.6, 5.2)
            case (false, false): (6.8, 1.8)
            }
        }
    }

    let route: Route
    private let model: MLModel

    /// The compiled model (`.mlmodelc`) at `url`, made ready for `route`. A model of one size
    /// alone, as Bezzle came with before it had two, is the fine one.
    init(contentsOf url: URL, route: Route) throws {
        self.route = route
        let configuration = MLModelConfiguration()
        configuration.computeUnits = route.onGPU ? .cpuAndGPU : .cpuOnly
        configuration.functionName = route.function
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            guard route.side == 2048 else { throw error }
            configuration.functionName = nil
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
    }

    /// How solid each pixel of `picture` is, `route.side` square, for `CutoutMaker`.
    func matte(of picture: CGImage) throws -> CutoutMaker.Plane {
        let side = route.side
        let input = try Self.square(picture, side)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        guard let values = output.featureValue(for: "matte")?.multiArrayValue, values.count == side * side else {
            throw CutoutMaker.Failure.unreadable
        }
        let matte = CutoutMaker.Plane(side, side)
        MLShapedArray<Float>(converting: values).withUnsafeShapedBufferPointer { scalars, _, _ in
            matte.p.update(from: scalars.baseAddress!, count: matte.count)
        }
        return matte
    }

    /// `picture` squeezed into the square the model sees, as the model was measured with.
    private static func square(_ picture: CGImage, _ side: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { throw CutoutMaker.Failure.unreadable }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CutoutMaker.Failure.unreadable }
        ctx.interpolationQuality = .high
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}
