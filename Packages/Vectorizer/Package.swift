// swift-tools-version: 5.9
import PackageDescription

// Turns a picture into shapes: Bezzle's Vectorize. Plain Swift with Foundation alone, so the Mac
// app, Bezzle for Windows and a command line all build it. Always built optimized, also inside a
// Debug build of the app: unoptimized it would take minutes for what takes a second. See README.md.
let package = Package(
    name: "Vectorizer",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Vectorizer", targets: ["Vectorizer"])],
    targets: [
        .target(
            name: "Vectorizer",
            path: "Sources/Vectorizer",
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        // Traces a picture file to an SVG and measures the result: for working on the engine.
        .executableTarget(
            name: "vectorize-cli",
            dependencies: ["Vectorizer"],
            path: "Sources/vectorize-cli"
        ),
        .testTarget(
            name: "VectorizerTests",
            dependencies: ["Vectorizer"],
            path: "Tests/VectorizerTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
