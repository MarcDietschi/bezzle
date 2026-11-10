import Testing
import CoreGraphics
import Foundation
@testable import Bezzle

/// What is shown of a picture being cut out, and which way each Mac makes its matte: how far the
/// work is said to be (`CutoutPace`), the line drawn in round the subject (`CutoutLoop`), and the
/// ways a Mac of each size takes (`SubjectModel`).
struct CutoutWorkTests {
    // MARK: How far along

    /// The pace sampled every 20th of a second from `from` to `to`.
    private func samples(_ pace: CutoutPace, _ from: Double, _ to: Double) -> [Double] {
        stride(from: from, through: to, by: 0.05).map { pace.done(at: $0) }
    }

    @Test func theWorkMovesAllTheWhileAndIsDoneOnlyAtItsEnd() {
        var pace = CutoutPace(expected: [.look: 0.5, .matte: 1.5, .finish: 0.5], at: 100)
        #expect(pace.done(at: 100) == 0)
        var shown: [Double] = []
        pace.begin(.look, at: 100)
        shown += samples(pace, 100, 100.4)
        // The model is not loaded yet, which the work only knows now.
        pace.begin(.load, expecting: [.load: 3, .matte: 2], at: 100.4)
        shown += samples(pace, 100.4, 103)
        pace.begin(.matte, at: 103)
        // The matte takes five times as long as it did before: it still moves, ever slower.
        shown += samples(pace, 103, 113)
        pace.begin(.finish, at: 113)
        shown += samples(pace, 113, 113.6)
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(shown.allSatisfy { $0 >= 0 && $0 <= CutoutPace.most })
        pace.end(at: 113.6)
        #expect(pace.done(at: 113.6) == 1 && pace.done(at: 200) == 1)
        #expect(abs((pace.took[.matte] ?? 0) - 10) < 0.001 && abs((pace.took[.load] ?? 0) - 2.6) < 0.001)
    }

    @Test func aStepThatTakesLongerThanBeforeNeverStandsStill() {
        var pace = CutoutPace(expected: [.matte: 1], at: 0)
        pace.begin(.matte, at: 0)
        var last = pace.done(at: 0)
        // Sixty times as long as expected: more is shown with every second, and never all of it.
        for second in 1...60 {
            let now = pace.done(at: Double(second))
            #expect(now > last && now < CutoutPace.most)
            last = now
        }
    }

    @Test func aStepBeginningNeverJumps() {
        var pace = CutoutPace(expected: [.look: 1, .matte: 1, .finish: 1], at: 0)
        pace.begin(.look, at: 0)
        let before = pace.done(at: 0.3)
        // Told that far more lies ahead than was thought: what is shown stays where it is.
        pace.begin(.load, expecting: [.load: 30, .matte: 20], at: 0.3)
        #expect(abs(pace.done(at: 0.3) - before) < 1e-9)
        // And a step over sooner than expected takes it no further back.
        pace.begin(.finish, at: 0.4)
        #expect(pace.done(at: 0.4) >= before)
        // Nothing more is heard once it has ended.
        pace.end(at: 1)
        pace.begin(.matte, at: 2)
        #expect(pace.done(at: 2) == 1 && pace.ended == 1)
    }

    @Test func theCutComesToRestAsSomethingPulledTightDoes() {
        #expect(CutoutMotion.sprung(0) == 0 && CutoutMotion.sprung(1) == 1)
        let way = stride(from: 0.0, through: 1, by: 0.02).map(CutoutMotion.sprung)
        // A little past, and back: once over, and by no more than a tenth.
        let most = way.max() ?? 0
        #expect(most > 1.005 && most < 1.1)
        #expect(way.allSatisfy { $0 >= 0 })
        #expect(abs(CutoutMotion.untilCut - (CutoutMotion.pull + CutoutMotion.cut)) < 1e-9)
    }

    // MARK: The line drawn in

    /// A mask of `w` × `h` cells with a disc of `radius` cells round each of `middles`.
    private func discs(_ w: Int, _ h: Int, _ middles: [(x: Double, y: Double)], radius: Double) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where middles.contains(where: { hypot(Double(x) + 0.5 - $0.x, Double(y) + 0.5 - $0.y) <= radius }) {
                mask[y * w + x] = 255
            }
        }
        return mask
    }

    @Test func theLineBeginsAsTheFrameAndEndsRoundTheSubject() {
        let w = 160, h = 120
        var loop = CutoutLoop(w: w, h: h)
        #expect(!loop.found)
        // Not drawn in at all, it is the frame: one closed line along its four sides.
        let frame = loop.lines(tight: 0)
        #expect(frame.count == 1)
        for p in frame[0] {
            let toSide = min(p.x, 1 - p.x) * CGFloat(w), toTopOrBottom = min(p.y, 1 - p.y) * CGFloat(h)
            #expect(min(toSide, toTopOrBottom) < 1.5 && p.x > -0.02 && p.x < 1.02 && p.y > -0.02 && p.y < 1.02)
        }
        // Before the subject is known it only comes loose of the frame, and stays near it.
        let loose = loop.lines(tight: 0.5)
        #expect(loose.count == 1)
        #expect(loose[0].allSatisfy { $0.x > 0 && $0.x < 1 && $0.y > 0 && $0.y < 1 })

        loop.find(discs(w, h, [(80, 60)], radius: 30))
        #expect(loop.found)
        // Drawn all the way in, it lies on the subject's outline.
        let tight = loop.lines(tight: 1)
        #expect(tight.count == 1)
        for p in tight[0] {
            let far = hypot(Double(p.x) * Double(w) - 80, Double(p.y) * Double(h) - 60)
            #expect(abs(far - 30) < 2.5)
        }
        // Half way, it lies between the two: outside the subject, inside the frame.
        let half = loop.lines(tight: 0.5)
        #expect(half.count == 1)
        for p in half[0] {
            let far = hypot(Double(p.x) * Double(w) - 80, Double(p.y) * Double(h) - 60)
            #expect(far > 31 && p.x > 0.01 && p.x < 0.99 && p.y > 0.01 && p.y < 0.99)
        }
        // It closes in steadily: what it holds grows less the tighter it is drawn.
        let held = stride(from: 0.0, through: 1, by: 0.1).map { area(loop.lines(tight: $0)) }
        #expect(zip(held, held.dropFirst()).allSatisfy { $0 > $1 })
    }

    /// What closed lines hold of the frame, by the shoelace formula.
    private func area(_ lines: [[CGPoint]]) -> Double {
        lines.reduce(0) { sum, line in
            var twice = 0.0
            for i in line.indices {
                let a = line[i], b = line[(i + 1) % line.count]
                twice += Double(a.x * b.y - b.x * a.y)
            }
            return sum + abs(twice) / 2
        }
    }

    @Test func oneLinePartsRoundTwoSubjects() {
        let w = 160, h = 80
        var loop = CutoutLoop(w: w, h: h)
        loop.find(discs(w, h, [(40, 40), (120, 40)], radius: 20))
        #expect(loop.lines(tight: 0).count == 1)
        let tight = loop.lines(tight: 1)
        #expect(tight.count == 2)
        // Each begins at its point furthest to the top left, and goes round clockwise as the screen has it.
        for line in tight {
            var twice = 0.0
            for i in line.indices {
                let a = line[i], b = line[(i + 1) % line.count]
                twice += Double(a.x * b.y - b.x * a.y)
            }
            #expect(twice > 0)
            func far(_ p: CGPoint) -> CGFloat { p.x * CGFloat(w) + p.y * CGFloat(h) }
            #expect(line.allSatisfy { far(line[0]) <= far($0) + 0.001 })
        }
    }

    @Test func nothingFoundLeavesTheLineAsItWas() {
        var loop = CutoutLoop(w: 80, h: 80)
        loop.find([UInt8](repeating: 0, count: 80 * 80))
        #expect(!loop.found)
        // A mask of another size is no mask of this layer.
        loop.find([UInt8](repeating: 255, count: 40 * 40))
        #expect(!loop.found)
        // A layer that is no rectangle begins as its own outline.
        let round = CutoutLoop(w: 80, h: 80, inside: discs(80, 80, [(40, 40)], radius: 38))
        let outline = round.lines(tight: 0)
        #expect(outline.count == 1)
        #expect(outline[0].allSatisfy { abs(hypot(Double($0.x) * 80 - 40, Double($0.y) * 80 - 40) - 38) < 2.5 })
        let cells = CutoutLoop.cells(for: CGSize(width: 900, height: 600))
        #expect(cells.w == 160 && cells.h == 107)
    }

    // MARK: Which way a Mac takes

    private func mac(_ gigabytes: Double, cores: Int, arm: Bool = true) -> SubjectModel.Machine {
        SubjectModel.Machine(memory: UInt64(gigabytes * 1_073_741_824), fastCores: cores, appleSilicon: arm)
    }

    @Test func eachMacTakesTheWayItCanAfford() {
        typealias Route = SubjectMatte.Route
        let large = 2048, small = 1200
        // A small Mac never takes more than the light size on its processor, whatever the picture.
        #expect(SubjectModel.routes(longest: large, on: mac(8, cores: 4)) == [Route.light])
        #expect(SubjectModel.routes(longest: small, on: mac(12, cores: 8)) == [Route.light])
        // A Mac of 16 GB holds the light size on its GPU, whatever the picture.
        #expect(SubjectModel.routes(longest: large, on: mac(16, cores: 4)) == [Route.lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: large, on: mac(16, cores: 8)) == [Route.lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: small, on: mac(18, cores: 8)) == [Route.lightOnGPU, .light])
        // Only a Mac with memory to spare holds the fine size on its GPU, and only for a large picture.
        #expect(SubjectModel.routes(longest: large, on: mac(24, cores: 4)) == [Route.fineOnGPU, .lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: large, on: mac(24, cores: 8)) == [Route.fineOnGPU, .fine, .lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: small, on: mac(24, cores: 8)) == [Route.lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: large, on: mac(36, cores: 10)) == [Route.fineOnGPU, .fine, .lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: small, on: mac(48, cores: 12)) == [Route.lightOnGPU, .light])
        #expect(SubjectModel.routes(longest: SubjectModel.fineFrom - 1, on: mac(64, cores: 12)).first == .lightOnGPU)
        #expect(SubjectModel.routes(longest: SubjectModel.fineFrom, on: mac(64, cores: 12)).first == .fineOnGPU)
        // An Intel Mac's GPU is left alone; one too small makes its cutouts without the model.
        #expect(SubjectModel.routes(longest: large, on: mac(32, cores: 8, arm: false)) == [Route.light])
        #expect(SubjectModel.routes(longest: large, on: mac(8, cores: 4, arm: false)).isEmpty)
        // No way of any Mac holds more than two fifths of its memory, and the last is the lightest.
        for gigabytes in [8.0, 16, 18, 24, 32, 36, 48, 64, 96, 128] {
            for cores in [2, 4, 8, 12, 16] {
                for longest in [small, large] {
                    let machine = mac(gigabytes, cores: cores)
                    let routes = SubjectModel.routes(longest: longest, on: machine)
                    #expect(!routes.isEmpty && routes.last == .light)
                    #expect(routes.allSatisfy { Double($0.holds) <= Double(machine.memory) * 0.4 }, "\(gigabytes) GB, \(routes)")
                }
            }
        }
        #expect(Route.all.map(\.description) == ["gpu2048", "cpu2048", "gpu1024", "cpu1024"])
        #expect(Route.fine.grade == .fine && Route.lightOnGPU.grade == .light && Route.light.function == "side1024")
    }

    /// Settings of their own for a test, gone after it.
    private func scratch() -> (UserDefaults, String) {
        let name = "BezzleTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func aWayNeverTakenBeforeIsNotTakenFirst() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SubjectModel(machine: mac(48, cores: 12), defaults: defaults, version: "9.9", find: { nil }, short: { false })
        #expect(model.ways(longest: 2048) == [.fineOnGPU, .fine, .lightOnGPU, .light])
        // Nothing made ready yet: the quickest to make ready goes first, the GPU's ways last.
        #expect(model.order(longest: 2048) == [.light, .fine, .fineOnGPU, .lightOnGPU])
        #expect(model.order(longest: 1200) == [.light, .lightOnGPU])
        #expect(!model.isReady(.light))
        // What has made a matte with this version goes first, as the Mac's ways have it.
        defaults.set(["cpu1024": "9.9"], forKey: "subjectMatte.ready")
        #expect(model.isReady(.light) && model.order(longest: 2048) == [.light, .fine, .fineOnGPU, .lightOnGPU])
        defaults.set(["cpu1024": "9.9", "gpu2048": "9.9"], forKey: "subjectMatte.ready")
        #expect(model.order(longest: 2048) == [.fineOnGPU, .light, .fine, .lightOnGPU])
        // Made ready by another version of Bezzle, it is to be made ready again.
        defaults.set(["cpu1024": "9.9", "gpu2048": "9.8"], forKey: "subjectMatte.ready")
        #expect(model.order(longest: 2048) == [.light, .fine, .fineOnGPU, .lightOnGPU])
        // Without the model there is nothing to take: cutouts are made the plain way.
        #expect(model.grade(longest: 2048) == .plain && model.cut(of: "photo") == nil)
    }

    @Test func aWayThatTookBezzleDownOrTooLongIsPassedOver() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        // Bezzle went down with two ways running: the one that asks the most is held to be it.
        defaults.set(["cpu1024", "gpu2048"], forKey: "subjectMatte.running")
        let model = SubjectModel(machine: mac(48, cores: 12), defaults: defaults, version: "9.9", find: { nil }, short: { false })
        #expect(defaults.object(forKey: "subjectMatte.running") == nil)
        #expect(model.ways(longest: 2048) == [.fine, .lightOnGPU, .light])
        #expect(model.ways(longest: 1200) == [.lightOnGPU, .light])
        // The next version of Bezzle tries it again.
        #expect(SubjectModel(machine: mac(48, cores: 12), defaults: defaults, version: "10.0", find: { nil }, short: { false }).ways(longest: 2048).first == .fineOnGPU)
        // A way that took longer than anyone waits is passed over for a lighter one.
        defaults.set(SubjectModel.patience + 15, forKey: "subjectMatte.seconds.cpu2048.warm")
        #expect(model.ways(longest: 2048) == [.lightOnGPU, .light])
        defaults.set(SubjectModel.patience - 5, forKey: "subjectMatte.seconds.cpu2048.warm")
        #expect(model.ways(longest: 2048) == [.fine, .lightOnGPU, .light])
        // While memory is short, the GPU is left alone.
        let pressed = SubjectModel(machine: mac(48, cores: 12), defaults: defaults, version: "10.0", find: { nil }, short: { true })
        #expect(pressed.ways(longest: 2048) == [.fine, .light] && pressed.ways(longest: 1200) == [.light])
    }
}
