import Testing
import AppKit
@testable import Bezzle

/// A clock the tests set, to see what an hour, a day or a month of work leaves behind.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func pass(_ minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

/// Versions: how they are kept on disk and thinned, when they are taken, named, looked back at,
/// gone back to and brought back a layer at a time, shared, told as a story, and how all of it
/// stays out of the way of the design as it is now.
@MainActor
struct VersionsTests {
    /// A bench whose design is a package on disk, as versions need, on a clock of its own.
    private func bench(_ clock: TestClock? = nil, extra: [Node]? = nil) throws -> Bench {
        let bench = Bench(extra: extra ?? [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                                           CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50))])
        try DesignFile.write(bench.store.doc, to: bench.store.url)
        bench.store.becamePackage()
        if let clock { bench.store.versions.clock = { clock.now } }
        return bench
    }

    private func done(_ bench: Bench) {
        bench.store.versions.stop()
        DocumentStore.finishSaving()
        try? FileManager.default.removeItem(at: bench.store.url)
    }

    private func move(_ bench: Bench, _ name: String, to x: CGFloat) {
        let id = bench.node(name)!.id
        bench.step { bench.store.update([id], "Move") { $0.frame.origin.x = x } }
    }

    /// The design opened again from disk, as after quitting.
    private func reopened(_ bench: Bench) throws -> DocumentStore {
        bench.store.save()
        DocumentStore.finishSaving()
        let store = DocumentStore(url: bench.store.url, document: try DesignFile.read(bench.store.url))
        store.versions.load()
        return store
    }

    // MARK: On disk

    @Test func aDesignPacksSmallAndComesBackWhole() throws {
        let bench = try bench()
        defer { done(bench) }
        var doc = bench.store.doc
        doc.notes = [MarginNote(on: bench.node("R")!.id, text: "Hm", by: "anna", time: 1)]
        let data = try #require(VersionFiles.pack(doc))
        var back = try #require(VersionFiles.unpack(data))
        back.viewport = doc.viewport
        #expect(back == doc)
        #expect(data.count < (try JSONEncoder().encode(doc)).count)
    }

    @Test func somethingDamagedReadsAsNothingRatherThanFailing() throws {
        let bench = try bench()
        defer { done(bench) }
        let url = bench.store.url
        #expect(VersionFiles.unpack(Data("not a design".utf8)) == nil)
        #expect(VersionFiles.read(UUID(), of: url) == nil)
        #expect(VersionFiles.index(of: url).isEmpty)
        try FileManager.default.createDirectory(at: VersionFiles.folder(of: url), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: VersionFiles.folder(of: url).appendingPathComponent("index.json"))
        #expect(VersionFiles.index(of: url).isEmpty)
    }

    @Test func theListOnDiskIsReadOldestFirst() throws {
        let bench = try bench()
        defer { done(bench) }
        // Kept to the millisecond, as the list on disk keeps them.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let list = [DesignVersion(date: now), DesignVersion(date: now.addingTimeInterval(-600)), DesignVersion(date: now.addingTimeInterval(-60))]
        try VersionFiles.writeIndex(list, to: bench.store.url)
        #expect(VersionFiles.index(of: bench.store.url).map(\.date) == list.map(\.date).sorted())
    }

    @Test func aVersionWhoseFileIsMissingIsLeftOut() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let kept = try #require(store.versions.take(store.sharedDoc, name: "Kept"))
        let lost = try #require(store.versions.take(store.sharedDoc, name: "Lost"))
        DocumentStore.finishSaving()
        try FileManager.default.removeItem(at: VersionFiles.file(lost.id, of: store.url))
        let again = try reopened(bench)
        #expect(again.versions.list.map(\.id) == [kept.id])
    }

    @Test func versionsAreThereAgainWhenTheDesignIsOpenedAgain() throws {
        let clock = TestClock()
        let bench = try bench(clock)
        defer { done(bench) }
        let store = bench.store
        store.save()
        clock.pass(1)
        move(bench, "R", to: 30)
        store.versions.nameNow("Moved")
        let again = try reopened(bench)
        #expect(again.versions.list.map(\.id) == store.versions.list.map(\.id))
        #expect(again.versions.list.last?.name == "Moved")
        let moved = try #require(again.versions.list.last)
        #expect(again.versions.document(moved.id)?.allNodes.first { $0.name == "R" }?.frame.minX == 30)
    }

    // MARK: Thinning

    @Test func versionsAreThinnedAsTimeMachineThinsBackups() {
        let now = Date()
        func at(_ ago: TimeInterval, _ name: String? = nil) -> DesignVersion { DesignVersion(date: now.addingTimeInterval(-ago), name: name) }
        // Every ten minutes for two days, and one named a month ago.
        var list = stride(from: 0.0, to: 2 * 86_400, by: 600).map { at($0) }
        list.append(at(31 * 86_400, "Launch"))
        let kept = VersionFiles.kept(list, now: now)
        // The last hour whole: six of them.
        #expect(kept.filter { now.timeIntervalSince($0.date) < 3600 }.count == 6)
        // Then no more than one each half hour of the day, and one a day before.
        #expect(kept.filter { let a = now.timeIntervalSince($0.date); return a >= 3600 && a < 86_400 }.count <= 47)
        #expect(kept.filter { let a = now.timeIntervalSince($0.date); return a >= 86_400 && a < 2 * 86_400 }.count <= 2)
        #expect(kept.contains { $0.name == "Launch" })
    }

    @Test func theNewestAndEveryNamedVersionAreAlwaysKept() {
        let now = Date()
        func at(_ days: Double, _ name: String? = nil) -> DesignVersion { DesignVersion(date: now.addingTimeInterval(-days * 86_400), name: name) }
        // A year untouched: one a day, and three named among them.
        var list = stride(from: 400.0, to: 30, by: -1).map { at($0) }
        list += [at(380, "First"), at(200, "Second"), at(100, "Third")]
        let kept = VersionFiles.kept(list, now: now)
        #expect(kept.contains { $0.date == list.map(\.date).max() })
        #expect(Set(kept.compactMap(\.name)) == ["First", "Second", "Third"])
        // Older than a month: one a week.
        let unnamed = kept.filter { !$0.isNamed && now.timeIntervalSince($0.date) > 30 * 86_400 }
        #expect(unnamed.count <= 54)
        #expect(unnamed.count >= 50)
        #expect(kept == kept.sorted { $0.date < $1.date })
    }

    @Test func thinningLetsTheFilesOfVersionsLetGoGoToo() throws {
        let clock = TestClock()
        let bench = try bench(clock)
        defer { done(bench) }
        let store = bench.store
        // A day of work, a version every ten minutes.
        for i in 0..<150 {
            move(bench, "R", to: CGFloat(i))
            clock.pass(10)
            store.save()
        }
        DocumentStore.finishSaving()
        let list = store.versions.list
        #expect(list.count < 150)
        #expect(list.count == VersionFiles.index(of: store.url).count)
        let files = try FileManager.default.contentsOfDirectory(atPath: VersionFiles.folder(of: store.url).path).filter { $0.hasSuffix(".lzfse") }
        #expect(Set(files) == Set(list.map { "\($0.id.uuidString).lzfse" }))
    }

    // MARK: Taking them

    @Test func aDesignKeepsAVersionWhenFirstSavedAndWhenClosedChanged() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        store.save()
        #expect(store.versions.list.count == 1)
        // Saved again soon after, unchanged or changed: no new version yet.
        move(bench, "R", to: 30)
        store.save()
        #expect(store.versions.list.count == 1)
        // Closing, changed: one more.
        store.versions.saved(store.sharedDoc, closing: true)
        #expect(store.versions.list.count == 2)
        // Closing again, unchanged: none.
        store.versions.saved(store.sharedDoc, closing: true)
        #expect(store.versions.list.count == 2)
        DocumentStore.finishSaving()
        #expect(VersionFiles.index(of: store.url).count == 2)
    }

    @Test func tenMinutesOfWorkKeepAnotherVersionOnlyIfSomethingChanged() throws {
        let clock = TestClock()
        let bench = try bench(clock)
        defer { done(bench) }
        let store = bench.store
        store.save()
        #expect(store.versions.list.count == 1)
        clock.pass(11)
        store.save()
        #expect(store.versions.list.count == 1)
        move(bench, "R", to: 30)
        store.save()
        #expect(store.versions.list.count == 2)
        clock.pass(5)
        move(bench, "R", to: 40)
        store.save()
        #expect(store.versions.list.count == 2)
        clock.pass(6)
        store.save()
        #expect(store.versions.list.count == 3)
        #expect(store.versions.list.map(\.date) == store.versions.list.map(\.date).sorted())
    }

    @Test func lookingAroundTheDesignIsNoChange() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        store.save()
        store.viewport = Viewport(origin: CGPoint(x: 300, y: 200), zoom: 2.5)
        store.versions.saved(store.sharedDoc, closing: true)
        #expect(store.versions.list.count == 1)
    }

    @Test func aDesignKeptAsOneFileBecomesAPackageForItsVersions() throws {
        let bench = Bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))])
        defer { done(bench) }
        let store = bench.store
        try JSONEncoder().encode(store.doc).write(to: store.url)
        #expect(!DesignFile.isPackage(store.url))
        store.save()
        DocumentStore.finishSaving()
        #expect(DesignFile.isPackage(store.url))
        #expect(store.versions.list.count == 1)
        #expect(try DesignFile.read(store.url).allNodes.contains { $0.name == "R" })
        // Naming works as well in one that was a single file.
        #expect(store.versions.nameNow("Kept") != nil)
    }

    @Test func nothingIsKeptByItselfWhileLookingBack() throws {
        let clock = TestClock()
        let bench = try bench(clock)
        defer { done(bench) }
        let store = bench.store
        store.save()
        let first = try #require(store.versions.list.first)
        move(bench, "R", to: 30)
        store.versions.show(first.id)
        clock.pass(20)
        store.save()
        #expect(store.versions.list.count == 1)
    }

    @Test func aVersionKnowsWhoTookItAndHowManyLayersThereWere() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let v = try #require(store.versions.take(store.sharedDoc, name: nil))
        #expect(v.layers == store.doc.layerCount)
        #expect(v.by == store.noteAuthor.name)
        #expect(v.replica == store.noteAuthor.replica)
        #expect(v.shared == nil)
    }

    @Test func aDesignThatCanOnlyBeLookedAtKeepsAndChangesNothing() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Then"))
        move(bench, "R", to: 30)
        store.sharing = Collaboration(url: store.url, state: SharedDesign(), folder: nil,
                                      link: ShareLink(secret: "", ownerName: "someone", ended: true))
        #expect(store.isReadOnly)
        store.versions.saved(store.sharedDoc, closing: true)
        #expect(store.versions.nameNow("Mine") == nil)
        store.versions.rename(first.id, "Renamed")
        store.versions.restore(first.id)
        #expect(store.versions.list.map(\.name) == ["Then"])
        #expect(bench.node("R")?.frame.minX == 30)
        // Looking back still is.
        store.versions.show(first.id)
        #expect(store.shownDoc.allNodes.first { $0.name == "R" }?.frame.minX == 10)
    }

    // MARK: Naming

    @Test func aNamedVersionOutlivesAllThinning() throws {
        let clock = TestClock()
        let bench = try bench(clock)
        defer { done(bench) }
        let store = bench.store
        let named = try #require(store.versions.nameNow("  Launch  "))
        #expect(named.name == "Launch")
        // Two months of work.
        for i in 0..<120 {
            move(bench, "R", to: CGFloat(i))
            clock.pass(12 * 60)
            store.save()
        }
        #expect(store.versions.list.contains { $0.id == named.id })
        #expect(store.versions.document(named.id) != nil)
    }

    @Test func namingWithoutWordsGivesItAPlainName() throws {
        let bench = try bench()
        defer { done(bench) }
        #expect(bench.store.versions.nameNow("   ")?.name == VersionShelf.defaultName)
    }

    @Test func aVersionIsNamedAfterwardsAndHasItsNameTakenAwayAgain() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let v = try #require(store.versions.take(store.sharedDoc, name: nil))
        store.versions.rename(v.id, " Before the client ")
        #expect(store.versions.list.first?.name == "Before the client")
        DocumentStore.finishSaving()
        #expect(VersionFiles.index(of: store.url).first?.name == "Before the client")
        store.versions.rename(v.id, "")
        #expect(store.versions.list.first?.isNamed == false)
        DocumentStore.finishSaving()
        #expect(VersionFiles.index(of: store.url).first?.name == nil)
    }

    // MARK: Looking back

    @Test func lookingBackShowsThePastWithoutChangingTheDesign() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, r = bench.node("R")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.versions.browse()
        store.versions.show(first.id)
        #expect(store.shownDoc.node(r)?.frame.minX == 10)
        #expect(store.doc.node(r)?.frame.minX == 300)
        #expect(store.versions.shown?.id == first.id)
        store.versions.step(1)
        #expect(store.versions.travel == nil)
        #expect(store.shownDoc.node(r)?.frame.minX == 300)
    }

    @Test func lookingBackTellsWhatChangedWhatWentAndWhatWasMadeSince() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, r = bench.node("R")!.id, s = bench.node("S")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 200)
        store.selection = [s]
        bench.step { store.deleteSelection() }
        let a = bench.a.id
        let t = CanvasTests.rect("T", CGRect(x: 20, y: 200, width: 40, height: 40))
        let made = t.id
        bench.step { store.edit("Add") { $0.insert(t, at: NodePath(indices: [0, $0.nodes[0].children.count])) } }
        store.versions.show(first.id)
        let travel = try #require(store.versions.travel)
        #expect(travel.changed == [r])
        #expect(travel.gone == [s])
        #expect(travel.added == [made])
        // The artboard holding them is not itself changed by what it holds.
        #expect(!travel.changed.contains(a))
    }

    @Test func theArrowsStepThroughTheVersionsAndPastTheNewestToNow() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, shelf = store.versions
        let v = try (0..<3).map { i -> DesignVersion in
            move(bench, "R", to: CGFloat(i * 10))
            return try #require(shelf.take(store.sharedDoc, name: "V\(i)"))
        }
        shelf.browse()
        shelf.step(-1)
        #expect(shelf.travel?.at == v[2].id)
        shelf.step(-1)
        #expect(shelf.travel?.at == v[1].id)
        shelf.step(-5)
        #expect(shelf.travel?.at == v[0].id)
        shelf.step(1)
        #expect(shelf.travel?.at == v[1].id)
        shelf.step(9)
        #expect(shelf.travel == nil)
        #expect(shelf.browsing)
    }

    @Test func theArrowKeysMoveWhatIsSelectedAtNowAndStepThroughTimeOtherwise() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, shelf = store.versions, r = bench.node("R")!.id
        let first = try #require(shelf.take(store.sharedDoc, name: "Start"))
        shelf.browse()
        store.selection = [r]
        bench.key(124, "\u{F703}")
        #expect(bench.node("R")?.frame.minX == 11)
        #expect(shelf.travel == nil)
        store.selection = []
        bench.key(123, "\u{F702}")
        #expect(shelf.travel?.at == first.id)
        // Looking back, the arrows always step, and nothing moves.
        store.selection = [r]
        bench.key(124, "\u{F703}")
        #expect(shelf.travel == nil)
        #expect(bench.node("R")?.frame.minX == 11)
        bench.key(53, "\u{1B}")
        #expect(!shelf.browsing)
    }

    @Test func aPressLookingBackPicksAndNeverMovesALayer() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 30)
        store.versions.show(first.id)
        let before = store.doc
        // R was at 10..60 across and 10..60 down in A, at 100, 100.
        bench.drag(CGPoint(x: 135, y: 135), CGPoint(x: 260, y: 220))
        #expect(store.doc == before)
        #expect(store.versions.travel?.picked == [bench.node("R")!.id])
    }

    @Test func aClickLookingBackPicksOnlyWhatDiffersTheSmallestFirst() throws {
        let child = CanvasTests.rect("C", CGRect(x: 10, y: 10, width: 20, height: 20))
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 200, y: 100, width: 100, height: 100))
        group.children = [child]
        let bench = try bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)), group])
        defer { done(bench) }
        let store = bench.store, shelf = store.versions
        let first = try #require(shelf.take(store.sharedDoc, name: "Start"))
        let g = bench.node("G")!.id, c = bench.node("C")!.id
        bench.step { store.update([g], "Turn") { $0.opacity = 0.5 } }
        bench.step { store.update([c], "Colour") { $0.fill.color = .black } }
        shelf.show(first.id)
        // On R, which has not changed: nothing.
        shelf.pick(at: CGPoint(x: 130, y: 130))
        #expect(shelf.travel?.picked.isEmpty == true)
        // On C, inside G: C, the smaller.
        shelf.pick(at: CGPoint(x: 100 + 200 + 15, y: 100 + 100 + 15))
        #expect(shelf.travel?.picked == [c])
        // On G away from C: G.
        shelf.pick(at: CGPoint(x: 100 + 200 + 80, y: 100 + 100 + 80))
        #expect(shelf.travel?.picked == [c, g])
        // Again on C: no longer.
        shelf.pick(at: CGPoint(x: 100 + 200 + 15, y: 100 + 100 + 15))
        #expect(shelf.travel?.picked == [g])
    }

    @Test func aChangeMadeHereWhileLookingBackBringsNowBack() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, r = bench.node("R")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        store.versions.show(first.id)
        // From a menu, or by the assistant.
        bench.step { store.update([r], "Colour") { $0.fill.color = .black } }
        #expect(store.versions.travel == nil)
        #expect(store.versions.browsing)
        #expect(store.shownDoc.node(r)?.fill.color == .black)
    }

    @Test func undoWhileLookingBackBringsNowBackAndUndoes() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.versions.show(first.id)
        bench.undo.undo()
        #expect(store.versions.travel == nil)
        #expect(bench.node("R")?.frame.minX == 10)
        #expect(store.shownDoc == store.doc)
    }

    @Test func someoneElsesChangeKeepsThePastInViewAndWhatDiffersIsMarkedAgain() async throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, s = bench.node("S")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.versions.show(first.id)
        var theirs = store.doc
        theirs.update(s) { $0.fill.color = .black }
        store.showChangesFromOthers(theirs)
        #expect(store.versions.travel?.at == first.id)
        #expect(store.shownDoc.node(s)?.fill.color != .black)
        for _ in 0..<50 where store.versions.travel?.changed.contains(s) != true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.versions.travel?.changed.contains(s) == true)
    }

    @Test func leavingPutsTheRulerAwayAndShowsNow() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.versions.show(first.id)
        #expect(store.versions.browsing)
        store.versions.leave()
        #expect(!store.versions.browsing)
        #expect(store.preview == nil)
        #expect(store.shownDoc == store.doc)
    }

    @Test func thePastComesBackAfterAnotherPreviewTookTheCanvas() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, r = bench.node("R")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.versions.show(first.id)
        store.preview = DocumentStore.Preview(key: "colours", ids: [r], change: { $0.fill.color = .black })
        store.versions.keepShown()
        #expect(store.preview?.key == VersionShelf.previewKey)
        #expect(store.shownDoc.node(r)?.frame.minX == 10)
    }

    // MARK: Going back

    @Test func goingBackKeepsWhatWasThereAndTheNotes() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, r = bench.node("R")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        bench.step { store.update([r], "Colour") { $0.fill.color = .black } }
        bench.step { store.edit("Write Note") { $0.notes = [MarginNote(on: r, text: "Darker!", by: "anna", time: 2)] } }
        bench.step { store.versions.restore(first.id) }
        #expect(bench.node("R")?.fill.color != .black)
        #expect(store.doc.notes?.first?.text == "Darker!")
        // What was there just before is kept, named.
        let before = try #require(store.versions.list.last)
        #expect(before.name?.isEmpty == false)
        #expect(store.versions.document(before.id)?.node(r)?.fill.color == .black)
        // And going back is a change undo takes back, and redo makes again.
        bench.undo.undo()
        #expect(bench.node("R")?.fill.color == .black)
        bench.undo.redo()
        #expect(bench.node("R")?.fill.color != .black)
    }

    @Test func goingBackStaysOnTheRulerAtNowAndKeepsTheView() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.viewport = Viewport(origin: CGPoint(x: 40, y: 20), zoom: 1.5)
        store.versions.show(first.id)
        bench.step { store.versions.restore() }
        #expect(store.versions.browsing)
        #expect(store.versions.travel == nil)
        #expect(store.viewport == Viewport(origin: CGPoint(x: 40, y: 20), zoom: 1.5))
        #expect(bench.node("R")?.frame.minX == 10)
    }

    @Test func goingBackToHowItIsNowDoesNothingAtAll() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        let count = store.versions.list.count
        bench.step { store.versions.restore(first.id) }
        #expect(store.versions.list.count == count)
        bench.undo.undo()
        #expect(store.versions.list.count == count)
    }

    @Test func aNoteAboutALayerMadeSinceStaysOnTheCanvasWhenGoingBack() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        let t = CanvasTests.rect("T", CGRect(x: 20, y: 200, width: 40, height: 40))
        let made = t.id
        bench.step { store.edit("Add") { $0.insert(t, at: NodePath(indices: [0, $0.nodes[0].children.count])) } }
        bench.step { store.edit("Write Note") { $0.notes = [MarginNote(on: made, text: "Lovely", by: "anna", time: 2)] } }
        bench.step { store.versions.restore(first.id) }
        #expect(store.doc.node(made) == nil)
        let note = try #require(store.doc.notes?.first)
        #expect(note.text == "Lovely")
        #expect(note.on == nil)
    }

    @Test func aVersionThatCannotBeReadCannotBeGoneBackTo() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        let again = try reopened(bench)
        try FileManager.default.removeItem(at: VersionFiles.file(first.id, of: again.url))
        again.versions.restore(first.id)
        again.versions.show(first.id)
        #expect(again.versions.travel == nil)
        #expect(again.doc.allNodes.first { $0.name == "R" }?.frame.minX == 300)
        #expect(again.versions.list.count == 1)
    }

    // MARK: Bringing back

    @Test func aLayerTakenAwaySinceIsBroughtBackWhereItWas() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, s = bench.node("S")!.id, r = bench.node("R")!.id
        let first = try #require(store.versions.take(store.sharedDoc, name: "Both"))
        store.selection = [s]
        bench.step { store.deleteSelection() }
        move(bench, "R", to: 200)
        #expect(bench.node("S") == nil)

        store.versions.browse()
        store.versions.show(first.id)
        // Picked on the canvas, where it was then.
        store.versions.pick(at: CGPoint(x: 100 + 125, y: 100 + 35))
        bench.step { store.versions.bringBack() }
        #expect(store.versions.travel == nil)
        #expect(bench.node("S")?.frame.minX == 100)
        // R stays where it is now.
        #expect(bench.node("R")?.frame.minX == 200)
        #expect(store.doc.parent(of: s)?.name == "A")
        #expect(store.selection == [s])
        // In one step.
        bench.undo.undo()
        #expect(bench.node("S") == nil)
        #expect(bench.node("R")?.frame.minX == 200)
    }

    @Test func aChangedLayerIsBroughtBackAsItWasAndTheRestStaysAsItIsNow() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let first = try #require(store.versions.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 200)
        move(bench, "S", to: 300)
        store.versions.show(first.id)
        store.versions.pick(at: CGPoint(x: 135, y: 135))
        bench.step { store.versions.bringBack() }
        #expect(bench.node("R")?.frame.minX == 10)
        #expect(bench.node("S")?.frame.minX == 300)
    }

    @Test func aGroupAndWhatItHeldComeBackOnceEvenWhenBothArePicked() throws {
        let child = CanvasTests.rect("C", CGRect(x: 10, y: 10, width: 20, height: 20))
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 200, y: 100, width: 100, height: 100))
        group.children = [child]
        let bench = try bench(extra: [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)), group])
        defer { done(bench) }
        let store = bench.store, shelf = store.versions
        let first = try #require(shelf.take(store.sharedDoc, name: "Start"))
        let g = bench.node("G")!.id
        store.selection = [g]
        bench.step { store.deleteSelection() }
        shelf.show(first.id)
        shelf.pick(at: CGPoint(x: 315, y: 215))
        shelf.pick(at: CGPoint(x: 380, y: 280))
        #expect(shelf.travel?.picked.count == 2)
        bench.step { shelf.bringBack() }
        #expect(store.doc.allNodes.filter { $0.name == "G" }.count == 1)
        #expect(store.doc.allNodes.filter { $0.name == "C" }.count == 1)
        #expect(store.doc.parent(of: bench.node("C")!.id)?.id == g)
    }

    @Test func aLayerWhoseArtboardIsGoneComesBackOnTheCanvasWhereItWas() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, shelf = store.versions, a = bench.a.id, r = bench.node("R")!.id
        let first = try #require(shelf.take(store.sharedDoc, name: "Start"))
        store.selection = [a]
        bench.step { store.deleteSelection() }
        #expect(store.doc.node(r) == nil)
        shelf.show(first.id)
        shelf.pick(at: CGPoint(x: 115, y: 115))
        #expect(shelf.travel?.picked == [r])
        bench.step { shelf.bringBack() }
        let back = try #require(store.doc.node(r))
        #expect(store.doc.parent(of: r) == nil)
        #expect(back.frame == CGRect(x: 110, y: 110, width: 50, height: 50))
    }

    // MARK: The story

    @Test func aLongStoryIsToldInAboutThirtyStepsWithEveryNamedOne() {
        let now = Date()
        var list = (0..<200).map { DesignVersion(date: now.addingTimeInterval(Double($0) * 600)) }
        for i in [3, 77, 150] { list[i].name = "N\(i)" }
        let story = VersionShelf.story(of: list)
        #expect(story.count <= 33)
        #expect(story.count >= 28)
        #expect(story.first == list.first?.id)
        #expect(story.last == list.last?.id)
        for i in [3, 77, 150] { #expect(story.contains(list[i].id)) }
        // In order.
        let order = story.map { id in list.firstIndex { $0.id == id }! }
        #expect(order == order.sorted())
        // A short one, whole.
        #expect(VersionShelf.story(of: Array(list.prefix(5))) == list.prefix(5).map(\.id))
    }

    @Test func theStoryPlaysToNowAndStepsOrLeavingStopIt() async throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, shelf = store.versions
        for i in 0..<3 {
            move(bench, "R", to: CGFloat(i * 10))
            shelf.take(store.sharedDoc, name: "V\(i)")
        }
        move(bench, "R", to: 99)
        shelf.tempo = 0.02
        shelf.play()
        #expect(shelf.playing)
        #expect(shelf.browsing)
        #expect(shelf.travel?.at == shelf.list.first?.id)
        for _ in 0..<100 where shelf.playing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!shelf.playing)
        #expect(shelf.travel == nil)
        #expect(store.shownDoc.allNodes.first { $0.name == "R" }?.frame.minX == 99)

        shelf.tempo = 10
        shelf.play()
        shelf.step(1)
        #expect(!shelf.playing)
        shelf.play()
        shelf.leave()
        #expect(!shelf.playing)
        #expect(shelf.travel == nil)
        // And a change while it plays brings now back.
        shelf.play()
        bench.step { store.update([bench.node("R")!.id], "Colour") { $0.fill.color = .black } }
        #expect(!shelf.playing)
        #expect(shelf.travel == nil)
    }

    // MARK: Shared

    @Test func aVersionNamedInASharedDesignIsSharedAndOnesTakenByThemselvesAreNot() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        store.sharing = Collaboration(url: store.url, keys: testKeys("design-\(UUID().uuidString)"))
        let named = try #require(store.versions.nameNow("For everyone"))
        #expect(named.shared == true)
        let own = try #require(store.versions.take(store.sharedDoc, name: nil))
        #expect(own.shared == nil)
        // Named afterwards, it is shared from then on.
        store.versions.rename(own.id, "Now for everyone too")
        #expect(store.versions.list.first { $0.id == own.id }?.shared == true)
    }

    @Test func aNamedVersionFromSomeoneElseJoinsTheListInItsPlace() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, shelf = store.versions
        let mine = try #require(shelf.take(store.sharedDoc, name: "Mine"))
        var doc = store.sharedDoc
        doc.update(bench.node("R")!.id) { $0.frame.origin.x = 222 }
        let theirs = DesignVersion(date: mine.date.addingTimeInterval(-3600), name: "Theirs", by: "ben", replica: "b2", layers: 4)
        shelf.arrived(theirs, data: try #require(VersionFiles.pack(doc)))
        #expect(shelf.list.map(\.name) == ["Theirs", "Mine"])
        #expect(shelf.list.first?.shared == true)
        shelf.show(theirs.id)
        #expect(store.shownDoc.allNodes.first { $0.name == "R" }?.frame.minX == 222)
        // Kept with the design.
        let again = try reopened(bench)
        #expect(again.versions.list.map(\.name) == ["Theirs", "Mine"])

        // Coming again, renamed: only its name changes.
        var renamed = theirs
        renamed.name = "Theirs, final"
        shelf.arrived(renamed, data: try #require(VersionFiles.pack(doc)))
        #expect(shelf.list.map(\.name) == ["Theirs, final", "Mine"])
        // Coming damaged: not kept.
        shelf.arrived(DesignVersion(date: Date(), name: "Broken"), data: Data("nope".utf8))
        #expect(shelf.list.count == 2)
    }

    // MARK: The light it was made in

    @Test func theLightComesFromTheLeftInTheMorningTheRightInTheEveningAndALampAtNight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Zurich"))
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Sky {
            Sky.at(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!, calendar: calendar)
        }
        let morning = at(6, 21, 6), noon = at(6, 21, 13, 30), evening = at(6, 21, 21), midnight = at(6, 21, 0, 30)
        #expect(morning.x < 0.35)
        #expect(evening.x > 0.65)
        #expect(abs(noon.x - 0.5) < 0.05)
        #expect(noon.sun > morning.sun && noon.sun > evening.sun)
        #expect(noon.warmth < morning.warmth && noon.warmth < evening.warmth)
        #expect(noon.night == 0)
        #expect(midnight.night > 0.99)
        #expect(midnight.warmth > 0.99)
        // Winter days are short and their noon is low: half past five is night in December, and
        // still day in June.
        #expect(at(12, 21, 17, 30).night > 0.5)
        #expect(at(6, 21, 17, 30).night == 0)
        #expect(at(12, 21, 12, 30).sun < noon.sun)
        // The sky of the ruler: blue at noon, indigo at night.
        #expect(noon.sky.b > noon.sky.r)
        #expect(midnight.sky.r < 0.3 && midnight.sky.b > midnight.sky.r)
    }

    @Test func theCombSpreadsTheVersionsFromTheFirstToNowWithRoomBetweenDays() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let now = today.addingTimeInterval(20 * 3600)
        // Three yesterday, two today.
        let dates = [-6.0, -5, -4, 9, 10].map { today.addingTimeInterval($0 * 3600) }
        let xs = TimeRuler.slots(dates, width: 600, now: now)
        #expect(xs.count == 6)
        #expect(xs.first == 4)
        #expect(abs(xs.last! - 594) < 0.001)
        #expect(xs == xs.sorted())
        let steps = zip(xs, xs.dropFirst()).map { $1 - $0 }
        // The same step within a day, a longer one from yesterday to today.
        #expect(abs(steps[0] - steps[1]) < 0.001)
        #expect(steps[2] > steps[1] * 1.5)
        #expect(abs(steps[3] - steps[0]) < 0.001)
        // Many fit in the comb.
        let many = TimeRuler.slots((0..<400).map { now.addingTimeInterval(Double($0 - 400) * 60) }, width: 600, now: now)
        #expect(many.first! >= 0)
        #expect(many.last! <= 600)
        #expect(TimeRuler.slots([], width: 600, now: now) == [594])
        #expect(TimeRuler.nearest(593, in: xs) == 5)
        #expect(TimeRuler.nearest(-50, in: xs) == 0)
    }

    @Test func theLineFlyingOverTheCombPlucksEachStrokeItPassesOnce() {
        let xs: [CGFloat] = [10, 30, 50, 70, 90]
        #expect(RulerMotion.crossed(from: 90, to: 10, xs: xs) == [0, 1, 2, 3])
        #expect(RulerMotion.crossed(from: 10, to: 50, xs: xs) == [1, 2])
        #expect(RulerMotion.crossed(from: 50, to: 50.1, xs: xs).isEmpty)
        // Flown in small steps, frame by frame, each stroke is plucked once.
        let motion = RulerMotion()
        let start = Date(timeIntervalSince1970: 0)
        let bases: [CGFloat] = [9, 9, 9, 9, 0]
        motion.step(at: start, xs: xs, bases: bases, pointer: nil, head: 90, held: false)
        for i in 1...60 { motion.step(at: start.addingTimeInterval(Double(i) / 60), xs: xs, bases: bases, pointer: nil, head: 90, held: false) }
        #expect(motion.heights.allSatisfy { abs($0.value - 9) < 0.5 || $0.target == 0 })
        var seen = Set<Int>()
        for i in 61...160 {
            motion.step(at: start.addingTimeInterval(Double(i) / 60), xs: xs, bases: bases, pointer: nil, head: 10, held: false)
            for (k, g) in motion.glow.enumerated() where g > 0.99 { seen.insert(k) }
        }
        #expect(seen == [0, 1, 2, 3])
        #expect(abs(motion.head.value - 10) < 1)
        // Under the pointer the strokes swell, the nearest most.
        for i in 161...260 { motion.step(at: start.addingTimeInterval(Double(i) / 60), xs: xs, bases: bases, pointer: 50, head: 10, held: false) }
        #expect(motion.heights[2].value > motion.heights[1].value)
        #expect(motion.heights[1].value > motion.heights[0].value)
        #expect(motion.heights[2].value > 15)
    }

    /// Strokes plucked near the comb's right end, and the comb a sixth as wide by the next frame,
    /// as when the window is made smaller while the line flies: the ripple is set going where the
    /// string still is, and nothing breaks off past its end.
    @Test func aStrokePluckedPastTheStringsEndOnceTheCombNarrowsBreaksNothing() {
        let motion = RulerMotion()
        let start = Date(timeIntervalSince1970: 0)
        let bases: [CGFloat] = [9, 9, 0]
        motion.step(at: start, xs: [200, 400, 590], bases: bases, pointer: nil, head: 150, held: true, width: 600)
        motion.step(at: start.addingTimeInterval(1.0 / 20), xs: [200, 400, 590], bases: bases, pointer: nil, head: 590, held: true, width: 600)
        #expect(motion.glow[0] == 1)
        motion.step(at: start.addingTimeInterval(2.0 / 20), xs: [20, 60, 94], bases: bases, pointer: nil, head: 94, held: true, width: 100)
        #expect(motion.wave.count == 20 && motion.wave.allSatisfy(\.isFinite))
        // And a stroke within reach still sets the string going there.
        motion.step(at: start.addingTimeInterval(3.0 / 20), xs: [20, 60, 94], bases: bases, pointer: nil, head: 10, held: true, width: 100)
        for i in 4...8 { motion.step(at: start.addingTimeInterval(Double(i) / 20), xs: [20, 60, 94], bases: bases, pointer: nil, head: 10, held: true, width: 100) }
        #expect(motion.wave.contains { abs($0) > 0 })
    }

    @Test func theRulerNamesDaysAsOneSaysThem() {
        let now = Date()
        #expect(TimeRuler.day(now, now: now) == String(localized: "Today"))
        #expect(TimeRuler.day(now.addingTimeInterval(-86_400), now: now) == String(localized: "Yesterday"))
        let lastWeek = now.addingTimeInterval(-3 * 86_400)
        #expect(TimeRuler.day(lastWeek, now: now) == lastWeek.formatted(.dateTime.weekday(.wide)))
        let longAgo = now.addingTimeInterval(-400 * 86_400)
        #expect(TimeRuler.day(longAgo, now: now).contains(longAgo.formatted(.dateTime.year())))
    }

    @Test func theDesignGlidesToThePastAndSettlesOnIt() throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store, shelf = store.versions, r = bench.node("R")!.id, s = bench.node("S")!.id
        let first = try #require(shelf.take(store.sharedDoc, name: "Start"))
        move(bench, "R", to: 300)
        store.selection = [s]
        bench.step { store.deleteSelection() }
        let made = CanvasTests.rect("T", CGRect(x: 20, y: 200, width: 40, height: 40))
        bench.step { store.edit("Add") { $0.insert(made, at: NodePath(indices: [0, $0.nodes[0].children.count])) } }
        let table = TimeTable(store: store)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        _ = table.frame(of: store.shownDoc, in: bounds, at: 0)
        shelf.show(first.id)
        // As it begins, nothing has changed yet.
        let start = table.frame(of: store.shownDoc, in: bounds, at: 1)
        #expect(start.node(r)?.frame.minX == 300)
        #expect(start.node(made.id)?.opacity == 0 || start.node(made.id)?.opacity == 1)
        #expect(table.isMoving)
        // On its way, all together: between, what was made since fading, and what went since coming back.
        let mid = table.frame(of: store.shownDoc, in: bounds, at: 1 + TimeTable.duration / 2)
        let x = try #require(mid.node(r)?.frame.minX)
        #expect(x > 10 && x < 300)
        #expect(mid.node(s) != nil)
        // Settled: just as it was then.
        let end = table.frame(of: store.shownDoc, in: bounds, at: 10)
        #expect(end == store.shownDoc)
        #expect(end.node(r)?.frame.minX == 10)
        #expect(end.node(made.id) == nil)
        #expect(!table.isMoving)
        // And back to now the same way.
        shelf.showNow()
        let back = table.frame(of: store.shownDoc, in: bounds, at: 11)
        #expect(back.node(r)?.frame.minX == 10)
        #expect(table.frame(of: store.shownDoc, in: bounds, at: 20) == store.doc)
    }

    // MARK: The assistant

    @Test func theAssistantNamesListsShowsAndGoesBackToVersions() async throws {
        let bench = try bench()
        defer { done(bench) }
        let store = bench.store
        let tools = MCPTools()
        MCPTools.opened(store)
        func call(_ arguments: [String: Any]) async -> (text: String, failed: Bool, object: [String: Any]) {
            var arguments = arguments
            arguments["design"] = store.name
            let result = await tools.call("versions", arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let inner = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            return (text, object?["isError"] as? Bool == true, inner)
        }
        let named = await call(["name": "Start"])
        #expect(!named.failed, "\(named.text)")
        let id = try #require(named.object["named"] as? String)
        #expect((named.object["versions"] as? [[String: Any]])?.first?["name"] as? String == "Start")
        move(bench, "R", to: 300)
        let shown = await call(["show": id])
        #expect(!shown.failed)
        #expect(store.versions.travel?.at.uuidString == id)
        let now = await call(["show": "none"])
        #expect(!now.failed)
        #expect(!store.versions.browsing)
        let back = await call(["go_back_to": id])
        #expect(!back.failed, "\(back.text)")
        #expect(bench.node("R")?.frame.minX == 10)
        #expect((back.object["versions"] as? [[String: Any]])?.count == 2)
        let wrong = await call(["go_back_to": UUID().uuidString])
        #expect(wrong.failed)
    }
}
