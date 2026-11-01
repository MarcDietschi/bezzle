import Testing
import AppKit
@testable import Bezzle

/// Components: something designed once and used in many places, every copy changing with any
/// other, but for its words and pictures, where it lies, how big it is, how it is turned, and what
/// it keeps as its own.
@MainActor
struct ComponentTests {
    /// Artboard A holding a group "Button": a 120 × 40 rectangle "Shape" and the words "Button"
    /// in its middle, with a "Note" text far off on its own.
    private func bench() -> Bench {
        var shape = Node(kind: .rectangle, name: "Shape", frame: CGRect(x: 40, y: 40, width: 120, height: 40))
        shape.fill.color = RGBA(r: 0.2, g: 0.4, b: 1)
        shape.cornerRadius = 8
        var label = Node(kind: .text, name: "Label", frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        label.text = "Button"
        label.style?.size = 16
        label.style?.align = .center
        label.refit()
        label.frame.origin = CGPoint(x: 100 - label.frame.width / 2, y: 60 - label.frame.height / 2)
        var button = Node(kind: .group, name: "Button", frame: .zero)
        button.children = [shape, label]
        let bench = Bench(extra: [button])
        bench.step { bench.store.edit("Fit") { $0.fitGroups() } }
        return bench
    }

    /// A component made of "Button", and a second copy of it 100 points lower.
    private func two() -> (Bench, UUID, UUID) {
        let bench = bench()
        bench.store.selection = [bench.node("Button")!.id]
        bench.step { bench.store.makeComponent() }
        let first = bench.store.selection[0]
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 100)) }
        let second = bench.store.selection[0]
        return (bench, first, second)
    }

    private func layer(_ name: String, in copy: UUID, _ bench: Bench) -> Node? {
        bench.store.doc.node(copy)?.children.first { $0.name == name }
    }

    private func absolute(_ name: String, in copy: UUID, _ bench: Bench) -> CGRect? {
        layer(name, in: copy, bench).flatMap { bench.store.doc.absoluteFrame(of: $0.id) }
    }

    @Test func makingAComponentLeavesTheGroupAsItsFirstCopy() {
        let bench = bench()
        let id = bench.node("Button")!.id
        let before = bench.store.doc.absoluteFrame(of: id)
        bench.store.selection = [id]
        #expect(bench.store.canMakeComponent)
        bench.step { bench.store.makeComponent() }
        let doc = bench.store.doc
        #expect(doc.masters.count == 1)
        let copy = doc.node(id)!
        #expect(copy.isCopy)
        #expect(copy.instance?.of == doc.masters[0].id)
        #expect(doc.absoluteFrame(of: id) == before)
        // Every layer of the copy is the component's mixed with the copy's key.
        let k = Components.key(of: copy)!
        #expect(copy.children.map { $0.id.mixed(k) } == doc.masters[0].children.map(\.id))
        #expect(!bench.store.canMakeComponent)
    }

    @Test func aChangeToOneCopyIsMadeInEveryCopy() {
        let (bench, first, second) = two()
        let shape = layer("Shape", in: second, bench)!
        let red = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = red } }
        #expect(layer("Shape", in: first, bench)?.fill.color == red)
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        #expect(Components.layers(of: bench.store.doc.masters[0], variant: nil).first { $0.name == "Shape" }?.fill.color == red)
        // Where the copies are is their own.
        #expect(absolute("Shape", in: second, bench)!.minY - absolute("Shape", in: first, bench)!.minY == 100)
        bench.undoLast()
        #expect(layer("Shape", in: first, bench)?.fill.color != red)
    }

    @Test func theWordsOfACopyAreItsOwnAndItsShapeGrowsRoundThem() {
        let (bench, first, second) = two()
        let label = layer("Label", in: second, bench)!
        let shapeBefore = absolute("Shape", in: second, bench)!
        bench.step { bench.store.update([label.id], "Type") { $0.text = "Continue to checkout" } }
        #expect(layer("Label", in: first, bench)?.text == "Button")
        #expect(layer("Label", in: second, bench)?.text == "Continue to checkout")
        let shape = absolute("Shape", in: second, bench)!, words = absolute("Label", in: second, bench)!
        #expect(shape.width > shapeBefore.width + 40)
        // The shape keeps as much room round the words as before, and the words stay in its middle.
        #expect(abs(shape.midX - words.midX) < 0.6)
        #expect(abs(shape.midX - shapeBefore.midX) < 0.6)
        #expect(absolute("Shape", in: first, bench)!.width == 120)
        // A change to the look after that keeps the words.
        let shapeID = layer("Shape", in: first, bench)!.id
        bench.step { bench.store.update([shapeID], "Corners") { $0.cornerRadius = 20 } }
        #expect(layer("Label", in: second, bench)?.text == "Continue to checkout")
        #expect(layer("Shape", in: second, bench)?.cornerRadius == 20)
    }

    @Test func aCopyResizedWholeStretchesWhatSpansItAndKeepsItsMiddle() {
        let (bench, first, second) = two()
        let copy = bench.store.doc.node(second)!
        bench.step {
            bench.store.edit("Resize") { doc in
                doc.update(second) { n in
                    let old = n.frame.size
                    n.frame.size = CGSize(width: 300, height: 40)
                    n.children = BezzleDocument.scaled(n.children, from: old, to: n.frame.size)
                }
            }
        }
        let shape = absolute("Shape", in: second, bench)!, words = absolute("Label", in: second, bench)!
        #expect(abs(shape.width - 300) < 0.6)
        #expect(abs(words.width - absolute("Label", in: first, bench)!.width) < 0.6)
        #expect(abs(words.midX - shape.midX) < 0.6)
        #expect(layer("Label", in: second, bench)?.style?.size == 16)
        // The component and the other copy stay as they were.
        #expect(absolute("Shape", in: first, bench)!.width == 120)
        #expect(Components.box(of: bench.store.doc.masters[0], variant: nil).width == 120)
        #expect(bench.store.doc.node(second)?.instance?.box.width == 300)
        // A change in the narrow copy reaches the wide one, which stays wide.
        let shapeID = layer("Shape", in: first, bench)!.id
        bench.step { bench.store.update([shapeID], "Corners") { $0.cornerRadius = 4 } }
        #expect(layer("Shape", in: second, bench)?.cornerRadius == 4)
        #expect(abs(absolute("Shape", in: second, bench)!.width - 300) < 0.6)
        _ = copy
    }

    @Test func aLayerMovedInOneCopyMovesInEveryCopy() {
        let (bench, first, second) = two()
        let label = layer("Label", in: first, bench)!
        bench.step { bench.store.update([label.id], "Move") { $0.frame.origin.y -= 6 } }
        let a = absolute("Label", in: first, bench)!, b = absolute("Label", in: second, bench)!
        #expect(abs((b.minY - a.minY) - 100) < 0.01)
        #expect(abs(a.minX - b.minX) < 0.01)
    }

    @Test func aCopyTurnedWholeKeepsItsTurnAndFollowsTheComponent() {
        let (bench, first, second) = two()
        bench.step {
            bench.store.edit("Rotate") { doc in
                let c = doc.node(second)!
                doc.update(second) { $0 = BezzleDocument.turned($0, by: 30, about: c.frame.center) }
            }
        }
        #expect(bench.store.doc.node(second)?.instance?.turn == 30)
        #expect(layer("Shape", in: first, bench)?.rotation == 0)
        let shapeID = layer("Shape", in: first, bench)!.id
        let red = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.update([shapeID], "Fill") { $0.fill.color = red } }
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        #expect(abs((layer("Shape", in: second, bench)?.rotation ?? 0) - 30) < 0.001)
        #expect(abs((layer("Label", in: second, bench)?.rotation ?? 0) - 30) < 0.001)
    }

    @Test func aCopyFlippedWholeKeepsItsFlip() {
        let (bench, first, second) = two()
        // Its words to the left, so it shows which way it faces.
        let label = layer("Label", in: first, bench)!
        bench.step { bench.store.update([label.id], "Move") { $0.frame.origin.x -= 30 } }
        bench.store.selection = [second]
        bench.step { bench.store.flip(horizontally: true) }
        #expect(absolute("Label", in: second, bench)!.midX > absolute("Shape", in: second, bench)!.midX + 20)
        #expect(absolute("Label", in: first, bench)!.midX < absolute("Shape", in: first, bench)!.midX - 20)
        #expect(bench.store.doc.node(second)?.instance?.flipX == true)
        let shapeID = layer("Shape", in: first, bench)!.id
        bench.step { bench.store.update([shapeID], "Corners") { $0.cornerRadius = 12 } }
        #expect(bench.store.doc.node(second)?.instance?.flipX == true)
        #expect(layer("Shape", in: second, bench)?.cornerRadius == 12)
    }

    @Test func keepingAChangeInOneCopyPutsTheOthersBack() {
        let (bench, first, second) = two()
        let shape = layer("Shape", in: second, bench)!
        let red = RGBA(r: 1, g: 0, b: 0), blue = layer("Shape", in: first, bench)!.fill.color
        bench.store.selection = [shape.id]
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = red } }
        guard let offer = bench.store.componentOffer else {
            Issue.record("No offer after a change that every copy followed")
            return
        }
        #expect(offer.buttons.map(\.action) == [.onlyHere, .newVariant])
        bench.step { bench.store.take(offer, .onlyHere) }
        #expect(layer("Shape", in: first, bench)?.fill.color == blue)
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        #expect(layer("Shape", in: second, bench)?.own == ["fill"])
        // What it keeps, it keeps when the others change; the rest follows.
        let firstShape = layer("Shape", in: first, bench)!.id
        bench.step { bench.store.update([firstShape], "Corners") { $0.cornerRadius = 2 } }
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        #expect(layer("Shape", in: second, bench)?.cornerRadius == 2)
        bench.step { bench.store.resetCopy(second) }
        #expect(layer("Shape", in: second, bench)?.fill.color == blue)
    }

    @Test func aVariantKeepsWhatItWasMadeWithAndFollowsTheRest() {
        let (bench, first, second) = two()
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 100)) }
        let third = bench.store.selection[0]
        let shape = layer("Shape", in: second, bench)!
        let red = RGBA(r: 1, g: 0, b: 0), blue = layer("Shape", in: first, bench)!.fill.color
        bench.store.selection = [shape.id]
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = red } }
        let offer = bench.store.componentOffer!
        bench.step { bench.store.take(offer, .newVariant) }
        let master = bench.store.doc.masters[0]
        #expect(master.master?.variants.count == 1)
        let v = master.master!.variants[0]
        #expect(bench.store.doc.node(second)?.instance?.variant == v)
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        #expect(layer("Shape", in: first, bench)?.fill.color == blue)
        #expect(layer("Shape", in: third, bench)?.fill.color == blue)
        // Its words stay its own, its colour the variant's, and a change to what all share reaches all.
        let firstShape = layer("Shape", in: first, bench)!.id
        bench.step { bench.store.update([firstShape], "Corners") { $0.cornerRadius = 18 } }
        #expect(layer("Shape", in: second, bench)?.cornerRadius == 18)
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        // Another copy shown as the variant is red too.
        bench.step { bench.store.setVariant(v, for: [third]) }
        #expect(layer("Shape", in: third, bench)?.fill.color == red)
        // Recoloured in the variant, every copy of the variant follows, and no other.
        let green = RGBA(r: 0, g: 1, b: 0)
        let thirdShape = layer("Shape", in: third, bench)!.id
        bench.step { bench.store.update([thirdShape], "Fill") { $0.fill.color = green } }
        #expect(layer("Shape", in: second, bench)?.fill.color == green)
        #expect(layer("Shape", in: first, bench)?.fill.color == blue)
        bench.step { bench.store.setVariant(nil, for: [third]) }
        #expect(layer("Shape", in: third, bench)?.fill.color == blue)
    }

    @Test func aNewVariantTakesWhatIsChangedFirstAsItsOwn() {
        let (bench, first, second) = two()
        bench.store.selection = [second]
        bench.step { bench.store.addVariant() }
        let v = bench.store.doc.masters[0].master!.variants[0]
        #expect(bench.store.doc.node(second)?.instance?.variant == v)
        let shape = layer("Shape", in: second, bench)!
        let red = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = red } }
        #expect(layer("Shape", in: second, bench)?.fill.color == red)
        #expect(layer("Shape", in: first, bench)?.fill.color != red)
    }

    @Test func aGroupThatLooksTheSameIsLinked() {
        let bench = bench()
        let button = bench.node("Button")!.id
        bench.store.selection = [button]
        // A plain duplicate first, as a part dropped twice from a kit was before.
        bench.step { bench.store.edit("Duplicate") { doc in _ = DocumentStore.duplicate([button], in: &doc, offset: CGPoint(x: 0, y: 100)) } }
        let other = bench.store.doc.nodes[0].children.last!.id
        bench.step { bench.store.update([bench.store.doc.node(other)!.children[1].id], "Type") { $0.text = "Cancel" } }
        bench.store.selection = [button]
        bench.step { bench.store.makeComponent() }
        guard let offer = bench.store.componentOffer, case .lookAlikes(_, let found) = offer.kind else {
            Issue.record("No look-alikes offered")
            return
        }
        #expect(found == [other])
        bench.step { bench.store.take(offer, .link) }
        let copies = bench.store.doc.copies(of: bench.store.doc.masters[0].id)
        #expect(copies.count == 2)
        #expect(copies.compactMap { $0.children.first { $0.kind == .text }?.text }.sorted() == ["Button", "Cancel"])
        let shape = copies[0].children[0].id
        let red = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.update([shape], "Fill") { $0.fill.color = red } }
        let colors = bench.store.doc.copies(of: bench.store.doc.masters[0].id).map { $0.children[0].fill.color }
        #expect(colors.allSatisfy { $0 == red })
    }

    @Test func unlinkingAndDeletingTheComponentLeaveGroups() {
        let (bench, first, second) = two()
        bench.store.selection = [first]
        bench.step { bench.store.unlinkComponent() }
        #expect(bench.store.doc.node(first)?.isCopy == false)
        let shape = layer("Shape", in: first, bench)!
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0) } }
        #expect(layer("Shape", in: second, bench)?.fill.color != RGBA(r: 1, g: 0, b: 0))
        bench.step { bench.store.deleteComponent(bench.store.doc.masters[0].id) }
        #expect(bench.store.doc.masters.isEmpty)
        #expect(bench.store.doc.node(second)?.isCopy == false)
        #expect(layer("Label", in: second, bench)?.text == "Button")
    }

    @Test func aDesignSharedKeepsItsComponents() {
        let (bench, _, second) = two()
        let doc = bench.store.doc
        let again = FlatDesign(doc).document()
        #expect(again.masters == doc.masters)
        #expect(again.nodes == doc.nodes)
        // A copy whose component someone else took away is a group like any other.
        var flat = FlatDesign(doc)
        flat.entries[doc.masters[0].id] = nil
        flat.order[nil]?.removeAll { $0 == doc.masters[0].id }
        let without = flat.document()
        #expect(without.node(second)?.isCopy == false)
        // Undone after someone else's change, only what this Mac did is taken back.
        let other = FlatDesign.apply(from: doc, to: doc, onto: doc)
        #expect(other == doc)
    }

    @Test func aCopyPastedIntoAnotherDesignBringsItsComponent() {
        let (bench, _, second) = two()
        bench.store.selection = [second]
        bench.store.copySelection()
        let other = Bench()
        other.step { other.store.paste() }
        #expect(other.store.doc.masters.map(\.id) == bench.store.doc.masters.map(\.id))
        let pasted = other.store.doc.node(other.store.selection[0])!
        #expect(pasted.isCopy)
        let shape = pasted.children[0].id
        other.step { other.store.update([shape], "Fill") { $0.fill.color = RGBA(r: 0, g: 1, b: 0) } }
        #expect(other.store.doc.masters[0].children[0].fill.color == RGBA(r: 0, g: 1, b: 0))
    }

    @Test func copiesInARepeatGridAreCopiesToo() {
        let (bench, first, _) = two()
        bench.store.selection = [first]
        bench.step { bench.store.makeRepeatGrid() }
        guard let grid = bench.store.doc.allNodes.first(where: \.isRepeatGrid) else {
            Issue.record("No grid")
            return
        }
        bench.step { bench.store.edit("Columns") { doc in doc.update(grid.id) { $0.grid?.columns = 3 } } }
        let cells = bench.store.doc.node(grid.id)!.children
        #expect(cells.count == 3)
        #expect(cells.filter(\.isCopy).count == 3)
        let shape = cells[2].children[0].id
        let red = RGBA(r: 1, g: 0, b: 0)
        bench.step { bench.store.update([shape], "Fill") { $0.fill.color = red } }
        let colors = bench.store.doc.copies(of: bench.store.doc.masters[0].id).map { $0.children[0].fill.color }
        #expect(colors.allSatisfy { $0 == red })
    }

    @Test func whatIsChangedInAVariantStaysInIt() {
        let (bench, first, second) = two()
        bench.store.selection = [second]
        bench.step { bench.store.addVariant() }
        let shape = layer("Shape", in: second, bench)!, label = layer("Label", in: second, bench)!
        let light = RGBA(r: 0.95, g: 0.94, b: 0.9), ink = RGBA(r: 0.1, g: 0.1, b: 0.1)
        let blue = layer("Shape", in: first, bench)!.fill.color, white = layer("Label", in: first, bench)!.fill.color
        bench.store.selection = [shape.id]
        bench.step { bench.store.update([shape.id], "Fill") { $0.fill.color = light } }
        bench.store.selection = [label.id]
        bench.step { bench.store.update([label.id], "Colour") { $0.fill.color = ink } }
        #expect(layer("Shape", in: second, bench)?.fill.color == light)
        #expect(layer("Label", in: second, bench)?.fill.color == ink)
        #expect(layer("Shape", in: first, bench)?.fill.color == blue)
        #expect(layer("Label", in: first, bench)?.fill.color == white)
        // Offered to every variant, and taken, the first has it too.
        guard let offer = bench.store.componentOffer else {
            Issue.record("Nothing offered after a change in a variant")
            return
        }
        #expect(offer.buttons.map(\.action).contains(.allVariants))
        bench.step { bench.store.take(offer, .allVariants) }
        #expect(layer("Label", in: first, bench)?.fill.color == ink)
        #expect(layer("Shape", in: first, bench)?.fill.color == blue)
        // A change in a copy of the first variant still reaches the other, but for what it keeps.
        let firstShape = layer("Shape", in: first, bench)!.id
        bench.step { bench.store.update([firstShape], "Corners") { $0.cornerRadius = 3 } }
        #expect(layer("Shape", in: second, bench)?.cornerRadius == 3)
        #expect(layer("Shape", in: second, bench)?.fill.color == light)
    }

    @Test func wordsDeepInACopyGrowItWhereItsGroupsStretch() {
        let bench = bench()
        // As a kit's parts are made: the part a group round one group of its layers.
        let button = bench.node("Button")!.id
        bench.store.selection = [button]
        bench.step { bench.store.group() }
        let outer = bench.store.selection[0]
        bench.store.selection = [outer]
        bench.step { bench.store.makeComponent() }
        bench.step { bench.store.duplicateSelection(offset: CGPoint(x: 0, y: 100)) }
        let second = bench.store.selection[0]
        func inner(_ name: String) -> Node? { bench.store.doc.node(second)?.children.first?.children.first { $0.name == name } }
        let before = bench.store.doc.absoluteFrame(of: inner("Shape")!.id)!
        bench.step { bench.store.update([inner("Label")!.id], "Type") { $0.text = "A much longer label" } }
        let shape = bench.store.doc.absoluteFrame(of: inner("Shape")!.id)!, words = bench.store.doc.absoluteFrame(of: inner("Label")!.id)!
        #expect(shape.width > before.width + 40)
        #expect(abs(shape.midX - words.midX) < 0.6)
    }

    @Test func aKitPartDroppedAgainIsAnotherCopy() {
        let bench = Bench()
        bench.store.selection = []
        let a = bench.a.id
        var first: UUID?, second: UUID?
        bench.step { first = bench.store.place(.component("bezzle.primary-button"), at: CGPoint(x: 200, y: 200)) }
        bench.step { second = bench.store.place(.component("bezzle.primary-button"), at: CGPoint(x: 200, y: 300)) }
        guard let first, let second else {
            Issue.record("Nothing placed")
            return
        }
        #expect(bench.store.doc.masters.count == 1)
        #expect(bench.store.doc.node(first)?.isCopy == true)
        #expect(bench.store.doc.node(second)?.instance?.of == bench.store.doc.node(first)?.instance?.of)
        #expect(bench.store.doc.parent(of: second)?.id == a)
        // On a dark artboard the part is another component: it was made otherwise.
        bench.step { bench.store.update([bench.b.id], "Fill") { $0.fill.color = RGBA(r: 0.05, g: 0.05, b: 0.05) } }
        bench.step { _ = bench.store.place(.component("bezzle.primary-button"), at: CGPoint(x: 800, y: 200)) }
        #expect(bench.store.doc.masters.count == 2)
        // Dragged in from the design's own, another copy too.
        let master = bench.store.doc.masters[0].id
        var third: UUID?
        bench.step { third = bench.store.place(.design(master), at: CGPoint(x: 300, y: 250)) }
        #expect(third.flatMap { bench.store.doc.node($0)?.instance?.of } == master)
    }

    @Test func aCopyPulledWiderByItsHandleStretchesAndTheOthersStay() {
        let (bench, first, second) = two()
        let start = bench.store.doc.absoluteFrame(of: second)!
        bench.click(CGPoint(x: start.minX + 8, y: start.minY + 4))
        #expect(bench.store.selection == [second])
        bench.drag(CGPoint(x: start.maxX, y: start.midY), CGPoint(x: start.maxX + 100, y: start.midY), flags: .command)
        let shape = absolute("Shape", in: second, bench)!, words = absolute("Label", in: second, bench)!
        #expect(abs(shape.width - (start.width + 100)) < 1, "\(start) → shape \(shape), words \(words), copy \(String(describing: bench.store.doc.absoluteFrame(of: second))), box \(String(describing: bench.store.doc.node(second)?.instance?.box)), selection \(bench.store.selection == [second])")
        #expect(abs(shape.minX - start.minX) < 1)
        #expect(abs(words.midX - shape.midX) < 0.6)
        #expect(layer("Label", in: second, bench)?.style?.size == 16)
        #expect(abs(absolute("Shape", in: first, bench)!.width - 120) < 0.01)
        #expect(Components.box(of: bench.store.doc.masters[0], variant: nil).width == 120)
        // One step to undo.
        bench.undoLast()
        #expect(abs(absolute("Shape", in: second, bench)!.width - 120) < 0.01)
    }

    @Test func typingInACopyKeepsTheWordsInItAndGrowsIt() {
        let (bench, first, second) = two()
        let label = layer("Label", in: second, bench)!.id
        bench.store.selection = [label]
        bench.step { bench.canvas.beginEditing(label, action: "Typing") }
        guard let editor = bench.editor else {
            Issue.record("No editor")
            return
        }
        editor.insertText(" now, please", replacementRange: NSRange(location: 6, length: 0))
        bench.step { bench.canvas.endEditing() }
        #expect(layer("Label", in: second, bench)?.text == "Button now, please")
        #expect(layer("Label", in: first, bench)?.text == "Button")
        let shape = absolute("Shape", in: second, bench)!, words = absolute("Label", in: second, bench)!
        #expect(shape.width > 150)
        #expect(abs(words.midX - shape.midX) < 0.6)
        #expect(absolute("Shape", in: first, bench)!.width == 120)
        if let offer = bench.store.componentOffer {
            #expect(offer.buttons.map(\.action) == [.everywhere])
            bench.step { bench.store.take(offer, .everywhere) }
            #expect(layer("Label", in: first, bench)?.text == "Button now, please")
        }
    }

    @Test func pinsFollowWhereLayersLie() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 60)
        var bar = Node(kind: .rectangle, frame: box)
        bar.name = "Bar"
        let p = Pinning.infer(bar, in: box)
        #expect(p == Pins(x: .stretch, y: .stretch))
        let icon = Node(kind: .rectangle, frame: CGRect(x: 268, y: 18, width: 24, height: 24))
        #expect(Pinning.infer(icon, in: box) == Pins(x: .end, y: .middle))
        let tab = Node(kind: .rectangle, frame: CGRect(x: 100, y: 10, width: 20, height: 20))
        #expect(Pinning.infer(tab, in: box).x == .spread)
        var words = Node(kind: .text, frame: CGRect(x: 12, y: 20, width: 200, height: 20))
        words.text = "A long title"
        #expect(Pinning.infer(words, in: box).x == .start)
    }
}
