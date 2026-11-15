// swift-tools-version: 6.2
import PackageDescription

// Tests of what Bezzle for Windows decides without asking Windows anything: which way a PC makes
// a subject matte, what it remembers of the ways, what cutouts are called, and the cells the line
// round a picture is laid on; in Animate, when a shape's points are taken in hand and put down,
// the Draw move's line in its chip, where the view goes when the desk turns to a film, and the
// timeline's sheet looked at closer: its ruler, the stroke that says which part shows, the wheel,
// and how many frames a second a movie of a size can have; and the moves of the cover over a design
// while it opens, against the Mac's numbers.
// Pure/, FilmPure/ and OpeningPure/ link to those files in
// ../Sources/BezzleCore/Host and to the shared model's files they use, so the tests run wherever
// Swift does, on a Mac too:
//
//     swift test --package-path Windows/Tests
//
// A package of its own, as the app's (../Package.swift) builds only on Windows.
let package = Package(
    name: "BezzleWindowsTests",
    targets: [
        .target(name: "CutoutWays", path: "Pure"),
        .testTarget(name: "CutoutWaysTests", dependencies: ["CutoutWays"], path: "CutoutWaysTests"),
        .target(name: "FilmRules", path: "FilmPure"),
        .testTarget(name: "FilmRulesTests", dependencies: ["FilmRules"], path: "FilmRulesTests"),
        .target(name: "OpeningRules", path: "OpeningPure"),
        .testTarget(name: "OpeningRulesTests", dependencies: ["OpeningRules"], path: "OpeningRulesTests"),
    ],
    swiftLanguageModes: [.v6]
)
