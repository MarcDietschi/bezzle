import Foundation
import Testing
@testable import CutoutWays

/// Which way each PC makes its subject matte, what Bezzle remembers of the ways, and what cutouts
/// are called (Host/MatteWays.swift): the Mac's CutoutWorkTests and CutoutTests, for a PC.
struct MatteWaysTests {
    private func pc(_ gigabytes: Double, cores: Int, card: Double = 0) -> MatteMachine {
        MatteMachine(memory: UInt64(gigabytes * MatteMachine.gigabyte), cores: cores, dedicated: UInt64(card * MatteMachine.gigabyte))
    }

    private let large = 2048, small = 1200

    // MARK: Which way a PC takes

    @Test func eachPCTakesTheWayItCanAfford() {
        typealias Route = MatteRoute
        // A small PC with integrated graphics: the light size on the processor, whatever the picture.
        #expect(MatteWays.routes(longest: large, on: pc(4, cores: 2)) == [Route.light])
        #expect(MatteWays.routes(longest: small, on: pc(4, cores: 2)) == [Route.light])
        #expect(MatteWays.routes(longest: large, on: pc(8, cores: 4)) == [Route.light])
        #expect(MatteWays.routes(longest: large, on: pc(16, cores: 8)) == [Route.light])
        // A card with 6 GB of its own takes the light size, and the processor after it.
        #expect(MatteWays.routes(longest: large, on: pc(16, cores: 8, card: 6)) == [Route.lightOnCard, .light])
        #expect(MatteWays.routes(longest: small, on: pc(16, cores: 8, card: 6)) == [Route.lightOnCard, .light])
        // Cores enough to make it in the time anyone waits: the fine size on the processor, for a
        // large picture only. Memory is not what it asks (2 GB, as the light size).
        #expect(MatteWays.routes(longest: large, on: pc(32, cores: 16)) == [Route.fine, .light])
        #expect(MatteWays.routes(longest: small, on: pc(32, cores: 16)) == [Route.light])
        #expect(MatteWays.routes(longest: large, on: pc(16, cores: 16)) == [Route.fine, .light])
        #expect(MatteWays.routes(longest: large, on: pc(32, cores: 12)) == [Route.light])
        #expect(MatteWays.routes(longest: large, on: pc(64, cores: 8)) == [Route.light])
        #expect(MatteWays.routes(longest: large, on: pc(8, cores: 16)) == [Route.light])
        // A card with 12 GB and more: the fine size on it for a large picture, then lighter and lighter.
        #expect(MatteWays.routes(longest: large, on: pc(64, cores: 16, card: 16)) == [Route.fineOnCard, .lightOnCard, .light])
        #expect(MatteWays.routes(longest: small, on: pc(64, cores: 16, card: 16)) == [Route.lightOnCard, .light])
        #expect(MatteWays.routes(longest: MatteWays.fineFrom - 1, on: pc(64, cores: 16, card: 16)).first == .lightOnCard)
        #expect(MatteWays.routes(longest: MatteWays.fineFrom, on: pc(64, cores: 16, card: 16)).first == .fineOnCard)
        // A card too small is left alone, and so is any card in a PC with little memory.
        #expect(MatteWays.routes(longest: large, on: pc(16, cores: 8, card: 4)) == [Route.light])
        #expect(MatteWays.routes(longest: large, on: pc(6, cores: 4, card: 8)) == [Route.light])
        // As Windows counts a PC's memory and a card's: a little under what they are sold with.
        #expect(MatteWays.routes(longest: large, on: pc(15.8, cores: 16)) == [Route.fine, .light])
        #expect(MatteWays.routes(longest: large, on: pc(15.8, cores: 8, card: 5.9)) == [Route.lightOnCard, .light])
        #expect(MatteWays.routes(longest: large, on: pc(31.9, cores: 16, card: 11.9)).first == .fineOnCard)
    }

    @Test func everyPCHasTheLightestWayLastAndNoneAsksMoreThanItHas() {
        for gigabytes in [4.0, 8, 16, 32, 64, 128] {
            for cores in [2, 4, 8, 12, 16, 24] {
                for card in [0.0, 2, 4, 6, 8, 12, 16, 24] {
                    for longest in [small, large] {
                        let machine = pc(gigabytes, cores: cores, card: card)
                        let routes = MatteWays.routes(longest: longest, on: machine)
                        #expect(routes.last == .light && Set(routes).count == routes.count, "\(machine): \(routes)")
                        // On the card no more than the card has, on the processor a quarter of the memory
                        // at most. But for the lightest way: it is all a small PC has, and 2 GB of 4 there.
                        for route in routes where route != .light {
                            let has = route.onCard ? Double(machine.dedicated) : Double(machine.memory) * 0.26
                            #expect(Double(route.holds) <= has, "\(machine): \(route)")
                        }
                        // Finer first: a way after another is never finer than it.
                        #expect(zip(routes, routes.dropFirst()).allSatisfy { $0.grade >= $1.grade }, "\(machine): \(routes)")
                    }
                }
            }
        }
    }

    @Test func theWaysAreCalledAsTheMacCallsThem() {
        #expect(MatteRoute.all.map(\.description) == ["gpu2048", "cpu2048", "gpu1024", "cpu1024"])
        #expect(MatteRoute.fine.grade == .fine && MatteRoute.fineOnCard.grade == .fine)
        #expect(MatteRoute.light.grade == .light && MatteRoute.lightOnCard.grade == .light)
        #expect(MatteRoute.fine.graph == "BiRefNet-2048.onnx" && MatteRoute.lightOnCard.graph == "BiRefNet-1024.onnx")
        #expect(MatteGrade.allCases == [.plain, .light, .fine] && MatteGrade.plain < .light && MatteGrade.light < .fine)
        #expect(MatteWays.version == 1)
    }

    @Test func aPCIsDescribedForTryingItsWays() {
        #expect(MatteMachine(describing: "16:8") == pc(16, cores: 8))
        #expect(MatteMachine(describing: "32:12:8") == pc(32, cores: 12, card: 8))
        #expect(MatteMachine(describing: "7.5:4:0") == pc(7.5, cores: 4))
        for wrong in ["", "16", "16:", "16:x", "0:4", "16:0", "16:8:x", "16:8:6:1", "16:8:-1"] {
            #expect(MatteMachine(describing: wrong) == nil, "\(wrong)")
        }
    }

    // MARK: What is remembered of the ways

    /// Settings of their own for a test, gone after it.
    private func scratch() -> (UserDefaults, String) {
        let name = "BezzleWindowsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func aWayThatTookBezzleDownIsPassedOverByThisVersion() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let machine = pc(64, cores: 16, card: 16)
        let fresh = MatteLedger(machine: machine, defaults: defaults, version: "9.9")
        #expect(fresh.wentDownWith == nil && fresh.ways(longest: large) == [.fineOnCard, .lightOnCard, .light])
        // A way is marked on disk while it runs, and no longer once it is over.
        fresh.mark(.fineOnCard, running: true)
        #expect(defaults.stringArray(forKey: "subjectMatte.running") == ["gpu2048"])
        fresh.mark(.fineOnCard, running: false)
        #expect(defaults.object(forKey: "subjectMatte.running") == nil)
        // Bezzle went down with it running: the next start finds the mark.
        fresh.mark(.fineOnCard, running: true)
        let after = MatteLedger(machine: machine, defaults: defaults, version: "9.9")
        #expect(after.wentDownWith == .fineOnCard)
        #expect(defaults.object(forKey: "subjectMatte.running") == nil)
        #expect(after.ways(longest: large) == [.lightOnCard, .light])
        #expect(after.ways(longest: small) == [.lightOnCard, .light])
        // And it stays passed over, start after start, until the next version of Bezzle tries it again.
        let later = MatteLedger(machine: machine, defaults: defaults, version: "9.9")
        #expect(later.wentDownWith == nil && later.ways(longest: large) == [.lightOnCard, .light])
        #expect(MatteLedger(machine: machine, defaults: defaults, version: "10.0").ways(longest: large).first == .fineOnCard)
    }

    @Test func ofSeveralWaysRunningTheHeaviestIsHeldToBeIt() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        // The card holds more at the light size than the processor at the fine one, here as on a Mac.
        defaults.set(["cpu1024", "gpu1024", "cpu2048"], forKey: "subjectMatte.running")
        let ledger = MatteLedger(machine: pc(64, cores: 16, card: 8), defaults: defaults, version: "9.9")
        #expect(ledger.wentDownWith == .lightOnCard)
        #expect(defaults.dictionary(forKey: "subjectMatte.avoided") as? [String: String] == ["gpu1024": "9.9"])
        #expect(ledger.ways(longest: large) == [.light])
        #expect(ledger.ways(longest: small) == [.light])
    }

    @Test func quittingWhileAWayRunsIsNotGoingDownWithIt() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let machine = pc(64, cores: 16, card: 16)
        let ledger = MatteLedger(machine: machine, defaults: defaults, version: "9.9")
        ledger.mark(.fineOnCard, running: true)
        ledger.quitting()
        let next = MatteLedger(machine: machine, defaults: defaults, version: "9.9")
        #expect(next.wentDownWith == nil && next.ways(longest: large).first == .fineOnCard)
    }

    @Test func aWayThatTookTooLongIsPassedOver() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let ledger = MatteLedger(machine: pc(32, cores: 16), defaults: defaults, version: "9.9")
        #expect(ledger.ways(longest: large) == [.fine, .light])
        ledger.remember(matte: MatteWays.patience + 15, by: .fine, cold: true)
        #expect(ledger.took(.fine) == MatteWays.patience + 15)
        #expect(ledger.ways(longest: large) == [.light])
        // Quicker the next times (another program was in its way), it is taken again.
        defaults.set(MatteWays.patience - 5, forKey: "subjectMatte.seconds.cpu2048.cold")
        #expect(ledger.ways(longest: large) == [.fine, .light])
        // While memory is short, the card is left alone; and the fine size where its graph is not there.
        let carded = MatteLedger(machine: pc(64, cores: 16, card: 16), defaults: defaults, version: "9.9")
        #expect(carded.ways(longest: large, short: true) == [.light])
        #expect(carded.ways(longest: large, fine: false) == [.lightOnCard, .light])
        #expect(MatteLedger(machine: pc(32, cores: 16), defaults: defaults, version: "9.9").ways(longest: large, fine: false) == [.light])
    }

    @Test func theLightestWayIsNeverPassedOver() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        // Bezzle went down with it, it took minutes, memory is short and the fine graph is gone: still there.
        defaults.set(["cpu1024"], forKey: "subjectMatte.running")
        defaults.set(["cpu1024": "9.9"], forKey: "subjectMatte.avoided")
        defaults.set(300.0, forKey: "subjectMatte.seconds.cpu1024.cold")
        defaults.set(300.0, forKey: "subjectMatte.seconds.cpu1024.warm")
        for machine in [pc(4, cores: 2), pc(32, cores: 12), pc(64, cores: 16, card: 16)] {
            let ledger = MatteLedger(machine: machine, defaults: defaults, version: "9.9")
            #expect(ledger.wentDownWith == nil)
            for longest in [small, large] {
                #expect(ledger.ways(longest: longest, short: true, fine: false) == [.light])
                #expect(ledger.ways(longest: longest).last == .light)
            }
        }
        #expect(defaults.dictionary(forKey: "subjectMatte.avoided") as? [String: String] == ["cpu1024": "9.9"])
    }

    @Test func oneWayAloneCanBeTried() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let ledger = MatteLedger(machine: pc(4, cores: 2), defaults: defaults, version: "9.9", forced: "gpu2048")
        #expect(ledger.ways(longest: small, short: true, fine: false) == [.fineOnCard])
        #expect(MatteLedger(machine: pc(4, cores: 2), defaults: defaults, version: "9.9", forced: "nonsense").ways(longest: large).isEmpty)
    }

    @Test func eachWayIsExpectedToTakeAsLongAsItTookHere() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let ledger = MatteLedger(machine: pc(16, cores: 9), defaults: defaults, version: "9.9")
        // Nothing known yet: by the PC's cores on the processor, by guess on the card.
        #expect(ledger.expecting(.light, loading: true, cold: true) == [.load: 2, .matte: 10])
        #expect(ledger.expecting(.fine, loading: true, cold: true) == [.load: 2, .matte: 46])
        #expect(ledger.expecting(.lightOnCard, loading: true, cold: true) == [.load: 8, .matte: 2])
        #expect(ledger.expecting(.fineOnCard, loading: true, cold: true) == [.load: 12, .matte: 5])
        // Loaded already, loading takes no time.
        #expect(ledger.expecting(.lightOnCard, loading: false, cold: false) == [.load: 0, .matte: 2])
        // What it took is what is expected, leaning to the last time over those before.
        ledger.remember(matte: 4, by: .light, cold: true)
        ledger.remember(loading: 1, for: .light)
        #expect(ledger.expecting(.light, loading: true, cold: true) == [.load: 1, .matte: 4])
        ledger.remember(matte: 8, by: .light, cold: true)
        let blended = ledger.expecting(.light, loading: true, cold: true)[.matte] ?? 0
        #expect(abs(blended - (4 * 0.3 + 8 * 0.7)) < 1e-9)
        // The first matte after loading stands in for those after it until one is known, and the other way round.
        #expect(ledger.expecting(.light, loading: false, cold: false)[.matte] == blended)
        ledger.remember(matte: 3, by: .light, cold: false)
        #expect(ledger.expecting(.light, loading: false, cold: false)[.matte] == 3)
        #expect(ledger.took(.light) == blended)
    }

    @Test func readingAndFinishingAreExpectedByThePicturesSize() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let times = CutoutTimes(defaults: defaults)
        let small = times.expecting(megapixels: 1), large = times.expecting(megapixels: 24)
        #expect((small[.look] ?? 0) > 0 && (small[.finish] ?? 0) > 0)
        #expect((large[.look] ?? 0) > (small[.look] ?? 0) && (large[.finish] ?? 0) > (small[.finish] ?? 0))
        // A picture of 10 megapixels took 1 s to read and 5 s to finish: a megapixel 0.1 s and 0.5 s.
        times.remember(reading: 1, finishing: 5, megapixels: 10)
        let known = times.expecting(megapixels: 2)
        #expect(abs((known[.look] ?? 0) - (0.2 + 2 * 0.1)) < 1e-9 && abs((known[.finish] ?? 0) - (0.3 + 2 * 0.5)) < 1e-9)
        // A cutout found made is not finished: nothing is learned of finishing from it.
        times.remember(reading: 3, finishing: nil, megapixels: 10)
        let again = times.expecting(megapixels: 2)
        #expect(abs((again[.look] ?? 0) - (0.2 + 2 * 0.2)) < 1e-9 && again[.finish] == known[.finish])
    }

    // MARK: Mattes kept

    @Test func aMatteKeptIsTakenOnlyWhereItIsAsFineAsWouldBeMadeNow() {
        var kept = KeptMattes<String>()
        #expect(kept.matte(of: "a", atLeast: .plain) == nil)
        kept.keep("light a", of: "a", grade: .light)
        #expect(kept.matte(of: "a", atLeast: .light)?.matte == "light a")
        #expect(kept.matte(of: "a", atLeast: .plain)?.grade == .light)
        // The fine size would be made now: the light one kept is not good enough.
        #expect(kept.matte(of: "a", atLeast: .fine) == nil)
        #expect(kept.matte(of: "b", atLeast: .plain) == nil)
        // Made anew, it takes the place of the one kept before.
        kept.keep("fine a", of: "a", grade: .fine)
        #expect(kept.count == 1 && kept.matte(of: "a", atLeast: .fine)?.matte == "fine a")
        #expect(kept.matte(of: "a", atLeast: .light)?.matte == "fine a")
        // Three pictures' mattes at most: the oldest goes.
        kept.keep("b", of: "b", grade: .light)
        kept.keep("c", of: "c", grade: .light)
        kept.keep("d", of: "d", grade: .light)
        #expect(kept.count == KeptMattes<String>.most && kept.matte(of: "a", atLeast: .plain) == nil)
        #expect(kept.matte(of: "d", atLeast: .light)?.matte == "d" && kept.matte(of: "b", atLeast: .light)?.matte == "b")
        kept.forget()
        #expect(kept.count == 0 && kept.matte(of: "d", atLeast: .plain) == nil)
    }

    // MARK: What cutouts are called

    @Test func cutoutsAreCalledAsTheMacCallsThem() {
        // The Mac's own names (BezzleTests/CutoutTests): a design shared with a Mac finds them.
        #expect(CutoutNames.name(of: "photo.png", picks: nil, grade: .plain) == "photo-cutout.png")
        #expect(CutoutNames.name(of: "photo.png", picks: nil, grade: .fine) == "photo-cutout-m1.png")
        #expect(CutoutNames.name(of: "photo.png", picks: nil, grade: .light) == "photo-cutout-m1-1024.png")
        #expect(CutoutNames.name(of: "A1B2.jpeg", picks: [], grade: .light) == "A1B2-cutout-m1-1024.png")
        // Picks are part of the name: FNV-1a over them to a ten-thousandth, worked out apart from Bezzle.
        #expect(CutoutNames.name(of: "photo.png", picks: [CGPoint(x: 0.5, y: 0.5)], grade: .fine) == "photo-cutout-m1-ffc7136ca4b5ac9.png")
        #expect(CutoutNames.name(of: "photo.png", picks: [CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.6, y: 0.4)], grade: .light)
            == "photo-cutout-m1-1024-5e0e8c38137393a5.png")
        #expect(CutoutNames.name(of: "photo.png", picks: [CGPoint(x: 0.33333, y: 0.66666)], grade: .plain) == "photo-cutout-520a123cac1a49a4.png")
        // The same picks, the same name; other picks, another.
        let picks = [CGPoint(x: 0.5, y: 0.5)]
        let names = MatteGrade.allCases.map { CutoutNames.name(of: "photo.png", picks: picks, grade: $0) }
        #expect(Set(names).count == 3)
        #expect(CutoutNames.name(of: "photo.png", picks: picks, grade: .fine) != CutoutNames.name(of: "photo.png", picks: [CGPoint(x: 0.4, y: 0.5)], grade: .fine))
    }

    @Test func aCutoutMadeBeforeIsLookedForTheFinestFirstAndNeverPlainerThanWanted() {
        #expect(CutoutNames.names(of: "photo.png", picks: nil, atLeast: .light).map(\.name) == ["photo-cutout-m1.png", "photo-cutout-m1-1024.png"])
        #expect(CutoutNames.names(of: "photo.png", picks: nil, atLeast: .fine).map(\.grade) == [.fine])
        #expect(CutoutNames.names(of: "photo.png", picks: nil, atLeast: .plain).map(\.grade) == [.fine, .light, .plain])
    }

    @Test func theCardIsLeftAloneWhileWindowsSaysMemoryIsShort() {
        let gigabyte: UInt64 = 1_073_741_824
        // Room enough: a load Windows calls ordinary, and gigabytes free.
        #expect(!MatteWays.memoryIsShort(load: 55, available: 8 * gigabyte))
        #expect(!MatteWays.memoryIsShort(load: 89, available: 2 * gigabyte))
        // Nine tenths in use, or less than a gigabyte and a half free: short.
        #expect(MatteWays.memoryIsShort(load: 90, available: 8 * gigabyte))
        #expect(MatteWays.memoryIsShort(load: 97, available: 2 * gigabyte))
        #expect(MatteWays.memoryIsShort(load: 40, available: gigabyte))
        #expect(MatteWays.memoryIsShort(load: 40, available: MatteWays.shortAvailable - 1))
        #expect(!MatteWays.memoryIsShort(load: 40, available: MatteWays.shortAvailable))
        // Short of memory, a PC with a card takes the processor's ways alone.
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let ledger = MatteLedger(machine: pc(64, cores: 16, card: 16), defaults: defaults, version: "9.9")
        #expect(ledger.ways(longest: 3000, short: false).first == .fineOnCard)
        #expect(!ledger.ways(longest: 3000, short: true).contains { $0.onCard })
        #expect(ledger.ways(longest: 3000, short: true).last == .light)
    }
}
