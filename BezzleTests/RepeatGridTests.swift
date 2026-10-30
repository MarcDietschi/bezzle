import Testing
import AppKit
@testable import Bezzle

/// Repeat grids: one layer repeated in rows and columns, every cell changing with any other, but
/// for the words and pictures each holds.
@MainActor
struct RepeatGridTests {
    /// A card on artboard A: a 60 × 40 rectangle "Back" at 10,10 and a text "Title" on it.
    private func cardBench() -> (Bench, UUID) {
        var back = Node(kind: .rectangle, name: "Back", frame: CGRect(x: 10, y: 10, width: 60, height: 40))
        back.fill.color = RGBA(r: 1, g: 1, b: 1)
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 16, y: 16, width: 0, height: 0))
        title.text = "Item 1"
        title.style?.size = 10
        title.refit()
        let bench = Bench(extra: [back, title])
        bench.store.selection = [back.id, title.id]
        bench.step { bench.store.makeRepeatGrid() }
        return (bench, bench.store.selection[0])
    }

    private func grid(_ bench: Bench, _ id: UUID) -> Node { bench.store.node(id)! }

    /// The layers named so, in every cell, as they are read.
    private func all(_ name: String, in bench: Bench, _ id: UUID) -> [Node] {
        let g = grid(bench, id)
        guard let layout = RepeatGrid.layout(of: g) else { return [] }
        func find(_ n: Node) -> Node? { n.name == name ? n : n.children.lazy.compactMap(find).first }
        guard let slot = find(g.children[layout.first]) else { return [] }
        return bench.store.copies(of: slot.id, in: g).compactMap { bench.store.node($0) }
    }

    private func absolute(_ bench: Bench, _ n: Node) -> CGRect { bench.store.doc.absoluteFrame(of: n.id)! }

    @Test func keysSayWhichCellTheyAre() {
        #expect(RepeatGrid.key(.first) == .none)
        for cell in [RepeatGrid.Cell(column: 1, row: 0), RepeatGrid.Cell(column: 0, row: 7), RepeatGrid.Cell(column: 99, row: 99)] {
            let key = RepeatGrid.key(cell)
            #expect(RepeatGrid.cell(of: key) == cell)
            let id = UUID()
            #expect(id.mixed(key) != id)
            #expect(id.mixed(key).mixed(key) == id)
            #expect(id.mixed(key).key(from: id) == key)
        }
        // Two ids of nothing to do with each other are no cell of each other.
        #expect(RepeatGrid.cell(of: UUID().key(from: UUID())) == nil)
    }

    @Test func aGridIsTheSelectionInOneCell() {
        let (bench, id) = cardBench()
        let g = grid(bench, id)
        #expect(g.isRepeatGrid && g.grid?.count == 1)
        #expect(g.children.count == 1 && g.children[0].isGroup && g.children[0].children.map(\.name) == ["Back", "Title"])
        // Nothing moved on the canvas.
        #expect(absolute(bench, all("Back", in: bench, id)[0]) == CGRect(x: 110, y: 110, width: 60, height: 40))
        #expect(g.grid?.columnGap == RepeatGrid.gap(for: CGSize(width: 60, height: 40)))
    }

    @Test func moreColumnsAndRowsAreCopiesAStepApart() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3; $0.rows = 2; $0.columnGap = 10; $0.rowGap = 6 } }
        let backs = all("Back", in: bench, id)
        #expect(backs.count == 6)
        #expect(backs.map { absolute(bench, $0).origin } == [
            CGPoint(x: 110, y: 110), CGPoint(x: 180, y: 110), CGPoint(x: 250, y: 110),
            CGPoint(x: 110, y: 156), CGPoint(x: 180, y: 156), CGPoint(x: 250, y: 156),
        ])
        #expect(grid(bench, id).frame == CGRect(x: 10, y: 10, width: 200, height: 86))
        // Fewer again: the ones past the edge go.
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 1 } }
        #expect(all("Back", in: bench, id).count == 2)
    }

    @Test func aChangeInAnyCellIsAChangeInAll() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3; $0.rows = 2 } }
        let third = all("Back", in: bench, id)[2]
        bench.store.selection = [third.id]
        bench.step { bench.store.updateSelection("Change Fill") { $0.fill.color = RGBA(r: 1, g: 0, b: 0); $0.cornerRadius = 6 } }
        #expect(all("Back", in: bench, id).allSatisfy { $0.fill.color == RGBA(r: 1, g: 0, b: 0) && $0.cornerRadius == 6 })
        // Moved in one cell, it moves in every one, the same way in its cell.
        let fifth = all("Title", in: bench, id)[4]
        let before = all("Title", in: bench, id).map { absolute(bench, $0) }
        bench.store.selection = [fifth.id]
        bench.step { bench.store.nudge(dx: 0, dy: 5) }
        let after = all("Title", in: bench, id).map { absolute(bench, $0) }
        #expect(zip(before, after).allSatisfy { $1 == $0.offsetBy(dx: 0, dy: 5) })
        // One step undoes it, in every cell.
        bench.undo.undo()
        #expect(all("Title", in: bench, id).map { absolute(bench, $0) } == before)
    }

    @Test func wordsAndPicturesAreEachCellsOwn() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 2; $0.rows = 2 } }
        let titles = all("Title", in: bench, id)
        bench.step { bench.store.edit("Typing") { doc in doc.update(titles[3].id) { $0.text = "Last one"; $0.refit() } } }
        #expect(all("Title", in: bench, id).map(\.text) == ["Item 1", "Item 1", "Item 1", "Last one"])
        // A style changed in another cell keeps what each says.
        bench.store.selection = [titles[1].id]
        bench.step { bench.store.updateSelection("Change Size") { $0.style?.size = 14 } }
        let changed = all("Title", in: bench, id)
        #expect(changed.map(\.text) == ["Item 1", "Item 1", "Item 1", "Last one"])
        #expect(changed.allSatisfy { $0.style?.size == 14 })
        // Each one is as wide as its own words.
        #expect(changed[3].frame.width > changed[0].frame.width)
        #expect(Set(changed.map { $0.frame.width }).count == 2)
    }

    @Test func newCellsCountOnOrRepeat() {
        let (bench, id) = cardBench()
        let slot = all("Title", in: bench, id)[0].id
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3 } }
        bench.step { bench.store.fill(slot, in: id, with: ["Item 1", "Item 2", "Item 3"]) }
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.rows = 2 } }
        #expect(all("Title", in: bench, id).map(\.text) == ["Item 1", "Item 2", "Item 3", "Item 4", "Item 5", "Item 6"])
        bench.step { bench.store.fill(slot, in: id, with: ["Oslo", "Bern"]) }
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 4 } }
        // The new column takes what the cells there were hold, in the order they are read.
        #expect(all("Title", in: bench, id).map(\.text) == ["Oslo", "Bern", "Oslo", "Oslo", "Bern", "Oslo", "Bern", "Bern"])
        #expect(Series.continuing(["07", "08"], count: 2) == ["09", "10"])
        #expect(Series.continuing(["No. 2", "No. 4"], count: 1) == ["No. 6"])
        #expect(Series.continuing(["$49"], count: 2) == ["$49", "$49"])
    }

    @Test func aLayerPutIntoOneCellIsPutIntoAll() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 2 } }
        let second = grid(bench, id).children[1]
        var badge = Node(kind: .ellipse, name: "Badge", frame: CGRect(x: 50, y: 0, width: 8, height: 8))
        badge.id = UUID()
        bench.step { bench.store.edit("Add") { doc in doc.update(second.id) { $0.children.append(badge) } } }
        let badges = all("Badge", in: bench, id)
        #expect(badges.count == 2)
        // It keeps its own id, in the cell it was put in.
        #expect(badges.contains { $0.id == badge.id })
        #expect(absolute(bench, badges[1]).minX - absolute(bench, badges[0]).minX == absolute(bench, all("Back", in: bench, id)[1]).minX - 110)
        // Taken out of one, it goes from all of them.
        bench.store.selection = [badges[0].id]
        bench.step { bench.store.deleteSelection() }
        #expect(all("Badge", in: bench, id).isEmpty)
        #expect(all("Back", in: bench, id).count == 2)
    }

    @Test func takingACellAwayTakesTheGrid() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 2 } }
        bench.store.selection = [grid(bench, id).children[1].id]
        bench.step { bench.store.deleteSelection() }
        #expect(bench.store.node(id) == nil)
    }

    @Test func aDuplicateKeepsWhatEachCellHolds() {
        let (bench, id) = cardBench()
        let slot = all("Title", in: bench, id)[0].id
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3 } }
        bench.step { bench.store.fill(slot, in: id, with: ["A", "B", "C"]) }
        bench.store.selection = [id]
        bench.step { bench.store.duplicateSelection() }
        let copy = bench.store.selection[0]
        #expect(copy != id)
        #expect(all("Title", in: bench, copy).map(\.text) == ["A", "B", "C"])
        // Still a grid whose cells follow the first.
        bench.step { bench.store.changeGrid(copy, "Repeat") { $0.rows = 2 } }
        #expect(all("Title", in: bench, copy).map(\.text) == ["A", "B", "C", "A", "B", "C"])
        #expect(all("Title", in: bench, id).map(\.text) == ["A", "B", "C"])
    }

    @Test func aGridPutTogetherFromChangesHasAllItsCells() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3 } }
        // As if the change that made the last cell had not come yet, and a stray layer had.
        var flat = FlatDesign(bench.store.doc)
        let last = grid(bench, id).children[2]
        flat.entries[last.id] = nil
        for c in last.children { flat.entries[c.id] = nil }
        flat.order[id]?.removeAll { $0 == last.id }
        let built = flat.document()
        let g = built.node(id)!
        #expect(g.children.count == 3)
        #expect(g.children.map(\.id) == grid(bench, id).children.map(\.id))
        // A design that is whole comes back the same.
        #expect(FlatDesign(bench.store.doc).document().nodes == bench.store.doc.nodes)
    }

    @Test func dataGoesToTheTextLayerOfItsName() {
        var price = Node(kind: .text, name: "Price", frame: CGRect(x: 10, y: 60, width: 0, height: 0))
        price.text = "0"
        price.refit()
        let (bench, id) = cardBench()
        let first = grid(bench, id).children[0]
        bench.step { bench.store.edit("Add") { doc in doc.update(first.id) { $0.children.append(price) } } }
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 2 } }
        var filled = 0
        bench.step { filled = bench.store.fill(id, from: "price,title\n\"1,50\",Tea\n3,Coffee\n") }
        #expect(filled == 2)
        #expect(all("Title", in: bench, id).map(\.text) == ["Tea", "Coffee"])
        #expect(all("Price", in: bench, id).map(\.text) == ["1,50", "3"])
    }

    /// A grid of one 40 × 40 tile at 110,110 on the canvas, 10 apart, selected.
    private func tileBench() -> (Bench, UUID) {
        let tile = Node(kind: .rectangle, name: "Tile", frame: CGRect(x: 10, y: 10, width: 40, height: 40))
        let bench = Bench(extra: [tile])
        bench.store.selection = [tile.id]
        bench.step { bench.store.makeRepeatGrid() }
        let id = bench.store.selection[0]
        bench.step { bench.store.changeGrid(id, "Gap") { $0.columnGap = 10; $0.rowGap = 10 } }
        return (bench, id)
    }

    @Test func pullingTheHandlesAddsColumnsAndRows() {
        let (bench, id) = tileBench()
        // The right edge's handle, pulled past the middle of a third tile, makes three columns.
        bench.drag(CGPoint(x: 150, y: 130), CGPoint(x: 236, y: 130))
        #expect(grid(bench, id).grid?.columns == 3 && grid(bench, id).grid?.rows == 1)
        #expect(grid(bench, id).children.count == 3)
        // The corner pulls both.
        bench.drag(CGPoint(x: 250, y: 150), CGPoint(x: 260, y: 236))
        #expect(grid(bench, id).grid?.columns == 3 && grid(bench, id).grid?.rows == 3)
        #expect(all("Tile", in: bench, id).count == 9)
        // One step undoes a pull.
        bench.undo.undo()
        #expect(grid(bench, id).grid?.rows == 1 && all("Tile", in: bench, id).count == 3)
    }

    @Test func draggingAGapSpacesTheCellsUnderThePointer() {
        let (bench, id) = tileBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3 } }
        // Between the second tile and the third, 200…210; the third follows the pointer.
        bench.drag(CGPoint(x: 205, y: 130), CGPoint(x: 225, y: 130))
        #expect(grid(bench, id).grid?.columnGap == 20)
        #expect(absolute(bench, all("Tile", in: bench, id)[2]).minX == 230)
        #expect(grid(bench, id).grid?.rowGap == 10)
    }

    @Test func aClickInAnotherCellPicksTheSameLayerThere() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3; $0.columnGap = 10 } }
        let titles = all("Title", in: bench, id)
        bench.store.selection = [titles[0].id]
        let third = absolute(bench, titles[2])
        bench.drag(CGPoint(x: third.midX, y: third.midY), CGPoint(x: third.midX, y: third.midY))
        #expect(bench.store.selection == [titles[2].id])
    }

    @Test func theAssistantMakesAndFillsGrids() async {
        var title = Node(kind: .text, name: "Title", frame: CGRect(x: 10, y: 10, width: 0, height: 0))
        title.text = "x"
        title.refit()
        let bench = Bench(extra: [Node(kind: .rectangle, name: "Back", frame: CGRect(x: 0, y: 0, width: 60, height: 40)), title])
        let tools = MCPTools()
        MCPTools.opened(bench.store)
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            var arguments = arguments
            arguments["design"] = bench.store.name
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        let made = await call("repeat_grid", ["layers": ["Back", "Title"], "columns": 3, "rows": 2, "column_gap": 8])
        #expect(!made.failed, "\(made.text)")
        guard let id = bench.store.doc.allNodes.first(where: \.isRepeatGrid)?.id else { Issue.record("No grid"); return }
        #expect(grid(bench, id).grid == RepeatGrid(columns: 3, rows: 2, columnGap: 8, rowGap: 4))
        // "Title" is the first cell's, though every cell has one.
        let filled = await call("fill_repeat_grid", ["layer": "Title", "values": ["A", "B", "C", "D", "E", "F"]])
        #expect(!filled.failed, "\(filled.text)")
        #expect(all("Title", in: bench, id).map(\.text) == ["A", "B", "C", "D", "E", "F"])
        #expect(filled.text.contains("cellTexts"))
        let numbered = await call("fill_repeat_grid", ["layer": "Title", "sample": "numbers"])
        #expect(!numbered.failed, "\(numbered.text)")
        #expect(all("Title", in: bench, id).map(\.text) == ["1", "2", "3", "4", "5", "6"])
        let wider = await call("repeat_grid", ["layers": [id.uuidString], "columns": 4])
        #expect(!wider.failed, "\(wider.text)")
        #expect(all("Title", in: bench, id).map(\.text) == ["1", "2", "3", "7", "4", "5", "6", "8"])
    }

    @Test func theContentListLeavesOutWhatTheCellIsDrawnOn() {
        let (bench, id) = cardBench()
        #expect(bench.store.slots(of: grid(bench, id)).map(\.name) == ["Title"])
    }

    // MARK: Turning and flipping

    /// Every cell's tile on the canvas, as it is read, rounded to a hundredth.
    private func centres(_ bench: Bench, _ id: UUID) -> [CGPoint] {
        all("Tile", in: bench, id).map { absolute(bench, $0).center }.map { CGPoint(x: ($0.x * 100).rounded() / 100, y: ($0.y * 100).rounded() / 100) }
    }

    @Test func aTurnedGridRunsItsRowsTheWayItIsTurned() {
        let (bench, id) = tileBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3; $0.rows = 2 } }
        let pivot = grid(bench, id).frame.center
        bench.step { bench.store.edit("Rotate") { doc in doc.update(id) { $0 = RepeatGrid.turned($0, by: 30, about: pivot) } } }
        let g = grid(bench, id)
        #expect(g.grid?.angle == 30)
        #expect(all("Tile", in: bench, id).allSatisfy { $0.rotation == 30 })
        // A cell along is a step along the turned row, and one down a step down the turned column.
        let c = centres(bench, id)
        let along = c[1] - c[0], down = c[3] - c[0]
        #expect(abs(hypot(along.x, along.y) - 50) < 0.01 && abs(atan2(along.y, along.x) * 180 / .pi - 30) < 0.01)
        #expect(abs(hypot(down.x, down.y) - 50) < 0.01 && abs(atan2(down.y, down.x) * 180 / .pi - 120) < 0.01)
        // Its cells are still the size they were, upright.
        #expect(RepeatGrid.step(of: g) == CGSize(width: 50, height: 50))
        // And turning it again leaves its cells where turning it put them.
        let settled = grid(bench, id)
        bench.step { bench.store.changeGrid(id, "Gap") { $0.columnGap = 10 } }
        #expect(grid(bench, id) == settled)
        // Turned back, it is as it was.
        bench.step { bench.store.edit("Rotate") { doc in doc.update(id) { $0 = RepeatGrid.turned($0, by: -30, about: pivot) } } }
        #expect(grid(bench, id).grid?.angle == nil)
        #expect(centres(bench, id) == [CGPoint(x: 130, y: 130), CGPoint(x: 180, y: 130), CGPoint(x: 230, y: 130),
                                       CGPoint(x: 130, y: 180), CGPoint(x: 180, y: 180), CGPoint(x: 230, y: 180)])
    }

    @Test func aTurnedGridsHandlesPullAlongItsRows() {
        let (bench, id) = tileBench()
        let pivot = CGPoint(x: 30, y: 30)
        bench.step { bench.store.edit("Rotate") { doc in doc.update(id) { $0 = RepeatGrid.turned($0, by: 90, about: pivot) } } }
        bench.store.selection = [id]
        // Turned a quarter, its rows run down the canvas: the handle at the end of the row is below it.
        bench.drag(CGPoint(x: 130, y: 150), CGPoint(x: 130, y: 236))
        #expect(grid(bench, id).grid?.columns == 3)
        let c = centres(bench, id)
        #expect(c.map(\.x) == [130, 130, 130] && c.map(\.y) == [130, 180, 230])
    }

    @Test func aFlippedGridIsItsMirrorImage() {
        let (bench, id) = cardBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3; $0.columnGap = 10 } }
        let slot = all("Title", in: bench, id)[0].id
        bench.step { bench.store.fill(slot, in: id, with: ["A", "B", "C"]) }
        let before = grid(bench, id)
        bench.store.selection = [id]
        bench.step { bench.store.flip(horizontally: true) }
        // Read left to right, the cells hold what they held right to left; the first cell is
        // still first, at the left, and the grid is where it was.
        #expect(all("Title", in: bench, id).map(\.text) == ["C", "B", "A"])
        #expect(grid(bench, id).frame == before.frame)
        #expect(grid(bench, id).children[0].id == before.children[0].id)
        let backs = all("Back", in: bench, id).map { absolute(bench, $0).minX }
        #expect(backs == [110, 180, 250])
        // Each card is turned over itself: its title is now at the right of its back.
        let title = absolute(bench, all("Title", in: bench, id)[0]), back = absolute(bench, all("Back", in: bench, id)[0])
        #expect(abs((back.maxX - title.maxX) - 6) < 0.5)
        // Flipped again, everything is as it was, each cell where it was with what it held. (Words
        // in a grid sit where the first cell's do, so a mirrored line of other words is only near
        // its own mirror image.)
        bench.step { bench.store.flip(horizontally: true) }
        #expect(all("Title", in: bench, id).map(\.text) == ["A", "B", "C"])
        #expect(grid(bench, id).children.map(\.id) == before.children.map(\.id))
        #expect(all("Back", in: bench, id).map(\.frame) == before.children.map { $0.children[0].frame })
        #expect(grid(bench, id).frame == before.frame)
    }

    @Test func aFlippedTurnedGridTurnsTheOtherWay() {
        let (bench, id) = tileBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 2; $0.rows = 2 } }
        let pivot = grid(bench, id).frame.center
        bench.step { bench.store.edit("Rotate") { doc in doc.update(id) { $0 = RepeatGrid.turned($0, by: 20, about: pivot) } } }
        bench.store.selection = [id]
        bench.step { bench.store.flip(horizontally: false) }
        #expect(grid(bench, id).grid?.angle == -20)
        let c = centres(bench, id)
        let along = c[1] - c[0]
        #expect(abs(atan2(along.y, along.x) * 180 / .pi + 20) < 0.01)
    }

    // MARK: Dropping

    /// A plain picture file of this size, in the temporary folder.
    private func picture(_ w: Int, _ h: Int) throws -> URL {
        let ctx = try #require(Renderer.bitmap(CGSize(width: w, height: h)))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleDrop-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func whatADropWillDoIsWhatItDoes() throws {
        let (bench, id) = tileBench()
        bench.step { bench.store.changeGrid(id, "Repeat") { $0.columns = 3 } }
        let tiles = all("Tile", in: bench, id)
        let one = Dropped(pictures: [try picture(40, 20)]), three = Dropped(pictures: [try picture(40, 20), try picture(20, 40), try picture(30, 30)])
        // One picture on a tile fills that tile alone; several fill the tile in every cell.
        guard case .fill(let alone)? = bench.store.plan(for: one, at: .zero, on: tiles[1].id) else { Issue.record("No fill"); return }
        #expect(alone == [tiles[1].id])
        guard case .fill(let each)? = bench.store.plan(for: three, at: .zero, on: tiles[1].id) else { Issue.record("No fill"); return }
        #expect(each == tiles.map(\.id))
        // On the artboard's empty part, a layer of its own at its size, round the pointer.
        guard case .place(let frames, let board)? = bench.store.plan(for: one, at: CGPoint(x: 300, y: 300), on: nil) else { Issue.record("No place"); return }
        #expect(board == bench.a.id && frames == [CGRect(x: 280, y: 290, width: 40, height: 20)])
        // Words go to a grid's text layers only.
        #expect(bench.store.plan(for: Dropped(text: "a\nb"), at: .zero, on: tiles[0].id) == nil)
        bench.step { bench.store.drop(three, at: .zero, on: tiles[2].id) }
        #expect(all("Tile", in: bench, id).map { $0.fill.image?.size } == [CGSize(width: 40, height: 20), CGSize(width: 20, height: 40), CGSize(width: 30, height: 30)])
    }

    @Test func sampleNumbersKeepTheirWords() {
        #expect(SampleContent.numbers.values(3, like: "Step 01") == ["Step 01", "Step 02", "Step 03"])
        #expect(SampleContent.numbers.values(2) == ["1", "2"])
        #expect(SampleContent.names.values(5).count == 5)
        #expect(SampleContent.emails.values(1)[0].hasSuffix("@example.com"))
    }
}
