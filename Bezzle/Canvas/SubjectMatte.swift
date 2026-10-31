import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// A learned matte of what stands out in a picture, hair by hair: BiRefNet (Peng Zheng et al.,
/// MIT licence), its high-resolution model trained at 2,048 pixels, converted to Core ML with its
/// weights kept to 8 bits (Scripts/subject-matte). `CutoutMaker` keeps it to the subject picked.
///
/// It runs on the GPU. The Neural Engine gets this model wrong, and slowly.
nonisolated final class SubjectMatte: CutoutMaker.Matting, @unchecked Sendable {
    /// The size the model sees a picture at, squeezed square.
    static let side = 2048
    /// Which model this is. Cutouts made with it are named for it (`cutoutName`), so a new one
    /// cuts pictures out afresh rather than finding the old one's.
    static let version = 1

    private let model: MLModel
    /// One picture at a time: the model is large, and running it twice at once only slows both.
    private let busy = NSLock()

    /// The compiled model (`.mlmodelc`) at `url`, or a model package (`.mlpackage`), compiled first.
    init(contentsOf url: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let compiled = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
    }

    /// How solid each pixel of `picture` is, `side` × `side`, for `CutoutMaker`.
    func matte(of picture: CGImage) throws -> CutoutMaker.Plane {
        let input = try Self.square(picture)
        let output = try busy.withLock {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        }
        guard let values = output.featureValue(for: "matte")?.multiArrayValue, values.count == Self.side * Self.side else {
            throw CutoutMaker.Failure.unreadable
        }
        let matte = CutoutMaker.Plane(Self.side, Self.side)
        MLShapedArray<Float>(converting: values).withUnsafeShapedBufferPointer { scalars, _, _ in
            matte.p.update(from: scalars.baseAddress!, count: matte.count)
        }
        return matte
    }

    /// `picture` squeezed into the square the model sees, as the model was measured with.
    private static func square(_ picture: CGImage) throws -> CVPixelBuffer {
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
