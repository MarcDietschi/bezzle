// swift-tools-version: 5.9
import PackageDescription

// libwebp 1.6.0 (https://chromium.googlesource.com/webm/libwebp), its encoder and what that uses,
// for exporting WebP files, which ImageIO reads but does not write. See README.md.
let package = Package(
    name: "WebP",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WebP", targets: ["WebP"])],
    targets: [
        .target(
            name: "WebP",
            path: "Sources/WebP",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("WEBP_USE_THREAD"),
            ]
        ),
    ]
)
