import Testing
import AppKit
import SwiftUI
@testable import Bezzle

/// The inspector's cards asked for once more after what they were made for has gone. SwiftUI may
/// evaluate a card (a pile's `ForEach`, a body it kept) after the selection has changed and before
/// the panel is made again, and a card reads the selection as it is then: Bezzle 1.8 broke off
/// reading the first of no layers there (2026-11-14). Each card is made here for a selection, the
/// selection is emptied, shrunk or changed under it, and the card is asked for again and drawn.
@MainActor
@Suite(.serialized)
struct LateCardsTests {
    let bench: Bench

    /// On artboard A: "R", a rectangle with three fills, two borders, two shadows and a blur, and
    /// "S", one with a fill alone.
    init() {
        var r = CanvasTests.rect("R", CGRect(x: 40, y: 40, width: 120, height: 80))
        r.fill = Fill(color: AnimateLooksTests.red)
        r.add(Presets.overlay)
        r.add(Fill(color: AnimateLooksTests.blue))
        r.border = Border(on: true, color: .black, width: 2)
        r.add(Border(on: true, color: AnimateLooksTests.green, width: 1))
        r.shadow = Shadow(on: true, color: RGBA(r: 0, g: 0, b: 0, a: 0.4), x: 0, y: 4, blur: 8)
        r.add(Presets.shadow(besides: r.shadow))
        Presets.applyBlur(8, to: &r)
        var s = CanvasTests.rect("S", CGRect(x: 240, y: 180, width: 60, height: 40))
        s.fill = Fill(color: AnimateLooksTests.green)
        bench = Bench(extra: [r, s])
    }

    private func id(_ name: String) -> UUID { bench.node(name)!.id }

    /// A card as the panel holds it, drawn into a host that is in no window: how tall it comes.
    private func drawn(_ card: some View) -> CGFloat {
        let host = NSHostingView(rootView: card.frame(width: Inspector.card)
            .environment(MenuHost())
            .environment(GradientSession())
            .environment(bench.store))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Every look card the inspector has, for the selection as it is when each is asked for.
    private func cards(of inspector: SelectionInspector) -> [CGFloat] {
        [drawn(inspector.cornersCard(live: false)),
         drawn(inspector.opacityCard(live: false)),
         drawn(inspector.fillCard(slot: 0, removable: true, live: false)),
         drawn(inspector.fillCard(slot: 2, removable: true, live: false)),
         drawn(inspector.fillControls(blends: true, action: "Change Fill", suggest: true, slot: 1)),
         drawn(inspector.fillControls(blends: false, action: "Change Fill", suggest: true, slot: 0)),
         drawn(inspector.fillControls(blends: false, action: "Change Fill", suggest: true, slot: 1)),
         drawn(inspector.borderCard(slot: 0, lineOnly: false, removable: true, live: false)),
         drawn(inspector.borderCard(slot: 1, lineOnly: false, removable: true, live: false)),
         drawn(inspector.shadowCard(slot: 0, canInset: true, canSpread: true, live: false)),
         drawn(inspector.shadowCard(slot: 1, canInset: true, canSpread: true, live: false)),
         drawn(inspector.blurCard(canBlurBehind: true, live: false))]
    }

    @Test func everyLookCardIsNoCardOnceItsLayersAreLetGo() {
        bench.store.selection = [id("R")]
        let inspector = SelectionInspector(store: bench.store)
        #expect(cards(of: inspector).allSatisfy { $0 > 0 })
        // Let go of, as picking the camera in Animate or clicking the bare canvas does.
        bench.store.selection = []
        #expect(cards(of: inspector).allSatisfy { $0 == 0 })
        // What the dashed cards would offer: nothing, for no layers.
        #expect(inspector.addable(fill: true, border: true).isEmpty)
        // The 3D card reads no first layer: it is drawn, saying the layers it has differ.
        #expect(drawn(inspector.depthCard(live: false)) > 0)
    }

    @Test func everyLookCardIsNoCardOnceItsLayersAreDeleted() {
        bench.store.selection = [id("R"), id("S")]
        let inspector = SelectionInspector(store: bench.store)
        let ids = bench.store.selection
        // Taken away by someone else, or by an undo, with the selection still naming them.
        bench.step { bench.store.edit("Delete Layers") { doc in for id in ids { _ = doc.detach(id) } } }
        #expect(bench.store.selection == ids && bench.store.selectedNodes.isEmpty)
        #expect(cards(of: inspector).allSatisfy { $0 == 0 })
        #expect(drawn(inspector).isZero)
    }

    @Test func aCardForMoreLayersThanArePickedShowsThoseThatAre() {
        bench.store.selection = [id("R"), id("S")]
        let inspector = SelectionInspector(store: bench.store)
        #expect(cards(of: inspector).allSatisfy { $0 > 0 })
        // The third fill's card, made while R was picked, asked for once S alone is: S's.
        bench.store.selection = [id("S")]
        #expect(drawn(inspector.fillCard(slot: 2, removable: true, live: false)) > 0)
        #expect(cards(of: inspector).allSatisfy { $0 > 0 })
        // And for words, which have no corners, borders or shadows of their own.
        let word = Node(kind: .text, name: "Word", frame: CGRect(x: 40, y: 200, width: 120, height: 30))
        bench.step { bench.store.add(word, onto: bench.a.id) }
        bench.store.selection = [id("Word")]
        #expect(cards(of: inspector).allSatisfy { $0 > 0 })
    }

    /// The whole panel, drawn, as its piles' layers are deleted and let go.
    @Test func thePanelLetsGoOfItsPilesAsTheirLayersGo() {
        bench.store.selection = [id("R")]
        let host = NSHostingView(rootView: SelectionInspector(store: bench.store).frame(width: Inspector.width)
            .environment(MenuHost())
            .environment(GradientSession())
            .environment(bench.store))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 200)
        bench.step { bench.store.deleteSelection() }
        host.layoutSubtreeIfNeeded()
        host.display()
        #expect(host.fittingSize.height == 0)
        bench.undo.undo()
        bench.store.selection = [id("R")]
        host.layoutSubtreeIfNeeded()
        bench.store.selection = [id("S")]
        host.layoutSubtreeIfNeeded()
        bench.store.selection = []
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == 0)
    }

    // MARK: What the model is asked for late

    /// Where a dropped row goes, said so that two can be compared.
    private func said(_ destination: (parent: UUID?, index: Int, depth: Int)?) -> String {
        destination.map { "\($0.parent?.uuidString ?? "canvas") \($0.index) \($0.depth)" } ?? "nowhere"
    }

    /// The gap a row dragged in the layers list would go into, found while the list had more rows
    /// than it has once the line is drawn or the row let go (layers taken away by an undo or by
    /// someone else while the drag went on): the last gap there is now.
    @Test func aDropGapPastTheRowsThereAreNowIsTheLast() {
        let a = bench.a
        let rows = [ListedLayer(node: a, depth: 0, parent: nil)] + a.children.reversed().map { ListedLayer(node: $0, depth: 1, parent: a.id) }
        let drop = LayerDrop(doc: bench.store.doc, rows: rows, board: nil, isShut: { _ in false })
        let s = rows[1]
        #expect(said(drop.destination(for: s, spot: .gap(rows.count))) == "\(a.id.uuidString) 0 1")
        #expect(said(drop.destination(for: s, spot: .gap(40))) == said(drop.destination(for: s, spot: .gap(rows.count))))
        #expect(said(drop.destination(for: s, spot: .gap(-3))) == said(drop.destination(for: s, spot: .gap(0))))
    }

    /// A layer asked to go below the bottom (the AI server's -1, or a place counted among layers
    /// that have gone since) goes to the bottom, and one above the top on top.
    @Test func aLayerPutPastEitherEndGoesToThatEnd() {
        var doc = bench.store.doc
        let a = bench.a.id
        doc.attach(CanvasTests.rect("Under", CGRect(x: 110, y: 110, width: 10, height: 10)), to: a, at: -1)
        doc.attach(CanvasTests.rect("Over", CGRect(x: 110, y: 110, width: 10, height: 10)), to: a, at: 99)
        #expect(doc.node(a)?.children.map(\.name) == ["Under", "R", "S", "Over"])
        doc.attach(CanvasTests.rect("Loose", CGRect(x: 0, y: 0, width: 10, height: 10)), to: nil, at: -2)
        doc.insert(CanvasTests.rect("Lowest", CGRect(x: 0, y: 0, width: 10, height: 10)), at: NodePath(indices: [-1]))
        #expect(doc.nodes.prefix(2).map(\.name) == ["Lowest", "Loose"])
        doc.insert(CanvasTests.rect("Deep", CGRect(x: 0, y: 0, width: 10, height: 10)), at: NodePath(indices: [2, -5]))
        #expect(doc.node(a)?.children.first?.name == "Deep")
    }

    /// Animate's cards, those of the layers as they look at the playhead, once the camera is picked.
    @Test func animatesCardsAreNoCardsOnceTheCameraIsPicked() {
        let f = FilmBench([bench.node("R")!, bench.node("S")!])
        f.step { f.store.selection = [f.id("R")] }
        let inspector = SelectionInspector(store: f.store, filming: true)
        f.step { f.store.pickCamera() }
        #expect(f.store.lookedSelection.isEmpty)
        let host = { (card: AnyView) -> CGFloat in
            let host = NSHostingView(rootView: card.frame(width: Inspector.card).environment(MenuHost()).environment(GradientSession()).environment(f.store))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        #expect(host(AnyView(inspector.cornersCard(live: false))) == 0)
        #expect(host(AnyView(inspector.fillCard(slot: 1, removable: false, live: false))) == 0)
        #expect(host(AnyView(inspector.borderCard(slot: 0, lineOnly: false, removable: false, live: false))) == 0)
        #expect(host(AnyView(inspector.shadowCard(slot: 1, canInset: true, canSpread: true, live: false))) == 0)
        #expect(host(AnyView(inspector)) == 0)
    }
}
