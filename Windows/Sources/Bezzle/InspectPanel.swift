import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// The inspector while the design is inspected, as the Mac's InspectInspector: for what is picked,
/// where it lies (each step a click away), its box inside the one round it, its type, its looks and
/// its code in CSS or SwiftUI; with nothing picked, the design's colours. Every value copies with a
/// click, and nothing here changes the design.
extension Inspector {
    func showInspect() {
        let ids = session.selection
        if ids.count == 1, let spec = WindowsCore.inspectSpec(ids[0], platform: inspectPlatform) {
            cards.children.append(layerPath(spec))
            cards.children.append(boxCard(spec))
            if spec.isText { cards.children.append(typeCard(spec)) }
            if !spec.looks.isEmpty { cards.children.append(specCard(spec.looks)) }
            cards.children.append(codeCard(ids[0]))
            cards.children.append(assetCard(ids[0]))
        } else {
            let palette = WindowsCore.inspectPalette(platform: inspectPlatform)
            if !palette.isEmpty {
                let stack = StackPanel()
                stack.spacing = 4
                stack.children.append(Theme.text(Words.t("Colours"), size: 12.5, weight: 600))
                for line in palette { stack.children.append(specLine(line)) }
                cards.children.append(specBox(stack))
            }
            let samples = WindowsCore.typeSamples(platform: inspectPlatform)
            if !samples.isEmpty { cards.children.append(typeSamplesCard(samples)) }
            cards.children.append(handOffCard(showsInspect: false))
            let marked = WindowsCore.markedAssets()
            if !marked.isEmpty { cards.children.append(markedAssetsCard(marked)) }
            cards.children.append(Controls.caption("Pick a layer to read its size, where it lies and its looks, and to copy any of them, or its code."))
        }
    }

    /// A card's frame round what it holds.
    private func specBox(_ child: UIElement) -> FrameworkElement {
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.padding = Theme.inset(12, 10, 12, 10)
        card.child = child
        return card
    }

    /// A value as it reads, copied with a click: it lights up while pointed at and ticks once copied.
    func copyValue(_ shown: String, copy: String, size: Double = 12, weight: UInt16 = 500, ink: SolidColorBrush? = nil) -> FrameworkElement {
        let box = Border()
        box.cornerRadius = Theme.corners(5)
        box.padding = Theme.inset(4, 1, 4, 1)
        box.background = Theme.clear
        let text = Theme.text(shown, size: size, weight: weight)
        if let ink { text.foreground = ink }
        text.textTrimming = .characterEllipsis
        box.child = text
        box.pointerEntered.addHandler { _, _ in box.background = Theme.brush(Theme.pencil, Theme.pencilWash) }
        box.pointerExited.addHandler { _, _ in box.background = Theme.clear }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.pointerReleased.addHandler { _, _ in
            Clipboard.copyText(copy)
            text.text = "✓ " + Words.t("Copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { MainActor.assumeIsolated { text.text = shown } }
        }
        try? ToolTipService.setToolTip(box, copy)
        return box
    }

    /// A line of a spec: its label, a colour beside the value, the value, the name the design gives
    /// it and a word after.
    private func specLine(_ line: WindowsCore.SpecLine) -> FrameworkElement {
        let row = Grid()
        row.minHeight = 22
        let label = Theme.text(line.label, size: 11.5, ink: 3)
        label.verticalAlignment = .center
        label.horizontalAlignment = .left
        label.textTrimming = .characterEllipsis
        label.maxWidth = 92
        row.children.append(label)
        let values = StackPanel()
        values.orientation = .horizontal
        values.spacing = 5
        values.margin = Theme.inset(line.label.isEmpty ? 0 : 96, 0, 0, 0)
        values.verticalAlignment = .center
        values.horizontalAlignment = .left
        if let swatch = line.swatch {
            let chip = Border()
            chip.width = 14
            chip.height = 14
            chip.cornerRadius = Theme.corners(4)
            chip.background = Theme.brush(swatch.hex, swatch.alpha)
            chip.borderBrush = Theme.hairline
            chip.borderThickness = Theme.inset(0.5)
            chip.verticalAlignment = .center
            values.children.append(chip)
        }
        values.children.append(copyValue(line.value, copy: line.copy))
        if let note = line.note {
            let n = Theme.text(note, size: 11.5, ink: 3)
            n.verticalAlignment = .center
            values.children.append(n)
        }
        if let token = line.token {
            let tag = Border()
            tag.cornerRadius = Theme.corners(5)
            tag.background = Theme.brush(0x7C4DDB, 0.1)
            tag.padding = Theme.inset(5, 1, 5, 1)
            let t = Theme.text(token, size: 10.5, weight: 500)
            t.foreground = Theme.brush(0x7C4DDB)
            t.textTrimming = .characterEllipsis
            t.maxWidth = 120
            tag.child = t
            tag.verticalAlignment = .center
            values.children.append(tag)
        }
        row.children.append(values)
        return row
    }

    private func specCard(_ lines: [WindowsCore.SpecLine]) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 4
        for line in lines { stack.children.append(specLine(line)) }
        return specBox(stack)
    }

    /// Where the layer lies, from its screen down, each step picked with a click, and the
    /// component copy it is part of.
    private func layerPath(_ spec: WindowsCore.InspectSpec) -> FrameworkElement {
        let wrap = StackPanel()
        wrap.spacing = 4
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 3
        for (k, step) in spec.path.enumerated() {
            if k > 0 { line.children.append(Theme.text("›", size: 11.5, ink: 3)) }
            let last = k == spec.path.count - 1
            let crumb = Theme.text(step.name, size: 11.5, weight: last ? 600 : 400, ink: last ? 1 : 2)
            crumb.textTrimming = .characterEllipsis
            crumb.maxWidth = last ? 160 : 80
            if !last {
                let id = step.id
                crumb.tapped.addHandler { [weak self] _, _ in
                    guard let self else { return }
                    self.session.select([id], on: WindowsCore.board(of: id) ?? WindowsCore.boardIndex(of: id))
                    self.session.edited(board: nil)
                }
            }
            line.children.append(crumb)
        }
        wrap.children.append(line)
        if let component = spec.component {
            let chip = Theme.text("◆ " + component, size: 11, weight: 500)
            chip.foreground = Theme.brush(0x7C4DDB)
            wrap.children.append(chip)
        }
        wrap.margin = Theme.inset(4, 0, 0, 0)
        return wrap
    }

    /// The layer's box inside the one round it, as a browser's tools draw it: the layer in pencil
    /// with its size, and the room on each side in the canvas's pink; then where it lies on its screen.
    private func boxCard(_ spec: WindowsCore.InspectSpec) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 10
        let w = Theme.cardWidth - 24, pink: UInt32 = 0xE0457B
        let model = Grid()
        model.width = w
        model.height = spec.insets == nil ? 56 : 136
        let h = model.height
        let inner = spec.insets == nil ? CGRect(x: 0, y: 0, width: w, height: h) : CGRect(x: w / 2 - 58, y: h / 2 - 22, width: 116, height: 44)
        let canvas = Canvas()
        model.children.append(canvas)
        func place(_ e: FrameworkElement, x: Double, y: Double) {
            try? e.measure(Size(width: 300, height: 100))
            try? Canvas.setLeft(e, x - Double(e.desiredSize.width) / 2)
            try? Canvas.setTop(e, y - Double(e.desiredSize.height) / 2)
            canvas.children.append(e)
        }
        if let insets = spec.insets {
            let outer = Rectangle()
            outer.width = w
            outer.height = h
            outer.radiusX = 9
            outer.radiusY = 9
            outer.stroke = Theme.ink(4)
            outer.strokeThickness = 1
            let dashes = DoubleCollection()
            dashes.append(3)
            dashes.append(2.5)
            outer.strokeDashArray = dashes
            canvas.children.append(outer)
            if let name = spec.parent {
                let n = Theme.text(name, size: 10.5, weight: 500, ink: 3)
                n.maxWidth = w / 2 - 20
                n.textTrimming = .characterEllipsis
                try? Canvas.setLeft(n, 9)
                try? Canvas.setTop(n, 6)
                canvas.children.append(n)
            }
            var d = PathData()
            let lines: [((Double, Double), (Double, Double))] = [
                ((inner.midX, 0), (inner.midX, inner.minY)), ((inner.midX, inner.maxY), (inner.midX, h)),
                ((0, inner.midY), (inner.minX, inner.midY)), ((inner.maxX, inner.midY), (w, inner.midY)),
            ]
            for (a, b) in lines {
                d.move(a.0, a.1)
                d.line(b.0, b.1)
                let across = a.1 == b.1
                for end in [a, b] {
                    if across { d.move(end.0, end.1 - 3); d.line(end.0, end.1 + 3) } else { d.move(end.0 - 3, end.1); d.line(end.0 + 3, end.1) }
                }
            }
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='1'/>"
            if let p = (try? XamlReader.load(xaml)) as? WinUI.Path {
                p.stroke = Theme.brush(pink, 0.7)
                canvas.children.append(p)
            }
            func side(_ v: Double) -> FrameworkElement {
                let shown = InspectHandNumber(v)
                let box = copyValue(shown, copy: shown, size: 11.5, weight: 600, ink: Theme.brush(v < -0.05 ? Theme.warning : pink))
                (box as? Border)?.background = Theme.brush(Theme.card)
                return box
            }
            place(side(insets[0]), x: inner.midX, y: inner.minY / 2)
            place(side(insets[2]), x: inner.midX, y: (inner.maxY + h) / 2)
            place(side(insets[3]), x: inner.minX / 2, y: inner.midY)
            place(side(insets[1]), x: (inner.maxX + w) / 2, y: inner.midY)
        }
        let layer = Rectangle()
        layer.width = inner.width
        layer.height = inner.height
        layer.radiusX = 6
        layer.radiusY = 6
        layer.fill = Theme.brush(Theme.pencil, Theme.pencilWash)
        layer.stroke = Theme.brush(Theme.pencil)
        layer.strokeThickness = 1.2
        try? Canvas.setLeft(layer, inner.minX)
        try? Canvas.setTop(layer, inner.minY)
        canvas.children.append(layer)
        let size = StackPanel()
        size.orientation = .horizontal
        let ww = InspectHandNumber(Double(spec.size.width)), hh = InspectHandNumber(Double(spec.size.height))
        size.children.append(copyValue(ww, copy: ww, size: 12.5, weight: 600, ink: Theme.brush(Theme.pencil)))
        let times = Theme.text("×", size: 11)
        times.foreground = Theme.brush(Theme.pencil, 0.7)
        times.verticalAlignment = .center
        size.children.append(times)
        size.children.append(copyValue(hh, copy: hh, size: 12.5, weight: 600, ink: Theme.brush(Theme.pencil)))
        place(size, x: inner.midX, y: inner.midY)
        stack.children.append(model)
        if let x = spec.x, let y = spec.y {
            let line = StackPanel()
            line.orientation = .horizontal
            line.spacing = 10
            for (label, v) in [("X", x), ("Y", y)] {
                let pair = StackPanel()
                pair.orientation = .horizontal
                pair.spacing = 2
                let l = Theme.text(label, size: 11.5, ink: 3)
                l.verticalAlignment = .center
                pair.children.append(l)
                let shown = InspectHandNumber(v)
                pair.children.append(copyValue(shown, copy: shown))
                line.children.append(pair)
            }
            if let r = spec.rotation {
                let shown = InspectHandNumber(r)
                line.children.append(copyValue("↻ \(shown)°", copy: shown))
            }
            stack.children.append(line)
        }
        return specBox(stack)
    }

    /// The type the words are set in: its family and face, every measure of it, and the words.
    private func typeCard(_ spec: WindowsCore.InspectSpec) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 4
        if let font = spec.font {
            let head = StackPanel()
            head.spacing = 1
            head.margin = Theme.inset(0, 0, 0, 4)
            head.children.append(copyValue(font.family, copy: font.copyFamily, size: 12.5, weight: 600))
            head.children.append(copyValue(font.face, copy: font.copyWeight, size: 12, weight: 400, ink: Theme.ink(2)))
            stack.children.append(head)
        }
        for line in spec.type { stack.children.append(specLine(line)) }
        if let words = spec.words, !words.isEmpty {
            let block = Border()
            block.cornerRadius = Theme.corners(8)
            block.background = Theme.brush(Theme.ink, 0.04)
            block.padding = Theme.inset(8, 6, 8, 6)
            block.margin = Theme.inset(0, 6, 0, 0)
            let t = Theme.text(words, size: 12, ink: 2)
            t.textWrapping = .wrap
            t.maxLines = 6
            t.textTrimming = .characterEllipsis
            block.child = t
            block.pointerPressed.addHandler { _, args in args?.handled = true }
            block.pointerReleased.addHandler { _, _ in Clipboard.copyText(words) }
            try? ToolTipService.setToolTip(block, Words.t("Copy Text"))
            stack.children.append(block)
        }
        return specBox(stack)
    }

    /// The layer as code, in CSS or SwiftUI, its looks by the names the design gives them, copied whole.
    private func codeCard(_ id: UUID) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 8
        let head = Grid()
        let switcher = Controls.segmented(inspectPlatform, [(.css, "CSS"), (.swiftui, "SwiftUI")], width: 150) { [weak self] p in
            self?.inspectPlatform = p
            self?.show()
        }
        switcher.horizontalAlignment = .left
        head.children.append(switcher)
        let code = WindowsCore.inspectCode(id, platform: inspectPlatform)
        let copy = copyValue("⧉ " + Words.t("Copy"), copy: code, size: 12, weight: 500, ink: Theme.brush(Theme.pencil))
        copy.horizontalAlignment = .right
        copy.verticalAlignment = .center
        head.children.append(copy)
        stack.children.append(head)
        let block = Border()
        block.cornerRadius = Theme.corners(8)
        block.background = Theme.brush(Theme.ink, 0.04)
        block.padding = Theme.inset(10, 8, 10, 8)
        let text = TextBlock()
        text.text = code
        text.fontFamily = FontFamily("Consolas")
        text.fontSize = 11
        text.foreground = Theme.ink(1)
        text.textWrapping = .wrap
        text.isTextSelectionEnabled = true
        block.child = text
        stack.children.append(block)
        return specBox(stack)
    }
}

extension Inspector {
    // MARK: Taking a layer away

    /// The layer to take away as a file: its picture, dragged out to Explorer or into code, in
    /// the format and size chosen, or copied, as the Mac's AssetCard.
    fileprivate func assetCard(_ id: UUID) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 10
        let picture = isPicture(assetFormat)
        stack.children.append(dragPicture(id, format: assetFormat, scale: picture ? assetScale : 1))
        let chips = Grid()
        let formats = StackPanel()
        formats.orientation = .horizontal
        formats.spacing = 3
        for f in WindowsCore.assetFormats {
            formats.children.append(chip(f.title, on: assetFormat == f.key) { [weak self] in
                self?.assetFormat = f.key
                self?.show()
            })
        }
        chips.children.append(formats)
        if picture {
            let scales = StackPanel()
            scales.orientation = .horizontal
            scales.spacing = 3
            scales.horizontalAlignment = .right
            for s in [1.0, 2.0, 3.0] {
                scales.children.append(chip("\(Int(s))×", on: assetScale == s) { [weak self] in
                    self?.assetScale = s
                    self?.show()
                })
            }
            chips.children.append(scales)
        }
        stack.children.append(chips)
        let copy = Theme.card(radius: 8)
        copy.height = 28
        let label = Theme.text(Words.t("Copy"), size: 12.5, weight: 500)
        label.horizontalAlignment = .center
        copy.child = label
        let format = assetFormat, scale = picture ? assetScale : 1
        copy.pointerPressed.addHandler { _, args in args?.handled = true }
        copy.tapped.addHandler { _, _ in
            guard let url = WindowsCore.assetFile(id, format: format, scale: scale) else { return }
            Clipboard.copyFile(url, png: format == "png" ? WindowsCore.assetPixels(id, scale: scale) : nil)
            label.text = "✓ " + Words.t("Copied")
            label.foreground = Theme.brush(Theme.pencil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                MainActor.assumeIsolated {
                    label.text = Words.t("Copy")
                    label.foreground = Theme.ink(1)
                }
            }
        }
        stack.children.append(copy)
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.padding = Theme.inset(12)
        card.child = stack
        return card
    }

    private func isPicture(_ format: String) -> Bool { format != "pdf" && format != "svg" }

    /// A small choice, as the Mac's Chip: pencil while chosen.
    private func chip(_ title: String, on: Bool, _ action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let box = Border()
        box.height = 22
        box.cornerRadius = Theme.corners(6)
        box.padding = Theme.inset(6, 0, 6, 0)
        box.background = on ? Theme.brush(Theme.pencil, Theme.pencilWash) : Theme.brush(Theme.ink, 0.03)
        box.borderBrush = on ? Theme.brush(Theme.pencil, 0.5) : Theme.clear
        box.borderThickness = Theme.inset(1)
        let text = Theme.text(title, size: 11, weight: on ? 600 : 500, ink: on ? 1 : 2)
        if on { text.foreground = Theme.brush(Theme.pencil) }
        box.child = text
        box.pointerEntered.addHandler { _, _ in if !on { box.background = Theme.brush(Theme.ink, 0.06) } }
        box.pointerExited.addHandler { _, _ in if !on { box.background = Theme.brush(Theme.ink, 0.03) } }
        box.pointerPressed.addHandler { _, args in args?.handled = true }
        box.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { action() } } }
        return box
    }

    /// A layer's picture on a checkerboard, lifted a little while pointed at, to drag out as a file.
    fileprivate func dragPicture(_ id: UUID, format: String, scale: Double, width: Double = Theme.cardWidth - 24, height: Double = 124) -> FrameworkElement {
        let holder = Grid()
        holder.width = width
        holder.height = height
        holder.cornerRadius = Theme.corners(8)
        holder.borderBrush = Theme.hairline
        holder.borderThickness = Theme.inset(0.5)
        let light = WindowsCore.assetIsLight(id)
        holder.children.append(Self.checker(width: width, height: height, dark: light))
        let picture = Image()
        picture.stretch = .fill
        var bitmap: WriteableBitmap?
        let made = WindowsCore.assetPicture(id, fitting: CGSize(width: width - 24, height: height - 24)) { w, h in
            bitmap = WriteableBitmap(Int32(w), Int32(h))
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        let lift = CompositeTransform()
        if let made, let b = bitmap {
            try? b.invalidate()
            picture.source = b
            // At its own size, or smaller to fit.
            let w = Double(b.pixelWidth) / made, h = Double(b.pixelHeight) / made
            let k = min((width - 24) / max(w, 1), (height - 24) / max(h, 1), 1)
            picture.width = w * k
            picture.height = h * k
            picture.horizontalAlignment = .center
            picture.verticalAlignment = .center
            picture.renderTransform = lift
            lift.centerX = w * k / 2
            lift.centerY = h * k / 2
            holder.children.append(picture)
        }
        // A file's corner, where it is taken hold of.
        let file = Glyphs.view(Glyphs.fileDown(size: 16), size: 16, brush: Theme.ink(3))
        file.horizontalAlignment = .right
        file.verticalAlignment = .bottom
        file.margin = Theme.inset(0, 0, 6, 6)
        file.opacity = 0
        holder.children.append(file)
        holder.background = Theme.clear
        holder.pointerEntered.addHandler { _, _ in
            lift.translateY = -2
            lift.scaleX = 1.03
            lift.scaleY = 1.03
            file.opacity = 1
        }
        holder.pointerExited.addHandler { _, _ in
            lift.translateY = 0
            lift.scaleX = 1
            lift.scaleY = 1
            file.opacity = 0
        }
        // Dragged out of the window: the layer written as a file of its own the moment the drag
        // begins, named as an export names it, and carried to Explorer or into another app as
        // that file, as the Mac's DragPicture does (InspectCopy.dragged).
        // Begun by hand once the pointer has moved a little while pressed: the press is kept
        // from the panel, which would otherwise take it, and with it WinUI's own drag.
        var pressedAt: WindowsFoundation.Point?
        holder.pointerPressed.addHandler { _, args in
            args?.handled = true
            pressedAt = try? args?.getCurrentPoint(holder)?.position
        }
        holder.pointerReleased.addHandler { _, _ in pressedAt = nil }
        holder.pointerMoved.addHandler { _, args in
            guard let from = pressedAt, let args, let point = try? args.getCurrentPoint(holder) else { return }
            guard point.properties?.isLeftButtonPressed == true else {
                Trace.say("inspect drag: moved without the button")
                pressedAt = nil
                return
            }
            let at = point.position
            guard abs(Double(at.x - from.x)) > 4 || abs(Double(at.y - from.y)) > 4 else { return }
            pressedAt = nil
            do {
                _ = try holder.startDragAsync(point)
            } catch {
                Trace.say("inspect drag: not begun, \(error)")
            }
        }
        holder.dragStarting.addHandler { _, args in
            Trace.say("inspect drag: starting")
            guard let args else { return }
            Self.dragOut(id, format: format, scale: scale, args)
        }
        try? ToolTipService.setToolTip(holder, WindowsCore.formatTitle(format) + (isPicture(format) ? " @\(Int(scale))x" : ""))
        return holder
    }

    /// A layer's file, made now, given to the drag that has begun: as a file Explorer, a mail or
    /// a chat takes in, copied, never moved.
    private static func dragOut(_ id: UUID, format: String, scale: Double, _ args: DragStartingEventArgs) {
        guard let url = WindowsCore.assetFile(id, format: format, scale: scale), let data = args.data else {
            args.cancel = true
            return
        }
        args.allowedOperations = .copy
        data.requestedOperation = .copy
        let path = (url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path).replacingOccurrences(of: "/", with: "\\")
        // Windows hands the file over once it is found, which takes a moment: the drag waits.
        let deferral = try? args.getDeferral()
        Task { @MainActor in
            defer { try? deferral?.complete() }
            guard let file = try? await StorageFile.getFileFromPathAsync(path)?.get() else {
                Trace.say("inspect drag: no file at \(path)")
                return
            }
            let items: [AnyIStorageItem?] = [file]
            try? data.setStorageItems(items.toVector())
            Trace.say("inspect drag: carrying \(path)")
        }
    }

    /// A checkerboard of squares 6 across, light, or dark for what is light.
    private static func checker(width: Double, height: Double, dark: Bool) -> Image {
        let image = Image()
        image.width = width
        image.height = height
        image.stretch = .fill
        image.isHitTestVisible = false
        let w = Int(width.rounded()), h = Int(height.rounded())
        guard w > 0, h > 0 else { return image }
        let bitmap = WriteableBitmap(Int32(w), Int32(h))
        if let p = (try? bitmap.pixelBuffer.buffer).flatMap({ $0 }) {
            let px = UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt32.self)
            // Light: the card, and half-strength squares of ink; dark: greys of a fifth and a quarter.
            let a: UInt32, b: UInt32
            if dark {
                a = 0xFF33_3333; b = 0xFF40_4040
            } else {
                let base = Theme.card, ink = Theme.ink
                func mix(_ c: UInt32, _ d: UInt32, _ t: Double) -> UInt32 {
                    var out: UInt32 = 0xFF00_0000
                    for shift in [16, 8, 0] as [UInt32] {
                        let x = Double((c >> shift) & 255), y = Double((d >> shift) & 255)
                        out |= UInt32((x + (y - x) * t).rounded()) << shift
                    }
                    return out
                }
                a = mix(base, ink, 0); b = mix(base, ink, 0.04)
            }
            for y in 0..<h { for x in 0..<w { px[y * w + x] = ((x / 6 + y / 6) % 2 == 1) ? b : a } }
        }
        try? bitmap.invalidate()
        image.source = bitmap
        return image
    }

    // MARK: Nothing picked

    /// The type the design is set in, each in itself: those it names first, by their names,
    /// then the others it uses most; a click copies one as code.
    fileprivate func typeSamplesCard(_ samples: [WindowsCore.TypeSample]) -> FrameworkElement {
        let stack = StackPanel()
        for (i, s) in samples.enumerated() {
            if i > 0 {
                let rule = Border()
                rule.height = 0.5
                rule.background = Theme.hairline
                stack.children.append(rule)
            }
            let row = Grid()
            row.padding = Theme.inset(12, 9, 12, 9)
            row.background = Theme.clear
            let words = StackPanel()
            words.spacing = 2
            let title = Theme.text(s.title, size: s.size)
            if let font = Self.font(of: s.family) { title.fontFamily = font }
            title.fontWeight = FontWeight(weight: UInt16(s.weight))
            if s.italic { title.fontStyle = .italic }
            words.children.append(title)
            words.children.append(Theme.text(s.detail, size: 10.5, ink: 3))
            row.children.append(words)
            let tick = Theme.text("✓", size: 11, weight: 600)
            tick.foreground = Theme.brush(Theme.pencil)
            tick.horizontalAlignment = .right
            tick.opacity = 0
            row.children.append(tick)
            row.pointerEntered.addHandler { _, _ in row.background = Theme.brush(Theme.pencil, Theme.pencilWash) }
            row.pointerExited.addHandler { _, _ in row.background = Theme.clear }
            let copy = s.copy
            row.tapped.addHandler { _, _ in
                Clipboard.copyText(copy)
                tick.opacity = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { tick.opacity = 0 } }
            }
            try? ToolTipService.setToolTip(row, copy)
            stack.children.append(row)
        }
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.child = stack
        return card
    }

    /// What the design marks for export, each to drag out as its first mark makes it, and all of
    /// it exported at once.
    fileprivate func markedAssetsCard(_ marked: [(id: UUID, name: String, format: String, scale: Double)]) -> FrameworkElement {
        let stack = StackPanel()
        stack.spacing = 10
        let tileWidth = (Theme.cardWidth - 24 - 16) / 3
        var row: StackPanel?
        let rows = StackPanel()
        rows.spacing = 10
        for (k, m) in marked.enumerated() {
            if k % 3 == 0 {
                let r = StackPanel()
                r.orientation = .horizontal
                r.spacing = 8
                rows.children.append(r)
                row = r
            }
            let tile = StackPanel()
            tile.spacing = 4
            tile.width = tileWidth
            tile.children.append(dragPicture(m.id, format: m.format, scale: m.scale, width: tileWidth, height: 64))
            let name = Theme.text(m.name, size: 10, ink: 2)
            name.textTrimming = .characterEllipsis
            name.horizontalAlignment = .center
            tile.children.append(name)
            let id = m.id
            tile.tapped.addHandler { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.session.select([id], on: WindowsCore.board(of: id) ?? WindowsCore.boardIndex(of: id))
                    }
                }
            }
            row?.children.append(tile)
        }
        stack.children.append(rows)
        stack.children.append(Controls.cardButton(Words.t("Export…"), height: 28) { [weak self] in self?.session.openExport?() })
        let card = Theme.card(radius: 12)
        card.width = Theme.cardWidth
        card.padding = Theme.inset(12)
        card.child = stack
        return card
    }
}

extension Glyphs {
    /// A page with its corner folded and an arrow down into it: a file to take.
    static func fileDown(size s: Double = 16) -> [Part] {
        var page = PathData(), arrow = PathData()
        page.move(s * 0.3, s * 0.14); page.line(s * 0.58, s * 0.14); page.line(s * 0.74, s * 0.3); page.line(s * 0.74, s * 0.86)
        page.line(s * 0.3, s * 0.86); page.close()
        arrow.move(s * 0.52, s * 0.38); arrow.line(s * 0.52, s * 0.7)
        arrow.move(s * 0.42, s * 0.6); arrow.line(s * 0.52, s * 0.7); arrow.line(s * 0.62, s * 0.6)
        return [Part(data: page.d, mode: .stroke, width: 1.2), Part(data: arrow.d, mode: .stroke, width: 1.2)]
    }
}

/// A distance as the canvas writes it: whole, or to a tenth.
@MainActor private func InspectHandNumber(_ v: Double) -> String { WindowsCore.InspectHand.number(BezzleCore.CGFloat(v)) }
