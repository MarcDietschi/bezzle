// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Bezzle for Windows: the app in Swift with WinUI 3, built on Windows (see README.md).
//
// - BezzleCore: the Mac app's own model and renderer, as the web core shares them (Sources/
//   BezzleCore/Shared, Platform and Web link to Web/Sources/BezzleCore), with Host/ in place of
//   the browser: CBezzleHost does with Skia (skia.ps1 builds it into Packages/skia) what the page
//   does with CanvasKit. The modules named after Apple's frameworks are the web core's empty ones.
// - Bezzle: the app, with WinUI 3 bindings that winrt.ps1 fetches into Packages/.
// - bezzle-render: draws a design's artboards to PNG files, to compare with the Mac.
// - bezzle-share: works on shared designs headless, for the Mac's tests to check.

// The architecture built for: the machine's own, or the one build.ps1 -Arch names (BEZZLE_ARCH,
// with `swift build --arch`), whose libraries are linked: an Arm machine makes x64 too.
let arch = switch Context.environment["BEZZLE_ARCH"] {
case "x64": "x86_64"
case "arm64": "aarch64"
default: Context.environment["PROCESSOR_ARCHITECTURE"] == "ARM64" ? "aarch64" : "x86_64"
}
let skiaOut = Context.packageDirectory + "\\Packages\\skia\\out\\" + (arch == "aarch64" ? "arm64" : "x64")

// SwiftPM links executables with -nostartfiles, leaving out swiftrt.obj, which registers an image's
// Swift metadata with the runtime: without it no conformance in the executable, or in what is
// linked into it, is found at run time (WinUI's wrappers then fail on their first use). So it is
// linked in by hand, from the Swift SDK (SDKROOT, which Swift's installer sets).
let swiftrt = (Context.environment["SDKROOT"] ?? "") + "\\usr\\lib\\swift\\windows\\\(arch)\\swiftrt.obj"

// The main thread's stack as big as the Mac's (8 MB; Windows gives 1 MB): what a web page is
// read into nests as deeply as its elements do, and is decoded and laid out there.
let mainStack = ["-Xlinker", "/STACK:8388608"]

// The Mac's pointers, as cursor resources (build.ps1 compiles Resources/Generated/Bezzle.rc).
let resources = Context.packageDirectory + "\\Resources\\Generated\\Bezzle.res"
let resourceFlags = FileManager.default.fileExists(atPath: resources) ? ["-Xlinker", resources] : []

// AVIF, read and written by libavif with libaom (avif.ps1 builds them into Packages/avif): linked
// into CBezzleHost when they are there, which then reads and writes it (Sources/CBezzleHost/avif.cpp).
let avifFolder = "Packages\\avif\\out\\" + (arch == "aarch64" ? "arm64" : "x64")
let hasAVIF = FileManager.default.fileExists(atPath: Context.packageDirectory + "\\" + avifFolder + "\\lib\\avif.lib")
let avifCxx: [CXXSetting] = hasAVIF ? [.headerSearchPath("../../" + avifFolder.replacingOccurrences(of: "\\", with: "/") + "/include"), .define("BEZZLE_AVIF")] : []
let avifLinking: [LinkerSetting] = hasAVIF
    ? [.unsafeFlags(["-L" + Context.packageDirectory + "\\" + avifFolder + "\\lib"]), .linkedLibrary("avif"), .linkedLibrary("aom")] : []

let frameworks = ["CoreGraphics", "AppKit", "CryptoKit", "ImageIO", "UniformTypeIdentifiers", "CoreImage", "CoreText", "QuartzCore"]

// What Skia's own build defines for code that uses it (gn desc … defines), so its headers agree.
let skiaDefines = [
    "_CRT_SECURE_NO_WARNINGS", "_HAS_EXCEPTIONS=0", "WIN32_LEAN_AND_MEAN", "NOMINMAX", "NDEBUG",
    "SK_ENABLE_PARAGRAPH", "SK_TYPEFACE_FACTORY_FREETYPE", "SK_FONTMGR_FREETYPE_EMPTY_AVAILABLE",
    "SK_CODEC_DECODES_PNG", "SK_CODEC_DECODES_PNG_WITH_LIBPNG", "SK_CODEC_ENCODES_PNG", "SK_CODEC_ENCODES_PNG_WITH_LIBPNG",
    "SK_CODEC_DECODES_JPEG", "SK_CODEC_ENCODES_JPEG", "SK_CODEC_DECODES_WEBP", "SK_CODEC_ENCODES_WEBP",
    "SK_SUPPORT_PDF", "SK_GANESH", "SK_DISABLE_TRACING",
    "SK_UNICODE_AVAILABLE", "SK_UNICODE_ICU_IMPLEMENTATION",
    "SK_SHAPER_PRIMITIVE_AVAILABLE", "SK_SHAPER_HARFBUZZ_AVAILABLE", "SK_SHAPER_UNICODE_AVAILABLE",
]
let skiaLibraries = [
    "skparagraph", "skshaper", "skunicode_icu", "skunicode_core", "skia", "harfbuzz", "icu", "freetype2",
    "libpng", "libjpeg", "libjpeg12", "libjpeg16", "libwebp", "libwebp_sse41", "zlib", "expat", "wuffs", "skcms",
    "raw_ptr", "allocator_core", "allocator_base",
]

// WebView2's SDK (winrt.ps1 fetches it into Packages\webview2): its header and its loader, linked
// in, which finds the WebView2 runtime Windows 11 has. Built without it, bringing a website in
// says it cannot be done (CBezzleHost/webview.cpp).
let webView2 = Context.packageDirectory + "\\Packages\\webview2\\build\\native"
let hasWebView2 = FileManager.default.fileExists(atPath: webView2 + "\\include\\WebView2.h")
let webView2Settings: [CXXSetting] = hasWebView2
    ? [.headerSearchPath("../../Packages/webview2/build/native/include"), .define("BEZZLE_WEBVIEW2", to: "1")] : []
let webView2Linking: [LinkerSetting] = hasWebView2
    ? [.unsafeFlags(["-L" + webView2 + "\\" + (arch == "aarch64" ? "arm64" : "x64")]), .linkedLibrary("WebView2LoaderStatic"), .linkedLibrary("version")]
    : []

let package = Package(
    name: "BezzleWindows",
    dependencies: [
        .package(path: "Packages/swift-winui"),
        .package(path: "Packages/swift-windowsappsdk"),
        .package(path: "Packages/swift-windowsfoundation"),
        .package(path: "Packages/swift-uwp"),
    ],
    targets: frameworks.map { .target(name: $0) } + [
        .target(name: "LZFSE", exclude: ["LICENSE", "README.md"]),
        // What the Mac's importers (Import/) take from Apple's Compression and Accelerate, here only.
        .target(name: "Compression", dependencies: ["CBezzleHost"]),
        .target(name: "Accelerate"),
        .target(
            name: "CBezzleHost",
            cxxSettings: [.headerSearchPath("../../Packages/skia")] + skiaDefines.map { define in
                let parts = define.split(separator: "=", maxSplits: 1).map(String.init)
                return .define(parts[0], to: parts.count > 1 ? parts[1] : nil)
            } + avifCxx + webView2Settings,
            linkerSettings: [.unsafeFlags(["-L" + skiaOut])] + skiaLibraries.map { .linkedLibrary($0) } + avifLinking
                + ["user32", "gdi32", "ole32", "advapi32", "usp10", "bcrypt", "dwmapi", "shell32", "oleaut32"].map { .linkedLibrary($0) }
                + webView2Linking
        ),
        .target(
            name: "BezzleCore",
            dependencies: frameworks.map { .target(name: $0) } + ["LZFSE", "CBezzleHost", "Compression", "Accelerate"],
            // The browser's host and Main.swift are replaced by Host/; DesignTokens.swift comes
            // from Web/prepare.sh, as for the web core. Live.swift seals with CryptoKit, which
            // Host/Sealing.swift stands in for with Windows' own cryptography. Which picture files
            // can be written is Host/PictureFormats.swift's to say (AVIF with avif.ps1's libraries).
            exclude: ["Platform/WebHost.swift", "Platform/ImageIO.swift", "Shared/Model/Kits/Icons.deflate", "Shared/Model/DesignTokens.swift"],
            // The Mac's web page reader and what runs before a page's scripts (Bezzle/Import), in
            // the core itself, for the app and the command-line tools alike.
            resources: [.embedInCode("Import/WebPageReader.js"), .embedInCode("Import/WebPageAwake.js")],
            swiftSettings: [.defaultIsolation(MainActor.self), .unsafeFlags(["-Xfrontend", "-disable-availability-checking"])]
        ),
        .executableTarget(
            name: "bezzle-render",
            dependencies: ["BezzleCore"],
            path: "Sources/BezzleRender",
            linkerSettings: [.unsafeFlags([swiftrt] + mainStack)]
        ),
        // Works on shared designs headless, for the Mac's tests to check (Sources/BezzleShare).
        .executableTarget(
            name: "bezzle-share",
            dependencies: ["BezzleCore"],
            path: "Sources/BezzleShare",
            linkerSettings: [.unsafeFlags([swiftrt])]
        ),
        .executableTarget(
            name: "Bezzle",
            dependencies: [
                "BezzleCore",
                .product(name: "WinUI", package: "swift-winui"),
                .product(name: "WinAppSDK", package: "swift-windowsappsdk"),
                .product(name: "CWinAppSDK", package: "swift-windowsappsdk"),
                .product(name: "WindowsFoundation", package: "swift-windowsfoundation"),
                .product(name: "UWP", package: "swift-uwp"),
            ],
            path: "Sources/Bezzle",
            swiftSettings: [.unsafeFlags(["-parse-as-library"]), .swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags([swiftrt, "-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"] + resourceFlags + mainStack)]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx20
)
