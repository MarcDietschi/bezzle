// swift-tools-version: 6.2
import PackageDescription

// Bezzle in a browser: the app's own model and renderer compiled to WebAssembly.
// `Sources/BezzleCore/Shared` links to the app's sources, so both build the same code. Where those
// import Apple frameworks that WebAssembly lacks, the modules of the same name here stand in:
// `CoreGraphics` records each drawing call for CanvasKit to play back in the page.
// Build with the swift.org toolchain: see README.md.

let isolation: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableExperimentalFeature("Extern"),
    .unsafeFlags(["-Xfrontend", "-disable-availability-checking", "-Xfrontend", "-import-module", "-Xfrontend", "CoreGraphics"]),
]

let package = Package(
    name: "BezzleWeb",
    targets: [
        .target(name: "CoreGraphics", swiftSettings: [.enableExperimentalFeature("Extern")]),
        .target(name: "AppKit", dependencies: ["CoreGraphics"]),
        .target(name: "CryptoKit"),
        .target(name: "ImageIO", dependencies: ["CoreGraphics"]),
        .target(name: "UniformTypeIdentifiers", dependencies: ["CoreGraphics"]),
        .target(name: "CoreImage", dependencies: ["CoreGraphics"]),
        .target(name: "CoreText", dependencies: ["CoreGraphics"]),
        .target(name: "QuartzCore", dependencies: ["CoreGraphics"]),
        .executableTarget(
            name: "BezzleCore",
            dependencies: ["CoreGraphics", "AppKit", "CryptoKit", "ImageIO", "UniformTypeIdentifiers", "CoreImage", "CoreText", "QuartzCore"],
            // Live co-working seals its messages with CryptoKit; the browser would use WebCrypto.
            exclude: ["Shared/Model/Live.swift"],
            swiftSettings: isolation,
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor", "-Xlinker", "-z", "-Xlinker", "stack-size=8388608"])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
