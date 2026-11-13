// swift-tools-version: 6.2
import PackageDescription

// Keeps a website's WebGL canvas live: its GLSL turned into Metal on the Mac and into Direct3D 11
// on Windows, and its recorded frame drawn into an image or a texture. glslang 16.6.0 and
// SPIRV-Cross vulkan-sdk-1.4.363.0 are vendored in Sources/ShaderCompiler, always built optimized,
// also inside a Debug build of the app. See README.md.
//
// What both platforms share is the upgrade of a page's GLSL, glslang, SPIRV-Cross's reflection
// and the working out of each draw (Sources/Shaders); each builds only its own back end: Metal
// (Sources/Shaders/Metal, Bridge/MSL.cpp) or Direct3D (Sources/Shaders/Direct3D, Bridge/HLSL.cpp,
// Sources/ShaderDirect3D).

#if os(Windows)
let otherBackEnd = ["Bridge/MSL.cpp", "SPIRV-Cross/spirv_msl.cpp", "glslang/glslang/OSDependent/Unix"]
let otherSwift = ["Metal"]
let backEnd: [Target.Dependency] = ["ShaderDirect3D"]
let backEndTargets: [Target] = [
    .target(
        name: "ShaderDirect3D",
        path: "Sources/ShaderDirect3D",
        publicHeadersPath: "include",
        cxxSettings: [.define("NDEBUG"), .define("WIN32_LEAN_AND_MEAN"), .define("NOMINMAX"), .unsafeFlags(["-O2"])],
        linkerSettings: [.linkedLibrary("d3d11"), .linkedLibrary("dxgi"), .linkedLibrary("d3dcompiler")]
    ),
]
#else
let otherBackEnd = ["Bridge/HLSL.cpp", "SPIRV-Cross/spirv_hlsl.cpp", "glslang/glslang/OSDependent/Windows"]
let otherSwift = ["Direct3D"]
let backEnd: [Target.Dependency] = []
let backEndTargets: [Target] = []
#endif

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
            ] + otherBackEnd,
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
            dependencies: ["ShaderCompiler"] + backEnd,
            path: "Sources/Shaders",
            exclude: otherSwift
        ),
        .testTarget(
            name: "ShadersTests",
            dependencies: ["Shaders", "ShaderCompiler"],
            path: "Tests/ShadersTests"
        ),
    ] + backEndTargets,
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
