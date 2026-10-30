import Testing
import AppKit
@testable import Bezzle

struct NumberEntryTests {
    @Test func plainNumbersAndSums() {
        #expect(NumberEntry.parse("24") == .value(24))
        #expect(NumberEntry.parse(" 12,5 ") == .value(12.5))
        #expect(NumberEntry.parse("120/3") == .value(40))
        #expect(NumberEntry.parse("2+3*4") == .value(14))
        #expect(NumberEntry.parse("(2+3)×4") == .value(20))
        #expect(NumberEntry.parse("16pt", unit: "pt") == .value(16))
        #expect(NumberEntry.parse("abc") == nil)
        #expect(NumberEntry.parse("") == nil)
        #expect(NumberEntry.parse("4/0") == nil)
    }

    @Test func changesToWhatIsThere() {
        #expect(NumberEntry.parse("+10") == .add(10))
        #expect(NumberEntry.parse("*2") == .multiply(2))
        #expect(NumberEntry.parse("x2") == .multiply(2))
        #expect(NumberEntry.parse("×1.5") == .multiply(1.5))
        #expect(NumberEntry.parse("/4") == .multiply(0.25))
        #expect(abs((NumberEntry.parse("+10%")?.applied(to: 200) ?? 0) - 220) < 1e-9)
        // A minus is a negative position, but takes away from a width.
        #expect(NumberEntry.parse("-5", negatives: true) == .value(-5))
        #expect(NumberEntry.parse("-5", negatives: false) == .add(-5))
        #expect(abs((NumberEntry.parse("-10%", negatives: false)?.applied(to: 200) ?? 0) - 180) < 1e-9)
    }

    @Test func sharesOfTheWhole() {
        #expect(NumberEntry.parse("50%") == .share(0.5))
        #expect(NumberEntry.parse("50%")?.applied(to: 80, whole: 400) == 200)
        // With nothing to measure against, a share is of the value itself.
        #expect(NumberEntry.parse("50%")?.applied(to: 80) == 40)
        // In a field measured in percent, % is only the unit.
        #expect(NumberEntry.parse("50%", unit: "%") == .value(50))
    }
}

@MainActor
struct PreviewTests {
    @Test func aPreviewShowsOnTheCanvasWithoutChangingTheDesign() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        let id = bench.node("R")!.id
        bench.store.selection = [id]
        bench.store.showPreview("shadow-floating") { Presets.applyShadow(Presets.shadows[3], to: &$0) }
        #expect(bench.store.shownDoc.node(id)?.shadow.on == true)
        #expect(bench.node("R")?.shadow.on == false)
        #expect(!bench.undo.canUndo)
        // Another control leaving does not take it away; its own does, and so does a new selection.
        bench.store.showPreview("corner-pill", nil)
        #expect(bench.store.preview != nil)
        bench.store.showPreview("shadow-floating", nil)
        #expect(bench.store.preview == nil)
        bench.store.showPreview("shadow-soft") { $0.shadow.on = true }
        bench.store.selection = []
        #expect(bench.store.preview == nil)
    }

    @Test func theDesignsColoursComeMostUsedFirst() {
        var a = CanvasTests.rect("A", .zero), b = CanvasTests.rect("B", .zero), c = CanvasTests.rect("C", .zero)
        a.fill.color = RGBA(hex: "FF0000")!
        b.fill.color = RGBA(hex: "00FF00")!
        c.fill.color = RGBA(hex: "00FF00", alpha: 0.5)!
        let bench = Bench(extra: [a, b, c])
        #expect(bench.store.designColors.map(\.hex).prefix(2) == ["00FF00", "FF0000"])
    }
}

struct PresetTests {
    @Test func aPillRoundsTheShortSides() {
        let wide = Node(kind: .rectangle, name: "W", frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        #expect(Presets.cornerRadius(nil, for: wide) == 20)
        #expect(Presets.cornerRadius(12, for: wide) == 12)
    }

    @Test func bordersAndShadowsKnowTheirOwn() {
        var n = Node(kind: .rectangle, name: "R", frame: .zero)
        Presets.applyBorder(2, to: &n)
        #expect(Presets.isBorder(2, n.border))
        #expect(!Presets.isBorder(nil, n.border))
        Presets.applyBorder(nil, to: &n)
        #expect(n.border.width == 2 && n.border.dash == 4 && n.border.gap == 4)
        #expect(Presets.isBorder(nil, n.border))
        n.shadow.color = RGBA(hex: "3B3326")!
        Presets.applyShadow(Presets.shadows[2], to: &n)
        #expect(Presets.isShadow(Presets.shadows[2], n.shadow))
        // The layer's own shadow colour stays; only how strong it is changes.
        #expect(n.shadow.color.hex == "3B3326")
    }

    @Test func aShadowMovesInsideAndBack() {
        var n = Node(kind: .rectangle, name: "R", frame: .zero)
        Presets.applyShadow(Presets.shadows[1], to: &n)
        // A choice becomes the one across from it: Soft, Pressed.
        Presets.setShadowInset(true, on: &n)
        #expect(n.shadow.inside && Presets.isShadow(Presets.innerShadows[1], n.shadow))
        #expect(!Presets.isShadow(Presets.shadows[1], n.shadow))
        Presets.setShadowInset(false, on: &n)
        #expect(n.shadow.outside && Presets.isShadow(Presets.shadows[1], n.shadow))
        // One set by hand keeps its numbers.
        n.shadow.y = 7
        Presets.setShadowInset(true, on: &n)
        #expect(n.shadow.inside && n.shadow.y == 7 && n.shadow.blur == 12)
        // Back under the layer it is as a shadow always was, so files and older Bezzles read it alike.
        Presets.setShadowInset(false, on: &n)
        #expect(n.shadow.inset == nil)
    }

    @Test func aBlurKeepsWhatItBlurs() {
        var n = Node(kind: .rectangle, name: "R", frame: .zero)
        Presets.applyBlur(8, to: &n)
        #expect(n.blur?.on == true && n.blur?.radius == 8 && n.blur?.background == false)
        // A blur of what is behind stays one, with its light and fill, when its amount changes.
        n.blur?.background = true
        n.blur?.brightness = -0.2
        n.blur?.fillOpacity = 0.3
        Presets.applyBlur(32, to: &n)
        #expect(n.blur == Blur(radius: 32, background: true, brightness: -0.2, fillOpacity: 0.3))
        // One that was switched off comes back on.
        n.blur?.on = false
        Presets.applyBlur(3, to: &n)
        #expect(n.blur?.on == true && n.blur?.radius == 3)
    }
}

@MainActor
struct CanvasHandleTests {
    @Test func aCornerDotRoundsTheCorners() {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))])
        bench.click(CGPoint(x: 160, y: 160))
        // With square corners the dot sits ten points in from the corner at 110,110.
        bench.drag(CGPoint(x: 120, y: 120), CGPoint(x: 140, y: 140))
        #expect(bench.node("R")?.cornerRadius == 30)
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 100, height: 100))
        // As far in as it goes, it is a circle, and no further.
        bench.drag(CGPoint(x: 140, y: 140), CGPoint(x: 230, y: 230))
        #expect(bench.node("R")?.cornerRadius == 50)
        bench.undoLast()
        #expect(bench.node("R")?.cornerRadius == 30)
    }

    @Test func draggingTheShadowMovesIt() {
        var r = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        r.shadow = Shadow(on: true, color: .shadow, x: 0, y: 20, blur: 10)
        let bench = Bench(extra: [r])
        bench.click(CGPoint(x: 160, y: 160))
        // Below the layer, where only its shadow is.
        bench.drag(CGPoint(x: 160, y: 225), CGPoint(x: 180, y: 255))
        #expect(bench.node("R")?.shadow.x == 20)
        #expect(bench.node("R")?.shadow.y == 50)
        #expect(bench.node("R")?.frame.origin == CGPoint(x: 10, y: 10))
        bench.undoLast()
        #expect(bench.node("R")?.shadow.y == 20)
    }

    @Test func aClickOnTheShadowStillSelectsWhatIsThere() {
        var r = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 100, height: 100))
        r.shadow = Shadow(on: true, color: .shadow, x: 0, y: 20, blur: 10)
        let bench = Bench(extra: [r])
        bench.click(CGPoint(x: 160, y: 160))
        let before = bench.store.doc
        bench.click(CGPoint(x: 160, y: 225))
        #expect(bench.store.selection.isEmpty)
        #expect(bench.store.doc == before)
    }
}
