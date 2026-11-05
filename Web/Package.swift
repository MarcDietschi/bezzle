// swift-tools-version: 6.2
import PackageDescription

// Bezzle in a browser: the app's own model and renderer compiled to WebAssembly.
// `Sources/BezzleCore/Shared` links to the app's sources, so both build the same code. What those
// take from Apple frameworks that WebAssembly lacks is in `Sources/BezzleCore/Platform`, in the
// core's own module, so that its CGFloat, CGPoint, CGSize and CGRect stand in for Foundation's
// (which are single precision here): `CGContext` records each drawing call for CanvasKit to
// play back in the page. The modules named after the frameworks are empty, so the shared
// sources' imports find them. Build with the swift.org toolchain: see README.md.

let frameworks = ["CoreGraphics", "AppKit", "CryptoKit", "ImageIO", "UniformTypeIdentifiers", "CoreImage", "CoreText", "QuartzCore"]

let package = Package(
    name: "BezzleWeb",
    targets: frameworks.map { .target(name: $0) } + [
        // Apple's LZFSE, which shared designs are packed with in iCloud.
        .target(name: "LZFSE", exclude: ["LICENSE", "README.md"]),
        .executableTarget(
            name: "BezzleCore",
            dependencies: frameworks.map { .target(name: $0) } + ["LZFSE"],
            // Live co-working seals its messages with CryptoKit; the browser would use WebCrypto.
            // DesignTokens.swift comes from prepare.sh (see there).
            exclude: ["Shared/Model/Live.swift", "Shared/Model/Kits/Icons.deflate", "Shared/Model/DesignTokens.swift"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableExperimentalFeature("Extern"),
                .unsafeFlags(["-Xfrontend", "-disable-availability-checking"]),
            ],
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor", "-Xlinker", "-z", "-Xlinker", "stack-size=8388608"])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
