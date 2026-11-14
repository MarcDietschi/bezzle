import Foundation

/// Shader fills (`ShaderFill`), which the Mac draws with Metal and Windows with Direct3D (the
/// engine in Packages/Shaders, through Bezzle/Canvas/ShaderPainting.swift). In the browser the
/// page draws them, with WebGL, which is what their programs were written for (site/shaders.mjs):
/// in the design at the fill's own moment and in a film at the film's, for the part of the layer
/// a picture shows and as sharp as it shows there, as the Mac's does. Where the page has no WebGL
/// (Node), or a program does not build, the fill's picture stands in, as it came in. Bezzle for
/// Windows leaves this file out and compiles the Mac's own.
nonisolated enum ShaderPainting {
    /// What of a fill stays the same from moment to moment (its programs, vertices and pictures),
    /// by the number the page knows it by: handed over once, and after that only the inputs.
    nonisolated(unsafe) private static var known: [ShaderFill: Int] = [:]
    /// Fills whose programs did not build on the page: not tried again frame after frame.
    nonisolated(unsafe) private static var broken: Set<Int> = []
    nonisolated(unsafe) private static var next = 1
    /// Whether the page has said it cannot draw shaders at all.
    nonisolated(unsafe) private static var unavailable = false

    /// The longest side the page draws a shader with, in pixels.
    private static let most: CGFloat = 4096

    /// Draws a shader fill inside an outline, a layer of `size` with its top left at zero, at the
    /// film's moment `film` (the design's moment when nil): placed as its picture is, or in the
    /// whole box. Says whether it drew, so that the picture is drawn when it did not.
    static func paint(_ shader: ShaderFill, picture: ImageFill?, in path: CGPath, size: CGSize, rule: CGPathFillRule,
                      in ctx: CGContext, film: Double?, assets: Assets?, box: CGRect? = nil) -> Bool {
        // What a fill holds beyond draws onto its canvas (passes into textures, depth and
        // stencil, instances, textures of numbers: `ShaderFill.beyondPlain`) the page does not
        // draw yet, and would draw wrongly: its picture stands in.
        guard !unavailable, !shader.beyondPlain else { return false }
        let box = box ?? CGRect(origin: .zero, size: size)
        let drawn = picture.map { Renderer.imageRect($0, in: box.size).offsetBy(dx: box.minX, dy: box.minY) } ?? box
        guard drawn.width > 0, drawn.height > 0, shader.size.width >= 1, shader.size.height >= 1 else { return false }
        // Only what shows: the part of it inside the outline and in the picture being drawn.
        var part = drawn.intersection(path.boundingBoxOfPath)
        if ctx.width > 0 { part = part.intersection(ctx.boundingBoxOfClipPath) }
        guard !part.isNull, part.width > 0.01, part.height > 0.01 else { return true }
        var scale = ctx.width > 0 ? Renderer.pixelScale(ctx) : 2
        while part.width * scale > most || part.height * scale > most { scale /= 2 }
        let pixels = CGSize(width: max(1, (part.width * scale).rounded(.up)), height: max(1, (part.height * scale).rounded(.up)))
        // That part of the drawing buffer, from its top left; across the other way where it was flipped.
        let across = shader.size.width / drawn.width, down = shader.size.height / drawn.height
        var region = CGRect(x: (part.minX - drawn.minX) * across, y: (part.minY - drawn.minY) * down,
                            width: part.width * across, height: part.height * down)
        if shader.flippedX == true { region.origin.x = shader.size.width - region.maxX }
        if shader.flippedY == true { region.origin.y = shader.size.height - region.maxY }
        guard let image = image(of: shader, at: shader.time(film: film), pixels: pixels, region: region) else { return false }
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

    /// The fill's frame at its own time `t` as the page draws it: `region` of its drawing buffer,
    /// counted from the top left, `pixels` large. Nil when the page cannot.
    private static func image(of shader: ShaderFill, at t: Double, pixels: CGSize, region: CGRect) -> CGImage? {
        // What the page keeps of it: all but its inputs and how its time runs.
        var fixed = shader
        fixed.at = 0
        fixed.speed = 1
        fixed.clocks = []
        fixed.recordings = nil
        fixed.flippedX = nil
        fixed.flippedY = nil
        for i in fixed.draws.indices { fixed.draws[i].uniforms = [:] }
        let id: Int
        if let k = known[fixed] {
            id = k
        } else {
            // A design changed again and again leaves fills behind that are drawn no more.
            if known.count >= 64 {
                known = [:]
                broken = []
                _ = Host.call(.shader, string: "{\"forget\":true}")
            }
            id = next
            next += 1
            known[fixed] = id
            guard let data = try? JSONEncoder().encode(fixed) else {
                broken.insert(id)
                return nil
            }
            let said = reply(Host.call(.shader, string: "{\"define\":\(id),\"fill\":" + String(decoding: data, as: UTF8.self) + "}"))
            if said["unavailable"] != nil { unavailable = true }
            if said["ok"] == nil { broken.insert(id) }
        }
        guard !broken.contains(id), !unavailable else { return nil }
        let inputs = shader.draws.map { draw -> String in
            let all = shader.uniforms(of: draw, at: t).sorted { $0.key < $1.key }.map { name, values in
                quoted(name) + ":[" + values.map { $0.isFinite ? "\($0)" : "0" }.joined(separator: ",") + "]"
            }
            return "{" + all.joined(separator: ",") + "}"
        }
        let said = reply(Host.call(.shader, string: "{\"draw\":\(id),\"uniforms\":[" + inputs.joined(separator: ",") + "],"
            + "\"pixels\":[\(Int(pixels.width)),\(Int(pixels.height))],\"region\":[\(region.minX),\(region.minY),\(region.width),\(region.height)]}"))
        guard let asset = said["asset"] as? Int, let w = said["w"] as? Int, let h = said["h"] as? Int, asset > 0, w > 0, h > 0 else {
            // A program that does not build, or a picture that is not there: the picture stands in.
            if said["broken"] != nil { broken.insert(id) }
            return nil
        }
        return CGImage(width: w, height: h, source: .asset(asset))
    }

    private static func reply(_ s: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]) ?? [:]
    }

    private static func quoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
