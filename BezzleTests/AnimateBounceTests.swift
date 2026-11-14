import Testing
import AppKit
import SwiftUI
@testable import Bezzle

/// A spring's bounce, set where a key's pace is chosen: on every spring among the keys in hand,
/// alike and in one step; from the Spring chip dragged sideways, or to the number; and read and
/// set by an assistant.
@MainActor
struct AnimateBounceTests {
    /// On artboard A: a card and a badge.
    let bench: Bench
    let hand: FilmHand

    init() {
        bench = Bench(extra: [CanvasTests.rect("Card", CGRect(x: 40, y: 40, width: 120, height: 80)),
                              CanvasTests.rect("Badge", CGRect(x: 240, y: 180, width: 60, height: 40))])
        hand = FilmHand(store: bench.store)
        bench.store.show(.animate)
        bench.store.glide.stop()
        // The card comes in by a spring at 0.8, its fade evenly at 0.6; the badge by a spring at 0.8 too.
        let card = bench.node("Card")!.id, badge = bench.node("Badge")!.id
        bench.step {
            bench.store.edit("Add Key") { doc in
                doc.update(card) { n in
                    n.setKey(.move, [30, 0], at: 0.2)
                    n.setKey(.move, [0, 0], at: 0.8, ease: .spring())
                    n.setKey(.fade, [0], at: 0.2)
                    n.setKey(.fade, [1], at: 0.6, ease: .linear)
                }
                doc.update(badge) { n in
                    n.setKey(.scale, [0.5, 0.5], at: 0)
                    n.setKey(.scale, [1, 1], at: 0.8, ease: .spring(0.6))
                }
            }
        }
    }

    var store: DocumentStore { bench.store }
    private var card: UUID { bench.node("Card")!.id }
    private var badge: UUID { bench.node("Badge")!.id }

    private func ease(_ name: String, _ property: MotionProperty, at t: Double) -> MotionEase? {
        guard let track = bench.node(name)?[track: property], let i = track.index(at: t) else { return nil }
        return track.keys[i].ease
    }

    /// How far a value has come at most on its way from one key to the next, the way being 1.
    private func furthest(_ name: String, _ property: MotionProperty, from a: Double, to b: Double) -> Double {
        let node = bench.node(name)!
        let first = node.value(of: property, at: a)[0], last = node.value(of: property, at: b)[0]
        return (0...200).map { (node.value(of: property, at: a + (b - a) * Double($0) / 200)[0] - first) / (last - first) }.max()!
    }

    // MARK: What the keys in hand share

    @Test func theKeysInHandShareAPaceWhateverEachSpringsBounce() {
        // Both layers picked, at the moment both have a spring: one of 0.3, one of 0.6.
        store.selection = [card, badge]
        store.seek(0.8)
        #expect(store.sharedPace == .spring)
        #expect(store.sharedBounce == nil)
        // No one pace to the last number, though one kind.
        #expect(store.sharedEase == nil)
        // The card alone.
        store.selection = [card]
        #expect(store.sharedPace == .spring && store.sharedBounce == 0.3)
        // Where its keys are come to in different ways, neither.
        store.film.keys = [FilmKeyRef(card, at: 0.8), FilmKeyRef(card, at: 0.6)]
        #expect(store.sharedPace == nil)
        // The springs among them still have their bounce.
        #expect(store.sharedBounce == 0.3)
        // No spring among them, no bounce.
        store.film.keys = [FilmKeyRef(card, at: 0.6)]
        #expect(store.sharedPace == .linear && store.sharedBounce == nil)
        // A spring that says nothing of its bounce has the usual.
        store.film.keys = []
        bench.step { store.edit("Change Pace") { $0.update(self.card) { $0.setEase(MotionEase(kind: .spring), at: 0.8, of: [.move]) } } }
        #expect(ease("Card", .move, at: 0.8)?.bounce == nil)
        #expect(store.sharedBounce == 0.3)
        // Nothing in hand, nothing shared.
        store.selection = []
        #expect(store.sharedPace == nil && store.sharedBounce == nil)
    }

    // MARK: Setting it

    @Test func aBounceGoesToEverySpringInHandInOneStepAndToNothingElse() {
        store.selection = [card, badge]
        store.film.keys = [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8), FilmKeyRef(card, at: 0.6)]
        let before = store.doc
        bench.step { store.setBounce(0.45) }
        #expect(ease("Card", .move, at: 0.8) == .spring(0.45))
        #expect(ease("Badge", .scale, at: 0.8) == .spring(0.45))
        #expect(store.sharedBounce == 0.45)
        // The fade comes evenly still: it is no spring, and is not made one.
        #expect(ease("Card", .fade, at: 0.6) == .linear)
        // Nor is any key that was not in hand touched.
        #expect(ease("Card", .move, at: 0.2) == nil && ease("Badge", .scale, at: 0) == nil)
        #expect(bench.undo.undoActionName == "Bounce")
        bench.undo.undo()
        #expect(store.doc == before)
        bench.undo.redo()
        #expect(ease("Card", .move, at: 0.8) == .spring(0.45) && ease("Badge", .scale, at: 0.8) == .spring(0.45))
    }

    @Test func withNoKeysPickedItGoesToTheSpringsAtThePlayhead() {
        store.selection = [card]
        store.seek(0.8)
        bench.step { store.setBounce(0.1) }
        #expect(ease("Card", .move, at: 0.8) == .spring(0.1))
        #expect(ease("Badge", .scale, at: 0.8) == .spring(0.6))
        // Between keys there is none to set.
        store.seek(0.5)
        let before = store.doc
        bench.step { store.setBounce(0.9) }
        #expect(store.doc == before)
    }

    @Test func aBounceIsKeptToWhatASpringCanHave() {
        store.selection = [card]
        store.seek(0.8)
        for (asked, kept) in [(7.0, 1.0), (-1, 0), (0.336, 0.34), (0.5, 0.5), (1, 1), (0, 0)] {
            bench.step { store.setBounce(asked) }
            #expect(ease("Card", .move, at: 0.8)?.bounce == kept, "asked \(asked)")
        }
        // What is no number changes nothing.
        let before = store.doc
        bench.step { store.setBounce(.nan); store.setBounce(.infinity) }
        #expect(store.doc == before)
    }

    @Test func theMoreBounceTheFurtherPastItGoes() {
        store.selection = [card]
        store.seek(0.8)
        var last = 1.0
        for bounce in [0, 0.2, 0.5, 0.8, 1] {
            bench.step { store.setBounce(bounce) }
            let most = furthest("Card", .move, from: 0.2, to: 0.8)
            // With none it only arrives; with any, it goes past, and further with more.
            if bounce == 0 { #expect(most <= 1.0001) } else { #expect(most > last + 0.003, "bounce \(bounce)") }
            last = most
        }
        // With all there is, by a good third of the way.
        #expect(last > 1.3)
        // The line of a property's own row is drawn from the same curve.
        store.film.open = [card]
        let rows = FilmRow.rows(of: store.filmBoard!, open: store.film.open)
        let move = rows.first { $0.property == .move }
        #expect(move?.marks.last?.pace == .curve(.spring, bounce: 1))
    }

    // MARK: Choosing Spring

    @Test func choosingSpringKeepsTheBounceThatIsThere() {
        // The badge's spring of 0.6, chosen again: as it was.
        store.selection = [badge]
        store.seek(0.8)
        bench.step { store.setPace(.spring) }
        #expect(ease("Badge", .scale, at: 0.8) == .spring(0.6))
        // The card's even fade, in hand with its spring of 0.3: it springs as that does.
        store.selection = [card]
        store.film.keys = [FilmKeyRef(card, at: 0.8), FilmKeyRef(card, at: 0.6)]
        bench.step { store.setBounce(0.7) }
        bench.step { store.setPace(.spring) }
        #expect(ease("Card", .fade, at: 0.6) == .spring(0.7) && ease("Card", .move, at: 0.8) == .spring(0.7))
        #expect(bench.undo.undoActionName == "Change Pace")
        // With no spring among them, the usual.
        store.film.keys = [FilmKeyRef(card, at: 0.2)]
        bench.step { store.setPace(.spring) }
        #expect(ease("Card", .move, at: 0.2) == .spring(0.3) && ease("Card", .fade, at: 0.2) == .spring(0.3))
        // Any other pace has no bounce to keep.
        bench.step { store.setPace(.easeOut) }
        #expect(ease("Card", .move, at: 0.2) == .easeOut)
        bench.step { store.setPace(.auto) }
        #expect(ease("Card", .move, at: 0.2) == nil)
        // The menu on a bead chooses the same way: the badge's spring stays as bouncy as it is.
        store.selection = [badge]
        let board = store.filmBoard!
        let rows = FilmRow.rows(of: board, open: store.film.open)
        let scale = FilmScale(width: 600, span: FilmScale.span(for: board.filmLength))
        let line = rows.firstIndex { $0.layer == badge }!
        hand.hot = hand.point(CGPoint(x: scale.x(0.8), y: (CGFloat(line) + 0.5) * FilmTimeline.rowHeight), rows: rows, scale: scale)
        let items = hand.menu(rows: rows, scale: scale).filter { $0.kind == .item }
        #expect(items.filter(\.checked).map(\.title) == [MotionEase.spring().title])
        bench.step { items.first { $0.title == MotionEase.spring().title }?.action() }
        #expect(ease("Badge", .scale, at: 0.8) == .spring(0.6))
    }

    // MARK: The Spring chip, dragged

    @Test func theSpringChipDraggedSetsTheBounceInOneStep() {
        store.selection = [card, badge]
        store.film.keys = [FilmKeyRef(card, at: 0.8), FilmKeyRef(badge, at: 0.8)]
        let before = store.doc
        // They differ: the drag sets out from the usual, and both go with it.
        bench.step {
            for dx in [10, 30, 60] as [CGFloat] { hand.turnBounce(by: dx) }
            #expect(store.sharedBounce == 0.7)
            hand.turnBounce(by: 75)
            hand.bounceTurned()
        }
        #expect(ease("Card", .move, at: 0.8) == .spring(0.8) && ease("Badge", .scale, at: 0.8) == .spring(0.8))
        #expect(bench.undo.undoActionName == "Bounce")
        bench.undo.undo()
        #expect(store.doc == before)
        bench.undo.redo()
        // From 0.8 back down, it is held at the usual as it passes, and goes on below it.
        bench.step {
            hand.turnBounce(by: -72)
            #expect(store.sharedBounce == 0.3)
            hand.turnBounce(by: -78)
            #expect(store.sharedBounce == 0.3)
            hand.turnBounce(by: -90)
            #expect(store.sharedBounce == 0.2)
            // Past either end it stops there.
            hand.turnBounce(by: -400)
            #expect(store.sharedBounce == 0)
            hand.turnBounce(by: 900)
            #expect(store.sharedBounce == 1)
            hand.bounceTurned()
        }
        // Dragged and put back where it was, nothing is left to undo of it.
        let rest = store.doc
        bench.step {
            hand.turnBounce(by: -40)
            hand.turnBounce(by: 0)
            hand.bounceTurned()
        }
        #expect(store.doc == rest)
        // With no spring in hand the chip is no dial, and a drag told of does nothing.
        store.film.keys = [FilmKeyRef(card, at: 0.6)]
        bench.step {
            hand.turnBounce(by: 50)
            hand.bounceTurned()
        }
        #expect(store.doc == rest && !store.inGesture)
    }

    @Test func theChipsPictureTellsTheWholeDial() {
        // With the usual bounce it is the picture the chip always had; with none, a plain arrival; with all, all.
        #expect(PaceChip.drawn(0) == 0 && PaceChip.drawn(1) == 1)
        #expect(abs(PaceChip.drawn(0.3) - PaceChip.usual) < 1e-12)
        // More bounce, more to see, all the way.
        let drawn = stride(from: 0.0, through: 1, by: 0.05).map(PaceChip.drawn)
        #expect(zip(drawn, drawn.dropFirst()).allSatisfy { $0 < $1 })
        #expect(PaceChip.drawn(-2) == 0 && PaceChip.drawn(9) == 1)
    }

    /// The chip itself, in a window nobody sees, pressed as the window is told of a press: a
    /// drag is the dial's and no click, and a click is no drag.
    @Test func theChipItselfTellsADragFromAClick() async throws {
        nonisolated final class Told: @unchecked Sendable {
            var clicks = 0, turns: [CGFloat] = [], ends = 0
        }
        let told = Told()
        let chip = PaceChip(kind: .spring, chosen: true, bounce: 0.3, turned: { dx in
            if let dx { told.turns.append(dx) } else { told.ends += 1 }
        }) { told.clicks += 1 }
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 68, height: 66), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: chip.padding(20))
        window.contentView = host
        // Behind everything, off every screen and clear through: there for the views to be
        // told of presses, and for nobody to see.
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        host.display()
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 33), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        func pause() async throws { try await Task.sleep(for: .milliseconds(40)) }
        try await pause()
        // Dragged twenty points to the right.
        window.sendEvent(try mouse(.leftMouseDown, 34))
        try await pause()
        for dx in [2, 6, 12, 20] as [CGFloat] {
            window.sendEvent(try mouse(.leftMouseDragged, 34 + dx))
            try await pause()
        }
        window.sendEvent(try mouse(.leftMouseUp, 54))
        try await pause()
        #expect(told.turns == [6, 12, 20], "\(told.turns)")
        #expect(told.ends == 1 && told.clicks == 0)
        // Clicked.
        window.sendEvent(try mouse(.leftMouseDown, 34))
        try await pause()
        window.sendEvent(try mouse(.leftMouseUp, 34))
        try await pause()
        #expect(told.clicks == 1 && told.ends == 1)
        // A chip that is no dial only takes the click.
        let plain = Told()
        host.rootView = PaceChip(kind: .linear, chosen: false) { plain.clicks += 1 }.padding(20)
        host.layoutSubtreeIfNeeded()
        try await pause()
        window.sendEvent(try mouse(.leftMouseDown, 34))
        try await pause()
        window.sendEvent(try mouse(.leftMouseUp, 34))
        try await pause()
        #expect(plain.clicks == 1 && plain.turns.isEmpty && plain.ends == 0)
    }

    // MARK: The assistant

    @Test func theAssistantReadsAndSetsABounceOfShaderInputsToo() async throws {
        let bench = Bench(extra: ShaderKeyTests.painted)
        MCPTools.opened(bench.store)
        defer { MCPTools.closed(bench.store) }
        let tools = MCPTools()
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let keyed = await call("animate", ["keys": [
            ["layer": "Card", "input": "u_strength", "time": 0, "value": 0],
            ["layer": "Card", "input": "u_strength", "time": 1, "value": 0.5, "pace": "spring", "bounce": 0.75],
            ["layer": "Card", "property": "scale", "time": 0, "value": 0.5],
            ["layer": "Card", "property": "scale", "time": 1, "value": 1, "pace": "spring", "bounce": 0.15],
        ]])
        #expect(!keyed.failed)
        let card = try #require(bench.node("Card"))
        #expect(card[track: "shader.u_strength"]?.keys.last?.ease == .spring(0.75))
        #expect(card[track: .scale]?.keys.last?.ease == .spring(0.15))
        let read = await call("get_animation", ["artboard": "A"])
        let object = try JSONSerialization.jsonObject(with: Data(read.text.utf8)) as? [String: Any]
        let layer = (object?["layers"] as? [[String: Any]])?.first { $0["name"] as? String == "Card" }
        let strength = (((layer?["shader"] as? [String: Any])?["u_strength"]) as? [String: Any])?["keys"] as? [[String: Any]]
        #expect(strength?.last?["pace"] as? String == "spring" && strength?.last?["bounce"] as? Double == 0.75)
        #expect(strength?.first?["bounce"] == nil)
        let scale = ((layer?["tracks"] as? [String: Any])?["scale"]) as? [[String: Any]]
        #expect(scale?.last?["bounce"] as? Double == 0.15)
        // What the person then sets in the panel is what the assistant reads next.
        bench.store.show(.animate)
        bench.store.selection = [card.id]
        bench.store.seek(1)
        bench.step { bench.store.setBounce(0.4) }
        let again = try JSONSerialization.jsonObject(with: Data((await call("get_animation", ["artboard": "A"])).text.utf8)) as? [String: Any]
        let now = (again?["layers"] as? [[String: Any]])?.first { $0["name"] as? String == "Card" }
        let nowScale = ((now?["tracks"] as? [String: Any])?["scale"]) as? [[String: Any]]
        let nowStrength = (((now?["shader"] as? [String: Any])?["u_strength"]) as? [String: Any])?["keys"] as? [[String: Any]]
        #expect(nowScale?.last?["bounce"] as? Double == 0.4 && nowStrength?.last?["bounce"] as? Double == 0.4)
    }
}
