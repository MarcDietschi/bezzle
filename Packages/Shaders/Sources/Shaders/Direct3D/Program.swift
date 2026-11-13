import Foundation
import ShaderCompiler
import ShaderDirect3D

/// Something made with Direct3D (a program, input layout, state or texture), let go of with it.
final class Handle: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(_ pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }

    deinit { bz_d3d_release(pointer) }
}

/// The text a C call wrote, let go of.
func taken(_ text: UnsafeMutablePointer<CChar>?) -> String {
    guard let text else { return "" }
    defer { bz_d3d_free(text) }
    return String(cString: text)
}

/// A WebGL program translated to HLSL and built with Direct3D 11: its stages and its layout
/// (`ProgramLayout`, the same as the Mac's), every name as the page wrote it.
final class Program: @unchecked Sendable {
    let layout: ProgramLayout
    let handle: Handle
    /// The vertex stage sets a point size, so points are drawn by Bezzle's geometry shader.
    let drawsPoints: Bool
    /// How long glslang and SPIRV-Cross took, and Direct3D's compiler after them, in seconds.
    let translationTime: Double
    let buildTime: Double

    var interface: ShaderInterface { layout.interface }

    private let lock = NSLock()
    private var layouts: [[AttributeLayout]: Handle] = [:]

    /// As many attributes as the Mac binds, so a program builds on both or on neither.
    static let mostAttributes = 17

    init(device: OpaquePointer, vertex vertexSource: String, fragment fragmentSource: String) throws {
        let start = Date()
        let fragmentShader = Upgrade.upgrade(fragmentSource, stage: .fragment, sprites: .init(coordinates: false))
        let vertexShader = Upgrade.upgrade(vertexSource, stage: .vertex,
                                           sprites: .init(coordinates: fragmentShader.readsPointCoord))
        var translation = BZHLSLTranslation()
        let translated = bz_translate_hlsl(vertexShader.source, fragmentShader.source, &translation)
        defer { bz_hlsl_translation_free(&translation) }
        let log = translation.log.map { String(cString: $0) } ?? ""
        guard translated == 1, let vertexHLSL = translation.vertex, let fragmentHLSL = translation.fragment,
              let json = translation.reflection else {
            throw ShaderError(log.isEmpty ? "The program did not translate." : log)
        }
        var original = vertexShader.original
        original.merge(fragmentShader.original) { first, _ in first }
        layout = try ProgramLayout(reflection: String(cString: json), original: original)
        translationTime = Date().timeIntervalSince(start)
        if layout.inputs.count > Program.mostAttributes {
            throw ShaderError("The program takes more attributes than Bezzle binds.")
        }

        var message: UnsafeMutablePointer<CChar>?
        var seconds = 0.0
        guard let made = bz_d3d_program(device, vertexHLSL, fragmentHLSL, translation.points, translation.lines, &message,
                                        &seconds) else {
            let why = taken(message)
            throw ShaderError(why.isEmpty ? "Direct3D: the program does not build." : why)
        }
        handle = Handle(made)
        drawsPoints = translation.points != nil
        buildTime = seconds
    }

    /// The input layout for these attributes; nil for a vertex stage that takes none.
    func inputLayout(_ attributes: [AttributeLayout], device: OpaquePointer) throws -> Handle? {
        guard !attributes.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let layout = layouts[attributes] { return layout }
        let elements = attributes.map { attribute in
            BZD3DElement(location: Int32(attribute.location), base: attribute.base.number, width: Int32(attribute.width),
                         slot: Int32(attribute.buffer), offset: Int32(attribute.offset), constant: attribute.constant ? 1 : 0)
        }
        var message: UnsafeMutablePointer<CChar>?
        guard let made = bz_d3d_layout(device, handle.pointer, elements, Int32(elements.count), &message) else {
            let why = taken(message)
            throw ShaderError(why.isEmpty ? "Direct3D: the program does not build." : why)
        }
        let layout = Handle(made)
        layouts[attributes] = layout
        return layout
    }
}

extension ProgramLayout.Base {
    /// As ShaderDirect3D.h numbers it.
    var number: Int32 {
        switch self {
        case .float: 0
        case .int: 1
        case .uint: 2
        }
    }
}
