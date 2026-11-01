import Testing
import AppKit
@testable import Bezzle

/// Developing pictures: what the settings do to colours, how they are kept, and the pictures made.
@MainActor
struct DevelopTests {
    /// What one colour, 0…1 through the sRGB curve, comes out as.
    private func developed(_ c: SIMD3<Double>, _ d: Develop) -> SIMD3<Double> {
        let map = PointMap(d)
        // The shoulder a whole cube would bring back with, from its brightest corner.
        let shoulder = PointMap.Shoulder(top: PointMap.encode(map.apply(SIMD3(1, 1, 1)).max()), knee: 0.86)
        return map.finish(map.apply(c), shoulder: shoulder)
    }

    private func develop(_ settings: [Develop.Setting: Double]) -> Develop {
        var d = Develop()
        for (s, v) in settings { d[s] = v }
        return d
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// How far apart two colours are, in their part that differs most.
    private func far(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return max(abs(d.x), abs(d.y), abs(d.z))
    }

    @Test func nothingSetLeavesEveryColourAsItWas() {
        let map = PointMap(Develop())
        for r in stride(from: 0.0, through: 1, by: 0.125) {
            for g in stride(from: 0.0, through: 1, by: 0.25) {
                for b in stride(from: 0.0, through: 1, by: 0.25) {
                    let c = SIMD3(r, g, b)
                    let out = map.finish(map.apply(c), shoulder: .init(top: 1, knee: 0.86))
                    #expect(far(out, c) < 1e-6, "\(c) came out \(out)")
                }
            }
        }
    }

    @Test func eachSettingGoesTheWayItSays() {
        let grey = SIMD3(0.45, 0.45, 0.45)
        #expect(luma(developed(grey, develop([.exposure: 1]))) > 0.55)
        #expect(luma(developed(grey, develop([.exposure: -1]))) < 0.35)
        // Warmer is redder and less blue; magenta is less green.
        let warm = developed(grey, develop([.temperature: 60]))
        #expect(warm.x > warm.y && warm.y > warm.z)
        let cool = developed(grey, develop([.temperature: -60]))
        #expect(cool.z > cool.x)
        let pink = developed(grey, develop([.tint: 60]))
        #expect(pink.y < pink.x && pink.y < pink.z)
        // Shadows lift dark tones more than light ones, highlights the other way round.
        let dark = SIMD3(repeating: 0.2), light = SIMD3(repeating: 0.82)
        let lifted = develop([.shadows: 80])
        #expect(developed(dark, lifted).x - dark.x > developed(light, lifted).x - light.x + 0.03)
        let held = develop([.highlights: -80])
        #expect(light.x - developed(light, held).x > dark.x - developed(dark, held).x + 0.03)
        // Contrast pushes tones away from the middle.
        let punchy = develop([.contrast: 80])
        #expect(developed(dark, punchy).x < dark.x && developed(light, punchy).x > light.x)
        // Blacks to black, whites to white.
        #expect(developed(SIMD3(repeating: 0.04), develop([.blacks: -100])).x < 0.01)
        #expect(developed(SIMD3(repeating: 0.94), develop([.whites: 100])).x > 0.99)
        // No colour left at all.
        let red = SIMD3(0.8, 0.2, 0.15)
        let grey2 = developed(red, develop([.saturation: -100]))
        #expect(grey2.max() - grey2.min() < 0.005)
        // Vibrance adds most where there is least.
        let dull = SIMD3(0.5, 0.45, 0.4), vivid = SIMD3(0.9, 0.2, 0.1)
        func strength(_ c: SIMD3<Double>) -> Double { PointMap.hueAndSaturation(c).1 }
        let v = develop([.vibrance: 80])
        #expect(strength(developed(dull, v)) / strength(dull) > strength(developed(vivid, v)) / strength(vivid))
    }

    @Test func toneSettingsNeverTurnTheTonesAround() {
        let extremes: [[Develop.Setting: Double]] = [
            [.shadows: -100, .blacks: 100], [.shadows: 100, .highlights: -100], [.highlights: 100, .whites: -100],
            [.contrast: 100, .exposure: 2], [.contrast: -100, .exposure: -2], [.exposure: 4, .whites: 100],
        ]
        for settings in extremes {
            let d = develop(settings)
            var last = -1.0
            for i in 0...100 {
                let out = developed(SIMD3(repeating: Double(i) / 100), d).x
                #expect(out >= last - 1e-6, "\(settings) at \(i)")
                last = out
            }
        }
    }

    @Test func eachColourBelongsToItsBand() {
        for h in stride(from: 0.0, to: 360, by: 7) {
            let total = Develop.Band.allCases.reduce(0) { $0 + $1.weight(hue: h) }
            #expect(abs(total - 1) < 1e-9)
        }
        for band in Develop.Band.allCases { #expect(abs(band.weight(hue: band.hue) - 1) < 1e-9) }
        // Less blue leaves red alone.
        var d = Develop()
        d[.blue] = Develop.Shift(saturation: -100)
        let blue = SIMD3(0.15, 0.3, 0.85), red = SIMD3(0.85, 0.15, 0.12)
        #expect(PointMap.hueAndSaturation(developed(blue, d)).1 < 0.05)
        #expect(far(developed(red, d), red) < 1e-6)
        // Orange turned on goes towards yellow.
        var turn = Develop()
        turn[.orange] = Develop.Shift(hue: 100)
        let orange = SIMD3(0.9, 0.5, 0.15)
        #expect(PointMap.hueAndSaturation(developed(orange, turn)).0 > PointMap.hueAndSaturation(orange).0 + 10)
    }

    @Test func filesKeepOnlyWhatChanges() throws {
        var d = Develop()
        d[.exposure] = 0.6
        d[.temperature] = 12
        d[.contrast] = 0
        d[.blue] = Develop.Shift(hue: 0, saturation: 20, luminance: -15)
        let data = try JSONEncoder().encode(d)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["exposure", "temperature", "colors"])
        #expect((object["colors"] as? [String: [Double]])?["blue"] == [0, 20, -15])
        #expect(try JSONDecoder().decode(Develop.self, from: data) == d)
        // A name it does not know, from a later Bezzle, is passed over.
        let later = Data(#"{"exposure": 1, "grain": 30, "colors": {"teal": [1, 2, 3], "red": [5]}}"#.utf8)
        let read = try JSONDecoder().decode(Develop.self, from: later)
        #expect(read[.exposure] == 1 && read[.red].hue == 5 && read.bands.count == 1)
        // Settings are held in their range, and nothing set is nothing kept.
        d[.exposure] = 9
        #expect(d[.exposure] == 4)
        #expect(Develop().kept == nil)
        var fill = ImageFill(asset: "a.jpg", size: CGSize(width: 10, height: 10))
        fill.develop = d.kept
        #expect(try JSONDecoder().decode(ImageFill.self, from: JSONEncoder().encode(fill)) == fill)
    }

    @Test func wordsSayWhatWasDone() {
        #expect(Develop().words.isEmpty)
        let said = develop([.exposure: 0.8, .temperature: 30, .clarity: 40]).words.map { String(localized: $0) }
        #expect(said == ["Brighter", "Warmer", "Crisper"])
        #expect(develop([.dehaze: 50]).words.map { String(localized: $0) } == ["Clearer"])
        let scaled = develop([.exposure: 1, .contrast: 40]).scaled(by: 0.5)
        #expect(scaled[.exposure] == 0.5 && scaled[.contrast] == 20)
        #expect(develop([.exposure: 1]).scaled(by: 0).kept == nil)
    }

    // MARK: Pictures

    /// A picture `size` wide: dark to light across, and from blue at the top to orange at the
    /// bottom, half see-through when `alpha` is.
    private func picture(_ size: Int = 64, alpha: CGFloat = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<size {
            for x in 0..<size {
                let l = CGFloat(x) / CGFloat(size - 1), t = CGFloat(y) / CGFloat(size - 1)
                ctx.setFillColor(CGColor(srgbRed: l * (0.3 + 0.6 * t), green: l * 0.5, blue: l * (0.9 - 0.6 * t), alpha: alpha))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    private func mean(_ image: CGImage) -> SIMD4<Double> {
        let px = Pixels(image, longest: 64)!
        var sum = SIMD4<Double>()
        for i in 0..<(px.width * px.height) { sum += px.color(at: i)! }
        return sum / Double(px.width * px.height)
    }

    @Test func picturesAreDevelopedAndKept() {
        let source = picture()
        #expect(Developer.developed(source, nil) === source)
        #expect(Developer.developed(source, Develop()) === source)
        let brighter = Developer.developed(source, develop([.exposure: 1]))
        #expect(brighter.width == source.width && brighter.height == source.height)
        let (a, b) = (mean(source), mean(brighter))
        #expect(b.x + b.y + b.z > a.x + a.y + a.z + 0.15)
        // Asked again, the same picture is handed back rather than developed again.
        #expect(Developer.developed(source, develop([.exposure: 1])) === brighter)
    }

    @Test func detailAndHazeChangeThePictureAndKeepItsShape() {
        let source = picture(alpha: 0.5)
        for settings: [Develop.Setting: Double] in [[.clarity: 80], [.texture: -60], [.sharpness: 70], [.dehaze: 60], [.dehaze: -60]] {
            let out = Developer.developed(source, develop(settings))
            #expect(out !== source, "\(settings) did nothing")
            // What was half see-through still is.
            #expect(abs(mean(out).w - 0.5) < 0.02, "\(settings)")
        }
        let hazy = mean(Developer.developed(source, develop([.dehaze: -80])))
        let clear = mean(Developer.developed(source, develop([.dehaze: 80])))
        #expect(hazy.x + hazy.y + hazy.z > clear.x + clear.y + clear.z)
    }

    @Test func autoBrightensADarkPictureAndCoolsAWarmOne() {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<32 {
            ctx.setFillColor(CGColor(srgbRed: 0.08 + Double(i) * 0.006, green: 0.08 + Double(i) * 0.006, blue: 0.08 + Double(i) * 0.006, alpha: 1))
            ctx.fill(CGRect(x: i, y: 0, width: 1, height: 32))
        }
        #expect(Develop.auto(for: ctx.makeImage()!)[.exposure] > 0.5)
        for i in 0..<32 {
            let l = 0.35 + Double(i) * 0.012
            ctx.setFillColor(CGColor(srgbRed: l * 1.12, green: l, blue: l * 0.82, alpha: 1))
            ctx.fill(CGRect(x: i, y: 0, width: 1, height: 32))
        }
        #expect(Develop.auto(for: ctx.makeImage()!)[.temperature] < -5)
    }

    @Test func aPointedToneOrColourShowsAlone() {
        var d = Develop()
        d.isolate = .band(.blue)
        let red = developed(SIMD3(0.85, 0.15, 0.12), d), blue = developed(SIMD3(0.15, 0.3, 0.85), d)
        #expect(red.max() - red.min() < 0.01)
        #expect(blue.z - blue.x > 0.5)
        // Being pointed at is never kept.
        #expect(d.kept == nil)
    }

    // MARK: The picture as the control

    /// A design with a grey photo in it, on a canvas that is driven as `Bench` drives its own.
    private final class PhotoBench {
        let store: DocumentStore
        let canvas: CanvasView
        let undo = UndoManager()
        let photo: UUID

        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests-\(UUID().uuidString).bezzle")
            let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            let out = CGImageDestinationCreateWithURL(images.appendingPathComponent("photo.png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(out, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(out)

            var picture = CanvasTests.rect("Photo", CGRect(x: 50, y: 50, width: 200, height: 100))
            picture.fill.image = ImageFill(asset: "photo.png", size: CGSize(width: 200, height: 100))
            photo = picture.id
            var a = Node(kind: .artboard, name: "A", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
            a.children = [picture]
            var doc = BezzleDocument()
            doc.nodes = [a]
            doc.viewport = Viewport(origin: .zero, zoom: 1)
            store = DocumentStore(url: url, document: doc)
            canvas = CanvasView(store: store)
            canvas.wantsLayer = false
            canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            store.canvas = canvas
            store.undoManager = undo
            undo.groupsByEvent = false
            store.viewport = Viewport(origin: .zero, zoom: 1)
            store.selection = [photo]
        }

        var node: Node? { store.node(photo) }

        private func event(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(store.viewport.toView(p), to: nil), modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        private func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        func drag(_ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = [], release: Bool = true) {
            step {
                canvas.mouseDown(with: event(.leftMouseDown, from, flags: flags))
                for i in 1...4 {
                    let t = CGFloat(i) / 4
                    canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), flags: flags))
                }
                if release { canvas.mouseUp(with: event(.leftMouseUp, to, flags: flags)) }
            }
        }

        func release(_ p: CGPoint) { step { canvas.mouseUp(with: event(.leftMouseUp, p)) } }

        func escape() {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            step { canvas.keyDown(with: e) }
        }
    }

    @Test func thePhotoIsTheControlOnlyWithTheTargetOn() throws {
        let bench = try PhotoBench()
        bench.store.openAspect = .photo
        let middle = CGPoint(x: 250, y: 200), at = bench.node!.frame

        // With the card open but the target off, a drag on the photo moves it, as on any layer.
        bench.drag(middle, CGPoint(x: 250, y: 160))
        #expect(bench.node?.frame != at)
        #expect(bench.node?.fill.image?.develop == nil)
        bench.undo.undo()
        #expect(bench.node?.frame == at)

        // With the target on, the same drag lightens the grey photo's middle tones instead.
        bench.store.developOnPhoto = true
        bench.drag(middle, CGPoint(x: 250, y: 160))
        #expect(bench.undo.undoActionName == "Exposure")
        #expect(bench.node?.frame == at)
        let lighter = bench.node?.fill.image?.develop?[.exposure] ?? 0
        #expect(abs(lighter - 0.5) < 0.02, "40 points up is half a stop, not \(lighter)")

        // Escape during a drag takes it back; Escape again gives the photo back to moving.
        bench.drag(middle, CGPoint(x: 250, y: 120), release: false)
        #expect((bench.node?.fill.image?.develop?[.exposure] ?? 0) > lighter)
        bench.escape()
        #expect(bench.node?.fill.image?.develop?[.exposure] == lighter)
        bench.release(CGPoint(x: 250, y: 120))
        #expect(bench.node?.fill.image?.develop?[.exposure] == lighter)
        #expect(bench.store.developOnPhoto)
        bench.escape()
        #expect(!bench.store.developOnPhoto)
        #expect(bench.store.selection == [bench.photo])

        // Undo takes the half stop away. Here every step is a group of the undo history, those
        // that changed nothing too, where the app's history only has steps that changed something.
        for _ in 0..<10 where bench.node?.fill.image?.develop != nil && bench.undo.canUndo { bench.undo.undo() }
        #expect(bench.node?.fill.image?.develop == nil)
    }

    // MARK: The assistant

    @Test func theAssistantDevelopsAPhoto() async {
        let bench = Bench()
        MCPTools.opened(bench.store)
        var photo = CanvasTests.rect("Photo", CGRect(x: 50, y: 50, width: 100, height: 100))
        photo.fill.image = ImageFill(asset: "photo.png", size: CGSize(width: 200, height: 100))
        bench.step { bench.store.add(photo, onto: bench.a.id) }
        let tools = MCPTools()
        func call(_ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            arguments["layers"] = ["Photo"]
            let result = await tools.call("develop_photo", arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let answer = await call(["exposure": 0.5, "temperature": 20, "colors": ["blue": ["saturation": 30]]])
        #expect(!answer.failed, "\(answer.text)")
        let d = bench.node("Photo")?.fill.image?.develop
        #expect(d?[.exposure] == 0.5 && d?[.temperature] == 20 && d?[.blue].saturation == 30)
        #expect(answer.text.contains("\"develop\""))
        #expect(await call(["exposure": 9]).failed)
        #expect(await call(["colors": ["teal": ["hue": 1]]]).failed)
        _ = await call(["reset": true])
        #expect(bench.node("Photo")?.fill.image?.develop == nil)
        bench.store.undoManager?.undo()
        #expect(bench.node("Photo")?.fill.image?.develop?[.exposure] == 0.5)
    }
}
