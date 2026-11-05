// swift-tools-version: 6.0
import PackageDescription

// Checks the browser's geometry (Sources/BezzleCore/Platform/CGGeometry.swift) against Core
// Graphics on this Mac: the same operations on random rectangles, which must agree exactly.
//   cd Web/tools/geometry && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run
let package = Package(
    name: "GeometryCheck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WebGeometry"),
        .executableTarget(name: "check", dependencies: ["WebGeometry"]),
    ]
)
