import Foundation

/// Shader fills (`ShaderFill`), which the Mac draws with Metal and Windows with Direct3D (the
/// engine in Packages/Shaders, through Bezzle/Canvas/ShaderPainting.swift). In the browser they do
/// not draw: the fill's picture, as it came in, stands in for them. Bezzle for Windows leaves this
/// file out and compiles the Mac's own.
nonisolated enum ShaderPainting {
    static func paint(_ shader: ShaderFill, picture: ImageFill?, in path: CGPath, size: CGSize, rule: CGPathFillRule,
                      in ctx: CGContext, film: Double?, assets: Assets?, box: CGRect? = nil) -> Bool { false }
}
