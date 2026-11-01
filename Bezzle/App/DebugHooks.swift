#if DEBUG
import AppKit
import SwiftUI

/// Lets a test run drive the app and photograph its own window, since this Mac's test sessions
/// cannot take screenshots. All through environment variables:
///   BEZZLE_LIBRARY=folder          where designs are kept (always set for test runs)
///   BEZZLE_DEMO=1                  make a sample design in the library and open it
///   BEZZLE_WELCOME=1               make the welcome tour in the library and open it, as a first launch does
///   BEZZLE_OPEN=path               open this design
///   BEZZLE_SELECT=name,name…       select the layers with these names
///   BEZZLE_TOOL=rectangle          pick a tool
///   BEZZLE_RESOURCES=seconds[:page[:words]]  bring out the resources panel, on a kit's or icon set's page
///   BEZZLE_RESOURCE_DRAG=seconds:resource:x,y;…  carry a part or icon over the canvas and hold it there
///   BEZZLE_CARD=seconds:layout     open this card of the inspector (layout, guides)
///   BEZZLE_EDIT=name[:start,length]  start typing into this text layer, those letters picked out
///   BEZZLE_FIND=seconds:words      open the find bar looking for these words, or "spelling" to check spelling
///   BEZZLE_MENU=seconds:anchor     open one of Bezzle's menus or panels (fill, border, zoom…)
///   BEZZLE_EXPORT=seconds          show the export panel
///   BEZZLE_EXPORT_FILES=seconds:folder:png,svg…  export the selected layers, or every artboard, and quit
///   BEZZLE_KEYS=seconds:code,…     press these keys (by key code) on the canvas, a tenth of a second apart
///   BEZZLE_RIGHTCLICK=seconds:name right-click the middle of this layer
///   BEZZLE_POINT=seconds:name[:dx,dy]  move the pointer to the middle of this layer, give or take
///   BEZZLE_PREVIEW=seconds:preset  show a preset on the canvas as pointing at it would (shadow-floating…)
///   BEZZLE_ZOOM=0.5                zoom, about the middle of the view
///   BEZZLE_LOOK=name:zoom[:dx,dy]  look at this layer (its top, for a tall one) at this zoom
///   BEZZLE_ZOOMS=seconds:z,z,…     zoom to each in turn, about the middle, as a pinch does
///   BEZZLE_APPEARANCE=light|dark   force an appearance
///   BEZZLE_WINDOW=WxH              window size
///   BEZZLE_SNAPSHOTS=seconds:path.png,…   save the window as PNG; quits after the last one
///   BEZZLE_STRESS=seconds:out.txt   pan, hover, select and nudge for a while, then write how long
///                                  the app was busy each time, and quit
///   BEZZLE_XDCHECK=xd-folder:out-folder  import every XD file and compare with XD's own previews (see XDCheck)
///   BEZZLE_ICLOUD_SCHEMA=out.txt   teach iCloud's development environment every record type sharing uses,
///                                  so they can be deployed to production; write how it went, and quit
///   BEZZLE_ARRIVING=name[:owner]   show a shared design on its way on the home screen, as an invitation does
///   BEZZLE_INVITATION_PROBLEM=text show an invitation that could not be opened
///   BEZZLE_SHARE_SHEET=seconds     open the share sheet in the design's window, as Share… does, for a plain link
///   BEZZLE_SNAPSHOT_LAYERS=1       take them through the layer tree instead of the views' drawing
///   BEZZLE_DUMP_VIEWS=1            next to each, the canvas's views and their frames in the window
///   BEZZLE_HITTEST=name,…          and with it, which view a click in the middle of these layers reaches
///   BEZZLE_CLICKS=seconds:step;…   use the pointer on the canvas, a few tenths of a second a step, at canvas
///                                  points: "x,y" clicks, "x,y>x,y" drags, "~x,y" only moves there,
///                                  "!x,y" is the second click of a double click, "+x,y>x,y" drags and keeps
///                                  the button down
enum DebugHooks {
    private static var ran = false
    private static let env = ProcessInfo.processInfo.environment

    /// Once per launch, from the home window.
    static func runOnce() {
        guard !ran else { return }
        ran = true
        if let spec = env["BEZZLE_XDCHECK"] {
            after(0.3) { XDCheck.run(spec) }
            return
        }
        if let out = env["BEZZLE_ICLOUD_SCHEMA"] {
            Task {
                let report: String
                do { report = try await CloudSync.shared.teachSchema() } catch { report = "failed: \(error)" }
                try? report.write(toFile: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if let look = env["BEZZLE_APPEARANCE"] { NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) }
        if let spec = env["BEZZLE_ARRIVING"] {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            CloudSync.shared.pretendArriving(parts[0], from: parts.count > 1 ? parts[1] : nil)
        }
        if let problem = env["BEZZLE_INVITATION_PROBLEM"] { CloudSync.shared.invitationProblem = problem }
        if env["BEZZLE_WELCOME"] != nil, let url = Welcome.make() {
            WindowRouter.shared.open(url)
        } else if env["BEZZLE_DEMO"] != nil, let url = makeDemo() {
            WindowRouter.shared.open(url)
        } else if let path = env["BEZZLE_OPEN"] {
            WindowRouter.shared.open(URL(fileURLWithPath: path))
        }
        sizeWindow()
        scheduleSnapshots()
    }

    /// When a design window opens.
    static func attach(_ store: DocumentStore) {
        if let s = env["BEZZLE_SHARE_SHEET"].flatMap(Double.init) {
            after(s) { CloudSync.shared.presentSheet([URL(string: "https://www.apple.com")!], for: store, at: nil) }
        }
        if let names = env["BEZZLE_SELECT"] {
            let wanted = names.split(separator: ",").map(String.init)
            after(0.6) { store.selection = store.doc.allNodes.filter { wanted.contains($0.name) }.map(\.id) }
        }
        if let tool = env["BEZZLE_TOOL"].flatMap(Tool.init(rawValue:)) { after(0.6) { store.tool = tool } }
        // BEZZLE_RESOURCES=seconds[:page[:words]] brings out the resources panel, on a kit's or an
        // icon set's page ("ios", "lucide"…), with words in its search.
        if let spec = env["BEZZLE_RESOURCES"] {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let page: ResourcePage? = parts.count > 1 && !parts[1].isEmpty ? (IconSetID(rawValue: parts[1]).map { .icons($0) } ?? .kit(parts[1])) : nil
            ResourcesPanel.opening = (page, parts.count > 2 ? parts[2] : "")
            after(Double(parts[0]) ?? 0.6) { store.showsResources = true }
        }
        // BEZZLE_RESOURCE_DRAG=seconds:resource:x,y[;x,y…] carries a part ("ios.tab-bar") or an icon
        // ("icon/lucide/heart") over these canvas points, a third of a second apart, and holds it at the last.
        if let spec = env["BEZZLE_RESOURCE_DRAG"] {
            let parts = spec.split(separator: ":").map(String.init)
            if parts.count == 3, let s = Double(parts[0]), let resource = try? MCPTools.resource(parts[1], style: nil, weight: nil) {
                let points = parts[2].split(separator: ";").compactMap { p -> CGPoint? in
                    let v = p.split(separator: ",").compactMap { Double($0) }
                    return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
                }
                after(s) { store.canvas?.resourceDropTool.begin(resource) }
                for (i, p) in points.enumerated() {
                    after(s + 0.05 + Double(i) / 3) { _ = store.canvas?.resourceDropTool.update(at: p, on: nil) }
                }
            }
        }
        // BEZZLE_CARD=seconds:layout|guides|photo opens that card of the inspector.
        if let spec = env["BEZZLE_CARD"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let card: Aspect? = switch spec[spec.index(after: colon)...] {
            case "layout": .layout
            case "guides": .guides
            case "photo", "photo-color", "photo-detail": .photo
            case "fill": .fill(0)
            case "text": .text
            case "path": .path
            default: nil
            }
            after(s) {
                store.openAspect = card
                if spec.hasSuffix("photo-color") { store.developGroup = .color; store.developBand = .green }
                if spec.hasSuffix("photo-detail") { store.developGroup = .detail }
            }
        }
        if let z = env["BEZZLE_ZOOM"].flatMap(Double.init) { after(0.7) { store.zoom(to: z) } }
        if let spec = env["BEZZLE_ZOOMS"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            // As a pinch does: one zoom after another, a frame or two apart.
            for (i, z) in spec[spec.index(after: colon)...].split(separator: ",").compactMap({ Double($0) }).enumerated() {
                after(s + Double(i) * 0.03) { store.zoom(to: z) }
            }
        }
        if let spec = env["BEZZLE_LOOK"] {
            let parts = spec.split(separator: ":").map(String.init)
            if parts.count >= 2, let zoom = Double(parts[1]) {
                let offset = parts.count > 2 ? parts[2].split(separator: ",").compactMap { Double($0) } : []
                after(3) {
                    guard let node = store.doc.allNodes.first(where: { $0.name == parts[0] }), let frame = store.doc.absoluteFrame(of: node.id) else { return }
                    let size = store.canvasSize
                    let c = CGPoint(x: frame.midX + (offset.first ?? 0), y: frame.minY + min(frame.height / 2, 400) + (offset.last ?? 0))
                    store.viewport = Viewport(origin: CGPoint(x: c.x - size.width / 2 / zoom, y: c.y - size.height / 2 / zoom), zoom: zoom)
                }
            }
        }
        // BEZZLE_FIND=seconds:words opens the find bar looking for them; "seconds:spelling" checks spelling.
        if let spec = env["BEZZLE_FIND"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let words = String(spec[spec.index(after: colon)...])
            after(s) {
                store.openFind(spelling: words == "spelling")
                if words != "spelling" {
                    store.finder?.query = words
                    store.finder?.replacement = words.uppercased()
                    store.findNext()
                }
            }
        }
        // BEZZLE_EDIT=name[:start,length] also picks out those letters.
        if let spec = env["BEZZLE_EDIT"] {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            let numbers = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Int($0) } : []
            after(0.8) {
                if let id = store.doc.allNodes.first(where: { $0.name == parts[0] })?.id { store.canvas?.beginEditing(id, action: "Typing") }
                if numbers.count == 2, let editor = store.canvas?.subviews.first?.subviews.first as? NSTextView {
                    editor.setSelectedRange(NSRange(location: numbers[0], length: numbers[1]))
                }
            }
        }
        if let spec = env["BEZZLE_MENU"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let anchor = String(spec[spec.index(after: colon)...])
            after(s) { NotificationCenter.default.post(name: .debugOpenMenu, object: anchor) }
        }
        if let s = env["BEZZLE_EXPORT"].flatMap(Double.init) { after(s) { store.exporting = true } }
        if let spec = env["BEZZLE_EXPORT_FILES"] {
            // seconds:folder:format[,format…] — exports what is selected, or every artboard, then quits.
            let parts = spec.split(separator: ":").map(String.init)
            if parts.count >= 3, let s = Double(parts[0]) {
                after(s) {
                    let layers = store.selection.compactMap { ExportItem(layer: $0, in: store.doc) }
                    let items = layers.isEmpty ? store.doc.artboards.flatMap(ExportItem.items(for:)) : layers
                    for format in parts[2].split(separator: ",").compactMap({ ExportFormat(rawValue: String($0)) }) {
                        Exporter.export(items, format: format, scale: 1, name: store.name, to: URL(fileURLWithPath: parts[1]), assets: store.assets)
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        if let spec = env["BEZZLE_KEYS"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let codes = spec[spec.index(after: colon)...].split(separator: ",").compactMap { UInt16($0) }
            for (i, code) in codes.enumerated() {
                after(s + Double(i) / 10) {
                    guard let canvas = store.canvas,
                          let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: "",
                                                   charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return }
                    canvas.keyDown(with: e)
                }
            }
        }
        if let spec = env["BEZZLE_RIGHTCLICK"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let name = String(spec[spec.index(after: colon)...])
            after(s) {
                guard let canvas = store.canvas, let node = store.doc.allNodes.first(where: { $0.name == name }),
                      let frame = store.doc.absoluteFrame(of: node.id) else { return }
                let p = canvas.convert(store.viewport.toView(CGPoint(x: frame.midX, y: frame.midY)), to: nil)
                if let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    canvas.rightMouseDown(with: e)
                }
            }
        }
        if let spec = env["BEZZLE_POINT"] {
            let parts = spec.split(separator: ":").map(String.init)
            if parts.count >= 2, let s = Double(parts[0]) {
                let offset = parts.count > 2 ? parts[2].split(separator: ",").compactMap { Double($0) } : []
                after(s) {
                    guard let canvas = store.canvas, let node = store.doc.allNodes.first(where: { $0.name == parts[1] }),
                          let frame = store.doc.absoluteFrame(of: node.id) else { return }
                    let c = CGPoint(x: frame.midX + (offset.first ?? 0), y: frame.midY + (offset.last ?? 0))
                    let p = canvas.convert(store.viewport.toView(c), to: nil)
                    if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                        canvas.mouseMoved(with: e)
                    }
                }
            }
        }
        if let spec = env["BEZZLE_CLICKS"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let steps = spec[spec.index(after: colon)...].split(separator: ";").map(String.init)
            for (i, step) in steps.enumerated() {
                after(s + Double(i) * 0.3) { pointer(step, on: store) }
            }
        }
        if let spec = env["BEZZLE_PREVIEW"], let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) {
            let id = String(spec[spec.index(after: colon)...])
            after(s) {
                if let preset = (Presets.shadows + Presets.innerShadows).first(where: { $0.id == id }) {
                    store.showPreview(id) { Presets.applyShadow(preset, to: &$0) }
                } else if let preset = Presets.corners.first(where: { $0.id == id }) {
                    store.showPreview(id) { $0.cornerRadius = Presets.cornerRadius(preset.radius, for: $0) }
                } else if let preset = Presets.borders.first(where: { $0.id == id }) {
                    store.showPreview(id) { Presets.applyBorder(preset.width, to: &$0) }
                } else if let points = Presets.textSizes.first(where: { "text-size-\(Int($0))" == id }) {
                    store.showPreview(id) { $0.style?.size = points }
                }
            }
        }
        if let spec = env["BEZZLE_STRESS"] {
            let parts = spec.split(separator: ":").map(String.init)
            if parts.count >= 2, let s = Double(parts[0]) {
                after(3) { Stress.run(store, seconds: s, report: URL(fileURLWithPath: parts[1]), only: parts.count > 2 ? parts[2] : nil) }
            }
        }
        sizeWindow()
    }

    /// One step of BEZZLE_CLICKS.
    private static func pointer(_ step: String, on store: DocumentStore) {
        guard let canvas = store.canvas else { return }
        var text = Substring(step)
        var kind = "click", clicks = 1, hold = false
        if text.hasPrefix("~") { kind = "move"; text = text.dropFirst() }
        if text.hasPrefix("+") { hold = true; text = text.dropFirst() }
        if text.hasPrefix("!") { clicks = 2; text = text.dropFirst() }
        let ends = text.split(separator: ">").map { $0.split(separator: ",").compactMap { Double($0) } }.filter { $0.count == 2 }
        guard let from = ends.first.map({ CGPoint(x: $0[0], y: $0[1]) }) else { return }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: canvas.convert(store.viewport.toView(p), to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: canvas.window?.windowNumber ?? 0,
                               context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : clicks, pressure: 1)
        }
        if kind == "move" {
            if let e = event(.mouseMoved, from) { canvas.mouseMoved(with: e) }
            return
        }
        if let e = event(.leftMouseDown, from) { canvas.mouseDown(with: e) }
        if ends.count > 1 {
            let to = CGPoint(x: ends[1][0], y: ends[1][1])
            for k in 1...6 {
                let t = CGFloat(k) / 6
                if let e = event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)) { canvas.mouseDragged(with: e) }
            }
            if !hold, let e = event(.leftMouseUp, to) { canvas.mouseUp(with: e) }
        } else if let e = event(.leftMouseUp, from) {
            canvas.mouseUp(with: e)
        }
    }

    private static func sizeWindow() {
        guard let spec = env["BEZZLE_WINDOW"] else { return }
        let size = spec.split(separator: "x").compactMap { Double($0) }
        guard size.count == 2 else { return }
        after(0.4) {
            for window in NSApp.windows where window.isVisible && window.contentView != nil {
                window.setFrame(NSRect(x: 80, y: 80, width: size[0], height: size[1]), display: true)
            }
        }
    }

    private static func scheduleSnapshots() {
        guard let shots = env["BEZZLE_SNAPSHOTS"] else { return }
        let list = shots.split(separator: ",").compactMap { item -> (Double, String)? in
            guard let colon = item.firstIndex(of: ":"), let s = Double(item[..<colon]) else { return nil }
            return (s, String(item[item.index(after: colon)...]))
        }
        for (i, (s, path)) in list.enumerated() {
            after(s) {
                snapshot(to: URL(fileURLWithPath: path))
                if i == list.count - 1 { NSApp.terminate(nil) }
            }
        }
    }

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    /// The front window, as it looks, into a PNG.
    static func snapshot(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        if env["BEZZLE_SNAPSHOT_LAYERS"] != nil, let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            // Through the layer tree, which clips and masks as the screen does.
            let cg = ctx.cgContext
            cg.scaleBy(x: CGFloat(rep.pixelsWide) / view.bounds.width, y: CGFloat(rep.pixelsHigh) / view.bounds.height)
            layer.render(in: cg)
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        if env["BEZZLE_DUMP_VIEWS"] != nil {
            var lines: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                let r = v.convert(v.bounds, to: nil)
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) win=\(r) clips=\(v.clipsToBounds) mask=\(v.layer?.masksToBounds ?? false)")
                for sub in v.subviews { walk(sub, depth + 1) }
            }
            if let canvas = NSApp.windows.compactMap({ $0.contentView?.firstDescendant(of: CanvasView.self) }).first {
                var up: NSView? = canvas.superview
                while let v = up { lines.insert("^ \(type(of: v)) win=\(v.convert(v.bounds, to: nil)) clips=\(v.clipsToBounds)", at: 0); up = v.superview }
                walk(canvas, 0)
            }
            // What a click in the middle of each named layer would reach.
            for name in (env["BEZZLE_HITTEST"] ?? "").split(separator: ",").map(String.init) {
                guard let canvas = NSApp.windows.compactMap({ $0.contentView?.firstDescendant(of: CanvasView.self) }).first,
                      let node = canvas.store.doc.allNodes.first(where: { $0.name == name }),
                      let frame = canvas.store.doc.absoluteFrame(of: node.id), let root = canvas.window?.contentView else { continue }
                let p = canvas.convert(canvas.store.viewport.toView(CGPoint(x: frame.midX, y: frame.midY)), to: nil)
                let hit = root.superview?.hitTest(p) ?? root.hitTest(p)
                lines.append("hit \(name) at \(p): \(hit.map { "\(type(of: $0))" } ?? "nothing")")
            }
            try? lines.joined(separator: "\n").write(to: url.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: A sample design

    static func makeDemo() -> URL? {
        var doc = BezzleDocument()
        var home = Node(kind: .artboard, name: "Home", frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        home.fill.color = RGBA(hex: "F7F4EE")!

        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 24, y: 72, width: 0, height: 0))
        title.text = "Good morning"
        title.style = TextStyle(family: TextStyle.system, face: "Bold", size: 32)
        title.fill.color = RGBA(hex: "1C1B19")!
        title.refit()

        var lede = Node(kind: .text, name: "Lede", frame: CGRect(x: 24, y: 120, width: 345, height: 0))
        lede.text = "Three things are waiting for you today. The first one is due at noon."
        lede.style = TextStyle(family: TextStyle.system, face: "Regular", size: 16, lineSpacing: 24, sizing: .autoHeight)
        lede.fill.color = RGBA(hex: "5E5A54")!
        lede.refit()

        var card = Node(kind: .rectangle, name: "Card", frame: CGRect(x: 24, y: 196, width: 345, height: 180))
        card.fill.color = .white
        card.cornerRadius = 18
        card.shadow = Shadow(on: true, color: RGBA(r: 0.23, g: 0.2, b: 0.15, a: 0.14), x: 0, y: 8, blur: 24)

        var avatar = Node(kind: .ellipse, name: "Avatar", frame: CGRect(x: 44, y: 216, width: 48, height: 48))
        avatar.fill.color = RGBA(hex: "3559C7")!

        var cardTitle = Node(kind: .text, name: "Card title", frame: CGRect(x: 108, y: 222, width: 0, height: 0))
        cardTitle.text = "Design review"
        cardTitle.style = TextStyle(family: TextStyle.system, face: "Semibold", size: 18)
        cardTitle.refit()

        var rule = Node(kind: .line, name: "Divider", frame: .zero)
        rule.setLineEnds(CGPoint(x: 44, y: 288), CGPoint(x: 349, y: 288))
        rule.border.color = RGBA(hex: "E5E1D9")!

        var button = Node(kind: .rectangle, name: "Button", frame: CGRect(x: 44, y: 308, width: 305, height: 48))
        button.fill.color = RGBA(hex: "1C1B19")!
        button.cornerRadius = 12

        var label = Node(kind: .text, name: "Button label", frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        label.text = "Join"
        label.style = TextStyle(family: TextStyle.system, face: "Semibold", size: 15)
        label.fill.color = .white
        label.refit()
        label.frame.origin = CGPoint(x: (196.5 - label.frame.width / 2).rounded(), y: (332 - label.frame.height / 2).rounded())

        home.children = [title, lede, card, avatar, cardTitle, rule, button, label]

        var profile = Node(kind: .artboard, name: "Profile", frame: CGRect(x: 473, y: 0, width: 393, height: 852))
        var big = Node(kind: .ellipse, name: "Portrait", frame: CGRect(x: 126, y: 120, width: 140, height: 140))
        big.fill.color = RGBA(hex: "D9D4CA")!
        big.border = Border(on: true, color: .white, width: 6, position: .outside)
        var tag = Node(kind: .rectangle, name: "Tag", frame: CGRect(x: 146, y: 300, width: 100, height: 28))
        tag.fill.color = RGBA(hex: "E8EDFA")!
        tag.cornerRadius = 14
        tag.rotation = -6
        profile.children = [big, tag]

        var sticky = Node(kind: .rectangle, name: "Note", frame: CGRect(x: 920, y: 40, width: 180, height: 140))
        sticky.fill.color = RGBA(hex: "F4E3A1")!
        sticky.rotation = 4
        sticky.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.12), x: 0, y: 4, blur: 10)

        doc.nodes = [home, profile, sticky]
        let url = Library.shared.freeURL(named: "Sample")
        do {
            try JSONEncoder().encode(doc).write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T ?? sub.firstDescendant(of: type) { return hit }
        }
        return nil
    }
}

/// Uses a design the way a person does, as fast as the app lets it, and notes how long each
/// kind of thing kept the app busy: every step waits for the screen to be drawn again.
@MainActor
enum Stress {
    static func run(_ store: DocumentStore, seconds: Double, report: URL, only: String? = nil) {
        guard let canvas = store.canvas else { return }
        if only == "flicker" { return finish(flicker(store, canvas: canvas), store: store, report: report) }
        if let only, only.hasPrefix("path") { return finish(pathEditing(store, canvas: canvas, points: Int(only.dropFirst(4))), store: store, report: report) }
        if let only, only.hasPrefix("nudge"), let z = Double(only.dropFirst(5)) {
            // "nudge2" only nudges, at one zoom, for long enough to be sampled.
            return finish(zoomed(store, canvas: canvas, levels: [CGFloat(z)], repeats: 800, nudgeOnly: true), store: store, report: report)
        }
        if let only, only.hasPrefix("zoom") {
            // "zoom8" stays at one zoom, panning for longer, to be sampled.
            let one = Double(only.dropFirst(4)).map { [CGFloat($0)] }
            return finish(zoomed(store, canvas: canvas, levels: one ?? [0.5, 1, 2, 4, 8, 16], repeats: one == nil ? 60 : 400), store: store, report: report)
        }
        if only == "panel" { return finish(panel(store, canvas: canvas), store: store, report: report) }
        let ids = store.doc.allNodes.filter { !$0.isArtboard }.map(\.id)
        // As a person clicks about: among the layers of a few artboards next to each other.
        let near = store.doc.artboards.prefix(3).flatMap(\.children).map(\.id)
        var times: [String: [Double]] = [:]
        func time(_ kind: String, _ body: () -> Void) {
            if let only, !kind.hasPrefix(only), !kind.hasPrefix("save") { return }
            let start = CACurrentMediaTime()
            body()
            // Until SwiftUI has caught up and the canvas has drawn.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            canvas.displayIfNeeded()
            canvas.window?.displayIfNeeded()
            times[kind, default: []].append((CACurrentMediaTime() - start) * 1000)
        }
        let end = Date(timeIntervalSinceNow: seconds)
        var i = 0
        while Date() < end {
            i += 1
            time("pan") {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i % 40 < 20 ? -12 : 12, wheel2: 8, wheel3: 0),
                   let e = NSEvent(cgEvent: cg) { canvas.scrollWheel(with: e) }
            }
            time("hover") { store.hovered = ids.randomElement() }
            if i % 8 == 0 || only == "select" { time("select") { store.selection = ids.randomElement().map { [$0] } ?? [] } }
            if only == "select" { time("select nearby") { store.selection = near.randomElement().map { [$0] } ?? [] } }
            if i % 16 == 0 || only == "nudge" { time("nudge") { store.nudge(dx: 1, dy: 0) } }
        }
        time("save") { store.save() }
        let t0 = CACurrentMediaTime()
        store.save()
        let t1 = CACurrentMediaTime()
        DocumentStore.finishSaving()
        let t2 = CACurrentMediaTime()
        times["save: asking"] = [(t1 - t0) * 1000]
        times["save: writing, in the background"] = [(t2 - t1) * 1000]
        finish(times, store: store, report: report)
    }

    private static func finish(_ times: [String: [Double]], store: DocumentStore, report: URL) {
        let lines = times.sorted { $0.key < $1.key }.map { kind, ms in
            guard !ms.isEmpty else { return "\(kind): none" }
            let sorted = ms.sorted()
            return String(format: "%@: %d times, median %.1f ms, slowest %.1f ms", kind, ms.count, sorted[sorted.count / 2], sorted.last ?? 0)
        }
        try? (["\(store.doc.allNodes.count) layers, \(store.doc.artboards.count) artboards"] + lines).joined(separator: "\n")
            .write(to: report, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Lets the app run for a while and gives the longest it went without coming back for more, in ms.
    private static func longestStall(_ seconds: Double) -> Double {
        var last = CACurrentMediaTime(), worst = 0.0
        let end = last + seconds
        while CACurrentMediaTime() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            last = now
        }
        return worst * 1000
    }

    /// Runs the app until `done`, and gives how long that took in ms, or nil after `limit` seconds.
    private static func wait(_ limit: Double, until done: () -> Bool) -> Double? {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < limit {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            if done() { return (CACurrentMediaTime() - start) * 1000 }
        }
        return nil
    }

    /// Pans, points and nudges on the busiest artboard, closer and closer.
    private static func zoomed(_ store: DocumentStore, canvas: CanvasView, levels: [CGFloat], repeats: Int, nudgeOnly only2: Bool = false) -> [String: [Double]] {
        var times: [String: [Double]] = [:]
        func count(_ n: Node) -> Int { n.children.reduce(1) { $0 + count($1) } }
        guard let board = store.doc.artboards.max(by: { count($0) < count($1) }) else { return times }
        let ids = board.children.map(\.id)
        let size = canvas.bounds.size
        let middle = CGPoint(x: board.frame.midX, y: board.frame.minY + min(board.frame.height / 2, 500))
        func time(_ kind: String, _ body: () -> Void) {
            let start = CACurrentMediaTime()
            body()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            canvas.displayIfNeeded()
            canvas.window?.displayIfNeeded()
            times[kind, default: []].append((CACurrentMediaTime() - start) * 1000)
        }
        for zoom in levels {
            let label = "×" + (zoom < 1 ? String(format: "%.1f", zoom) : String(format: "%02d", Int(zoom)))
            store.viewport = Viewport(origin: CGPoint(x: middle.x - size.width / 2 / zoom, y: middle.y - size.height / 2 / zoom), zoom: zoom)
            times["\(label) arriving, longest stall"] = [longestStall(0.8)]
            for i in 0..<(only2 ? 0 : repeats) {
                time("\(label) pan") {
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i % 20 < 10 ? -12 : 12, wheel2: i % 40 < 20 ? 8 : -8, wheel3: 0),
                       let e = NSEvent(cgEvent: cg) { canvas.scrollWheel(with: e) }
                }
                time("\(label) hover") { store.hovered = ids.randomElement() }
            }
            // Something in sight to move, among the layers of the artboard.
            let seen = store.visibleCanvasRect.offsetBy(dx: -board.frame.minX, dy: -board.frame.minY)
            let movable = board.children.filter { !$0.locked && !$0.hidden && $0.frame.intersects(seen) && $0.frame.width < board.frame.width / 2 }
            store.selection = movable.last.map { [$0.id] } ?? []
            times["\(label) moving \(movable.last?.name ?? "nothing")"] = [0]
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            for i in 0..<max(16, repeats / 2) { time("\(label) nudge") { store.nudge(dx: i % 2 == 0 ? 1 : -1, dy: 0) } }
            times["\(label) after nudging, longest stall"] = [longestStall(0.6)]
            store.selection = []
        }
        return times
    }

    /// Moves and zooms about as a person does, from the whole design down to one artboard, and
    /// counts what each frame drew: tiles kept, made, stood in for by others stretched, or still
    /// to come (bare paper), and how long after each move until nothing was left to make.
    private static func flicker(_ store: DocumentStore, canvas: CanvasView) -> [String: [Double]] {
        var times: [String: [Double]] = [:]
        func scroll(_ dx: Int32, _ dy: Int32, zoom: Bool) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            if zoom { cg.flags = .maskCommand }
            if let e = NSEvent(cgEvent: cg) { canvas.scrollWheel(with: e) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.016))
            canvas.display()
        }
        func phase(_ name: String, _ moves: () -> Void) {
            canvas.tiles.frames = []
            moves()
            let moving = canvas.tiles.frames ?? []
            canvas.tiles.frames = []
            // Then until there is nothing left to make, or two seconds.
            let start = CACurrentMediaTime()
            var done: Double?
            while CACurrentMediaTime() - start < 2 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.016))
                if canvas.needsDisplay { canvas.display() }
                if let last = canvas.tiles.frames?.last, last.made + last.stoodIn + last.papered + last.direct == 0 {
                    done = (CACurrentMediaTime() - start) * 1000
                    break
                }
            }
            let after = canvas.tiles.frames ?? []
            canvas.tiles.frames = nil
            for (when, frames) in [("while moving", moving), ("after", after)] {
                times["\(name) \(when): frames"] = [Double(frames.count)]
                times["\(name) \(when): frames with bare paper"] = [Double(frames.filter { $0.papered > 0 }.count)]
                times["\(name) \(when): frames with tiles stretched"] = [Double(frames.filter { $0.stoodIn > 0 }.count)]
                times["\(name) \(when): tiles made a frame"] = frames.map { Double($0.made) }
            }
            times["\(name): until all made, ms"] = [done ?? (after.isEmpty ? 0 : -1)]
            times["\(name): zoom ×100 at the end"] = [store.viewport.zoom * 100]
        }
        store.zoomToFit()
        _ = longestStall(3)
        phase("A overview pan") { for i in 0..<60 { scroll(i % 30 < 15 ? 14 : -14, 6, zoom: false) } }
        phase("B overview zoom in") { for _ in 0..<25 { scroll(0, 8, zoom: true) } }
        phase("C zoom out") { for _ in 0..<25 { scroll(0, -8, zoom: true) } }
        func count(_ n: Node) -> Int { n.children.reduce(1) { $0 + count($1) } }
        if let board = store.doc.artboards.max(by: { count($0) < count($1) }) {
            let size = canvas.bounds.size, zoom: CGFloat = 0.34
            let c = CGPoint(x: board.frame.midX, y: board.frame.minY + min(board.frame.height / 2, 400))
            store.viewport = Viewport(origin: CGPoint(x: c.x - size.width / 2 / zoom, y: c.y - size.height / 2 / zoom), zoom: zoom)
            _ = longestStall(2)
        }
        phase("D close pan") { for i in 0..<60 { scroll(i % 30 < 15 ? 14 : -14, i % 60 < 30 ? 10 : -10, zoom: false) } }
        phase("E close zoom in") { for _ in 0..<25 { scroll(0, 8, zoom: true) } }
        phase("F close zoom out") { for _ in 0..<25 { scroll(0, -8, zoom: true) } }
        return times
    }

    /// Drags a point of the design's longest path to and fro, as the pen tool does, its points
    /// showing, and times each step until drawn.
    /// With `points`, a path of that many curving points of its own is drawn across the busiest artboard first.
    private static func pathEditing(_ store: DocumentStore, canvas: CanvasView, points: Int? = nil) -> [String: [Double]] {
        var times: [String: [Double]] = [:]
        if let points, let board = store.doc.artboards.max(by: { $0.children.count < $1.children.count }) {
            // A wavy ring, as a traced illustration or a map's coast is.
            var d = ""
            for k in 0...points {
                let a = CGFloat(k) / CGFloat(points) * 2 * .pi
                let r = 380 + 40 * sin(a * 23)
                let p = CGPoint(x: board.frame.width / 2 + r * cos(a), y: 500 + r * sin(a))
                d += k == 0 ? "M \(p.x) \(p.y)" : " L \(p.x) \(p.y)"
            }
            d += " Z"
            var n = Node(kind: .path, name: "Big path", frame: .zero)
            n.path = d
            let box = PathData.bounds(d)
            n.pathBox = box
            // Attaching takes where it is on the canvas.
            n.frame = box.offsetBy(dx: board.frame.minX, dy: board.frame.minY)
            n.fill.on = true
            n.border = Border(on: true, color: .black, width: 2)
            store.edit("Draw") { $0.attach(n, to: board.id) }
        }
        guard let path = store.doc.allNodes.filter({ $0.kind == .path && store.doc.artboard(of: $0.id) != nil })
            .max(by: { ($0.path?.count ?? 0) < ($1.path?.count ?? 0) }) else { return times }
        store.selection = [path.id]
        store.zoomToSelection()
        store.editPoints()
        _ = longestStall(1)
        guard let (id, base) = store.editedPoints, let grabbed = base.allPoints.dropFirst(base.allPoints.count / 2).first else { return times }
        times["path: \(path.path?.count ?? 0) characters, \(base.allPoints.count) points"] = [0]
        store.selectedPoints = [grabbed]
        store.beginGesture()
        // Long enough to be sampled from outside.
        let until = CACurrentMediaTime() + 14
        var i = 0
        while CACurrentMediaTime() < until {
            i += 1
            let start = CACurrentMediaTime()
            var next = base
            next[grabbed] = base[grabbed].offset(by: CGPoint(x: CGFloat(i % 20 < 10 ? i % 10 : 10 - i % 10) * 3, y: 0))
            store.setPoints(next, of: id, "Move Points")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            canvas.display()
            canvas.window?.displayIfNeeded()
            times["drag a point", default: []].append((CACurrentMediaTime() - start) * 1000)
        }
        store.endGesture("Move Points")
        times["after letting go, longest stall"] = [longestStall(1)]
        return times
    }

    /// Does what clicks in the layers list do, with an artboard open in it, and times each until
    /// it shows, and the longest the app stays busy in the moment after.
    private static func panel(_ store: DocumentStore, canvas: CanvasView) -> [String: [Double]] {
        var times: [String: [Double]] = [:]
        guard let window = canvas.window else { return times }
        func count(_ n: Node) -> Int { n.children.reduce(1) { $0 + count($1) } }
        guard let board = store.doc.artboards.max(by: { count($0) < count($1) }) else { return times }
        let rows = board.children.reversed().prefix(10).map(\.id)
        // Selecting one of its layers opens it in the list.
        store.selection = [rows[0]]
        store.zoomToSelection()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        func time(_ kind: String, _ body: () -> Void) {
            let start = CACurrentMediaTime()
            body()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            canvas.displayIfNeeded()
            window.displayIfNeeded()
            times[kind, default: []].append((CACurrentMediaTime() - start) * 1000)
            times["\(kind): longest stall after", default: []].append(longestStall(0.8))
        }
        for k in 0..<16 { time("select a row") { store.selection = [rows[k % rows.count]] } }
        for k in 0..<12 {
            let id = rows[k / 2 % rows.count]
            time("hide a row") { store.setHidden(store.node(id)?.hidden != true, [id]) }
        }
        for k in 0..<12 {
            let id = rows[k / 2 % rows.count]
            time("lock a row") { store.setLocked(store.node(id)?.locked != true, [id]) }
        }
        return times
    }
}

extension Notification.Name {
    static let debugOpenMenu = Notification.Name("BezzleDebugOpenMenu")
}
#endif
