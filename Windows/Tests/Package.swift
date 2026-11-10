// swift-tools-version: 6.2
import PackageDescription

// Tests of what Bezzle for Windows decides without asking Windows anything: which way a PC makes
// a subject matte, what it remembers of the ways, what cutouts are called, and the cells the line
// round a picture is laid on. Pure/ links to those files in ../Sources/BezzleCore/Host and to the
// shared model's files they use, so the tests run wherever Swift does, on a Mac too:
//
//     swift test --package-path Windows/Tests
//
// A package of its own, as the app's (../Package.swift) builds only on Windows.
let package = Package(
    name: "BezzleWindowsTests",
    targets: [
        .target(name: "CutoutWays", path: "Pure"),
        .testTarget(name: "CutoutWaysTests", dependencies: ["CutoutWays"], path: "CutoutWaysTests"),
    ],
    swiftLanguageModes: [.v6]
)
