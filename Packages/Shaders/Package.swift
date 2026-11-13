// swift-tools-version: 6.2
import PackageDescription

// Keeps a website's WebGL canvas live: its GLSL turned into Metal and its recorded frame drawn
// into an image or a texture. glslang 16.6.0 and SPIRV-Cross vulkan-sdk-1.4.363.0 are vendored
// in Sources/ShaderCompiler, always built optimized, also inside a Debug build of the app. See
// README.md.
let package = Package(
    name: "Shaders",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Shaders", targets: ["Shaders"])],
    targets: [
        .target(
            name: "ShaderCompiler",
            path: "Sources/ShaderCompiler",
            exclude: [
                "glslang/LICENSE.txt", "glslang/LICENSES", "glslang/SPIRV/spirv.hpp11",
                "SPIRV-Cross/LICENSE", "SPIRV-Cross/LICENSES",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("glslang"),
                .define("ENABLE_OPT", to: "0"),
                .define("NDEBUG"),
                .unsafeFlags(["-O2", "-w"]),
            ]
        ),
        .target(
            name: "Shaders",
            dependencies: ["ShaderCompiler"],
            path: "Sources/Shaders"
        ),
        .testTarget(
            name: "ShadersTests",
            dependencies: ["Shaders", "ShaderCompiler"],
            path: "Tests/ShadersTests"
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
