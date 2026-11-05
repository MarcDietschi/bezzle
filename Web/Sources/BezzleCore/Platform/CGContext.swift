import Foundation

/// A Core Graphics context that draws nothing itself: it writes down each drawing call, for the
/// page to make with CanvasKit, keeping the state Core Graphics keeps (the transform, the clip's
/// bounds, colours, alpha, blend mode, shadow), so code that asks it questions gets the answers
/// Core Graphics would give.
///
/// Its space is Core Graphics' own: device pixels, y up from the bottom left, `width` by
/// `height`. Paths are kept in device space as they are added, as Core Graphics keeps them, and
/// written down in user space at the transform current when they are filled.
nonisolated public final class CGContext: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public private(set) var commands: [Double] = []

    struct State {
        var ctm = CGAffineTransform.identity
        /// The clip's bounds in device space.
        var clip: CGRect
        var fill = CGColor.black
        var stroke = CGColor.black
        var lineWidth: CGFloat = 1
        var cap = CGLineCap.butt
        var join = CGLineJoin.miter
        var miter: CGFloat = 10
        var dashPhase: CGFloat = 0
        var dashes: [CGFloat] = []
        var alpha: CGFloat = 1
        var blend = CGBlendMode.normal
        /// In device space: an offset y up, and Core Graphics' blur.
        var shadow: (offset: CGSize, blur: CGFloat, color: CGColor)?
        var interpolation = CGInterpolationQuality.default
        /// Whether this state began a transparency layer, which ending it ends.
        var layer = false
    }
    private var state: State
    private var saved: [State] = []
    /// The current path, in device space.
    private var path = CGMutablePath()

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        state = State(clip: CGRect(x: 0, y: 0, width: width, height: height))
    }

    public convenience init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
                             space: CGColorSpace, bitmapInfo: UInt32) {
        guard width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
    }

    // MARK: Commands, as the page reads them

    enum Op: Double {
        case save = 1, restore, concat, clip, fill, stroke, linear, radial, image, layer, endLayer, text
    }

    private func put(_ op: Op) { commands.append(op.rawValue) }
    private func put(_ values: Double...) { commands.append(contentsOf: values) }
    private func put(_ r: CGRect) { commands.append(contentsOf: [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]) }
    private func put(_ c: CGColor) { commands.append(contentsOf: c.rgba) }

    private func putPath(_ p: CGPath) {
        var encoded: [Double] = []
        Skia.encode(p, into: &encoded)
        commands.append(Double(encoded.count))
        commands.append(contentsOf: encoded)
    }

    /// What every drawing is mixed by: alpha, blend mode and shadow, the shadow's offset in the
    /// page's device space (y down) and its blur as a standard deviation in pixels.
    private func putLook() {
        put(Double(state.alpha), Double(state.blend.rawValue))
        if let s = state.shadow {
            put(1, Double(s.offset.width), Double(-s.offset.height), Double(s.blur / 2))
            put(s.color)
        } else {
            put(0, 0, 0, 0, 0, 0, 0, 0)
        }
    }

    /// The current path in user space, ready to draw, and cleared.
    private func takePath() -> CGPath? {
        defer { path = CGMutablePath() }
        guard !path.isEmpty else { return nil }
        let back = state.ctm.inverted()
        return path.copy(using: [back])
    }

    // MARK: State

    public func saveGState() {
        saved.append(state)
        state.layer = false
        put(.save)
    }

    public func restoreGState() {
        guard let last = saved.popLast() else { return }
        if state.layer { endTransparencyLayer(); return restoreGState() }
        state = last
        put(.restore)
    }

    public var ctm: CGAffineTransform { state.ctm }
    public var userSpaceToDeviceSpaceTransform: CGAffineTransform { state.ctm }

    public func concatenate(_ t: CGAffineTransform) {
        state.ctm = t.concatenating(state.ctm)
        put(.concat)
        put(Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty))
    }
    public func translateBy(x: CGFloat, y: CGFloat) { concatenate(CGAffineTransform(translationX: x, y: y)) }
    public func scaleBy(x: CGFloat, y: CGFloat) { concatenate(CGAffineTransform(scaleX: x, y: y)) }
    public func rotate(by angle: CGFloat) { concatenate(CGAffineTransform(rotationAngle: angle)) }

    public func convertToDeviceSpace(_ p: CGPoint) -> CGPoint { p.applying(state.ctm) }
    public func convertToUserSpace(_ p: CGPoint) -> CGPoint { p.applying(state.ctm.inverted()) }
    public func convertToDeviceSpace(_ r: CGRect) -> CGRect { r.applying(state.ctm) }
    public func convertToUserSpace(_ r: CGRect) -> CGRect { r.applying(state.ctm.inverted()) }

    public func setFillColor(_ c: CGColor) { state.fill = c }
    public func setStrokeColor(_ c: CGColor) { state.stroke = c }
    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { state.fill = CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    public func setStrokeColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { state.stroke = CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    public func setFillColor(gray: CGFloat, alpha: CGFloat) { state.fill = CGColor(gray: gray, alpha: alpha) }
    public func setStrokeColor(gray: CGFloat, alpha: CGFloat) { state.stroke = CGColor(gray: gray, alpha: alpha) }
    public func setLineWidth(_ w: CGFloat) { state.lineWidth = w }
    public func setLineCap(_ c: CGLineCap) { state.cap = c }
    public func setLineJoin(_ j: CGLineJoin) { state.join = j }
    public func setMiterLimit(_ m: CGFloat) { state.miter = m }
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) { state.dashPhase = phase; state.dashes = lengths }
    public func setAlpha(_ a: CGFloat) { state.alpha = a }
    public func setBlendMode(_ m: CGBlendMode) { state.blend = m }
    public func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {
        state.shadow = color.map { (offset, blur, $0) }
        if let c = color, c.alpha == 0 { state.shadow = nil }
    }
    public func setShadow(offset: CGSize, blur: CGFloat) { setShadow(offset: offset, blur: blur, color: CGColor(gray: 0, alpha: 1.0 / 3.0)) }
    public func setShouldAntialias(_ on: Bool) {}
    public func setAllowsAntialiasing(_ on: Bool) {}
    public func setFlatness(_ f: CGFloat) {}
    public func setRenderingIntent(_ i: CGColorRenderingIntent) {}
    public var interpolationQuality: CGInterpolationQuality {
        get { state.interpolation }
        set { state.interpolation = newValue }
    }

    /// The clip's bounds in user space.
    public var boundingBoxOfClipPath: CGRect { state.clip.applying(state.ctm.inverted()) }

    // MARK: The path

    public func beginPath() { path = CGMutablePath() }
    public var isPathEmpty: Bool { path.isEmpty }
    public var currentPointOfPath: CGPoint { path.currentPoint.applying(state.ctm.inverted()) }
    public var boundingBoxOfPath: CGRect { path.boundingBoxOfPath.applying(state.ctm.inverted()) }
    public var path_: CGPath? { path.copy(using: [state.ctm.inverted()]) }

    public func addPath(_ p: CGPath) { path.addPath(p, transform: state.ctm) }
    public func addRect(_ r: CGRect) { path.addRect(r, transform: state.ctm) }
    public func addRects(_ rs: [CGRect]) { path.addRects(rs, transform: state.ctm) }
    public func addEllipse(in r: CGRect) { path.addEllipse(in: r, transform: state.ctm) }
    public func addLines(between ps: [CGPoint]) { path.addLines(between: ps, transform: state.ctm) }
    public func move(to p: CGPoint) { path.move(to: p, transform: state.ctm) }
    public func addLine(to p: CGPoint) { path.addLine(to: p, transform: state.ctm) }
    public func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) { path.addCurve(to: p, control1: control1, control2: control2, transform: state.ctm) }
    public func addQuadCurve(to p: CGPoint, control: CGPoint) { path.addQuadCurve(to: p, control: control, transform: state.ctm) }
    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise, transform: state.ctm)
    }
    public func addArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat) {
        path.addArc(tangent1End: tangent1End, tangent2End: tangent2End, radius: radius, transform: state.ctm)
    }
    public func closePath() { path.closeSubpath() }

    public func replacePathWithStrokedPath() {
        guard let user = takePath() else { return }
        var stroked = user.copy(strokingWithWidth: state.lineWidth, lineCap: state.cap, lineJoin: state.join, miterLimit: state.miter)
        if !state.dashes.isEmpty { stroked = user.copy(dashingWithPhase: state.dashPhase, lengths: state.dashes)
            .copy(strokingWithWidth: state.lineWidth, lineCap: state.cap, lineJoin: state.join, miterLimit: state.miter) }
        path.addPath(stroked, transform: state.ctm)
    }

    // MARK: Drawing

    public func fillPath(using rule: CGPathFillRule = .winding) {
        guard let p = takePath() else { return }
        put(.fill)
        putLook()
        put(Double(rule.rawValue))
        put(state.fill)
        putPath(p)
    }

    public func strokePath() {
        guard let p = takePath() else { return }
        put(.stroke)
        putLook()
        put(Double(state.lineWidth), Double(state.cap.rawValue), Double(state.join.rawValue), Double(state.miter), Double(state.dashPhase))
        put(Double(state.dashes.count))
        commands.append(contentsOf: state.dashes.map { Double($0) })
        put(state.stroke)
        putPath(p)
    }

    public func drawPath(using mode: CGPathDrawingMode) {
        let kept = path.copy() ?? CGPath()
        switch mode {
        case .fill: fillPath(using: .winding)
        case .eoFill: fillPath(using: .evenOdd)
        case .stroke: strokePath()
        case .fillStroke, .eoFillStroke:
            fillPath(using: mode == .eoFillStroke ? .evenOdd : .winding)
            path = kept.mutableCopy() ?? CGMutablePath()
            strokePath()
        }
    }

    public func fill(_ r: CGRect) { beginPath(); addRect(r); fillPath() }
    public func fill(_ rs: [CGRect]) { beginPath(); addRects(rs); fillPath() }
    public func fillEllipse(in r: CGRect) { beginPath(); addEllipse(in: r); fillPath() }
    public func stroke(_ r: CGRect) { beginPath(); addRect(r); strokePath() }
    public func stroke(_ r: CGRect, width: CGFloat) { saveGState(); setLineWidth(width); stroke(r); restoreGState() }
    public func strokeEllipse(in r: CGRect) { beginPath(); addEllipse(in: r); strokePath() }
    public func strokeLineSegments(between ps: [CGPoint]) {
        beginPath()
        var i = 0
        while i + 1 < ps.count { move(to: ps[i]); addLine(to: ps[i + 1]); i += 2 }
        strokePath()
    }
    public func clear(_ r: CGRect) {
        saveGState(); setBlendMode(.clear); fill(r); restoreGState()
    }

    public func clip(using rule: CGPathFillRule = .winding) {
        let device = path.boundingBoxOfPath
        guard let p = takePath() else { state.clip = .zero; put(.clip); put(0, 0); return }
        state.clip = state.clip.intersection(device)
        if state.clip.isNull { state.clip = .zero }
        put(.clip)
        put(Double(rule.rawValue))
        putPath(p)
    }
    public func clip(to r: CGRect) { beginPath(); addRect(r); clip() }
    public func clip(to rs: [CGRect]) { beginPath(); addRects(rs); clip() }
    /// Clipping to a mask is used only where a PDF is written; here it clips to the rectangle.
    public func clip(to r: CGRect, mask: CGImage) { clip(to: r) }

    public func drawLinearGradient(_ g: CGGradient, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        put(.linear)
        putLook()
        put(Double(start.x), Double(start.y), Double(end.x), Double(end.y))
        putStops(g, options)
    }

    public func drawRadialGradient(_ g: CGGradient, startCenter: CGPoint, startRadius: CGFloat, endCenter: CGPoint, endRadius: CGFloat,
                                   options: CGGradientDrawingOptions) {
        put(.radial)
        putLook()
        put(Double(startCenter.x), Double(startCenter.y), Double(startRadius), Double(endCenter.x), Double(endCenter.y), Double(endRadius))
        putStops(g, options)
    }

    private func putStops(_ g: CGGradient, _ options: CGGradientDrawingOptions) {
        put(options.contains(.drawsBeforeStartLocation) ? 1 : 0, options.contains(.drawsAfterEndLocation) ? 1 : 0)
        put(Double(g.colors.count))
        for (c, l) in zip(g.colors, g.locations) { put(Double(l)); put(c) }
    }

    /// Draws the picture into `r` as Core Graphics does: its top row at the rectangle's top in
    /// Core Graphics' space, which is y up.
    public func draw(_ image: CGImage, in r: CGRect, byTiling: Bool = false) {
        put(.image)
        putLook()
        put(Double(image.id))
        put(r)
        put(Double(state.interpolation.rawValue))
    }

    public func beginTransparencyLayer(in r: CGRect, auxiliaryInfo: CFDictionary?) { beginLayer(r) }
    public func beginTransparencyLayer(auxiliaryInfo: CFDictionary?) { beginLayer(nil) }

    private func beginLayer(_ r: CGRect?) {
        put(.layer)
        putLook()
        if let r { put(1); put(r) } else { put(0, 0, 0, 0, 0) }
        saved.append(state)
        // Inside, nothing is faded, mixed or shadowed: the layer is, as a whole, when it ends.
        state.alpha = 1
        state.blend = .normal
        state.shadow = nil
        state.layer = true
        if let r { state.clip = state.clip.intersection(r.applying(state.ctm)) }
    }

    public func endTransparencyLayer() {
        guard state.layer, let last = saved.popLast() else { return }
        state = last
        put(.endLayer)
    }

    /// Text laid out by the page, by its number there, its top left at `at`, y down.
    public func drawText(_ id: Int, at: CGPoint, color: CGColor?) {
        put(.text)
        putLook()
        put(Double(id), Double(at.x), Double(at.y))
        if let color { put(1); put(color) } else { put(0, 0, 0, 0, 0) }
    }

    /// What has been drawn so far, as a picture.
    public func makeImage() -> CGImage? {
        CGImage(width: width, height: height, source: .picture(commands))
    }

    public func flush() {}
    public func synchronize() {}
    public func beginPage(mediaBox: UnsafePointer<CGRect>?) {}
    public func endPage() {}
    public func closePDF() {}
}
