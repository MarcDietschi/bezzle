# Shaders

Keeps a website's WebGL canvas live: the page's GLSL turned into Metal on the Mac and into
Direct3D 11 on Windows, and a recorded WebGL frame drawn into a picture or a texture, at any size,
in tiles, from any thread. It has no part of the app in it. glslang and SPIRV-Cross are vendored
in `Sources/ShaderCompiler` (below). Both platforms upgrade the GLSL, compile it and work out each
draw with the same code, and draw the same frames to within a level or two of 255 (Agreement).

```swift
let renderer = ShaderRenderer.shared!            // nil where Metal is not available
let interface = try renderer.interface(of: vertex, fragment)   // what the program takes
try renderer.check(frame)                        // throws when a program does not translate or build
let image = try renderer.image(of: frame, pixels: CGSize(width: 2880, height: 1800))
let tile = try renderer.image(of: frame, pixels: CGSize(width: 512, height: 512),
                              region: CGRect(x: 0, y: 0, width: 256, height: 256))
try renderer.draw(frame, into: texture, region: nil, commandBuffer: commands)   // the caller commits
```

A frame is what a page drew between two clears:

```swift
let draw = ShaderDraw(vertex: vertexSource, fragment: fragmentSource,
                      uniforms: ["u_time": [t], "u_resolution": [1440, 900], "u_colors": colors],
                      attributes: ["a_position": .init(components: 2, values: positions)],
                      indices: indices, mode: .triangles, count: indices.count,
                      textures: ["u_image": picture], sampling: ["u_image": .init(wrapS: .repeat, wrapT: .repeat)],
                      blend: .premultipliedOver, viewport: nil)
let frame = ShaderFrame(size: CGSize(width: 1440, height: 900), clear: [0, 0, 0, 0], draws: [draw])
```

On Windows the API is the same but for its pictures: `ShaderPicture`, which on the Mac is `CGImage`,
is there a picture's premultiplied RGBA pixels, rows top first (as Core Graphics keeps a picture on
the Mac), and `image(of:)` returns one; there is no `draw(into:)`. `ShaderRenderer.shared` draws on
the graphics card, or with WARP, Windows' own Direct3D on the processor, where there is none
(`adapter` says which); `ShaderRenderer(software: true)` takes WARP anyway.

For a page that draws a fragment shader alone, `ShaderDraw.fullSurface(fragment:uniforms:textures:)`
draws it over everything with `ShaderDraw.fullSurfaceVertex` (`attribute vec2 a_position`) and its
two triangles, `ShaderDraw.fullSurfacePositions`.

## What a draw takes

| | |
|---|---|
| `uniforms` | By GLSL name. An array whole as `u_colors` (flattened) or from an element on as `u_colors[1]`, as `uniform3fv` on that location sets it; struct members as `u_light.color` and `u_lights[1].color`; members of a WebGL 2 uniform block by their names, `Block.member` when the block has an instance name. Ints and bools as floats, matrices column-major. Unset uniforms read 0, as in WebGL |
| `attributes` | By name: numbers per vertex, tightly packed, or the constant of a disabled array. A vec4 given two numbers reads z = 0 and w = 1; an attribute never given reads 0, 0, 0, 1. Matrix attributes take their columns one after the other |
| `indices`, `first`, `count` | drawElements' indices (nil for drawArrays); `first` is the first vertex, or for drawElements the first index (the byte offset divided by 4). A draw that would read past an array draws nothing, as WebGL refuses it |
| `mode` | All of WebGL's, fans and line loops made into triangles and strips |
| `textures`, `sampling` | Sampler uniform name to its picture and to how WebGL's `texParameteri` left its texture (wrap, filters, mipmaps). Missing sampling is clamped and linear without mipmaps, which is what pages nearly always set, not WebGL's default. A samplerCube takes its six faces stacked top to bottom (+X, -X, +Y, -Y, +Z, -Z). A sampler without a picture reads opaque black |
| `flipsTextures`, `premultipliesTextures` | UNPACK_FLIP_Y_WEBGL and UNPACK_PREMULTIPLY_ALPHA_WEBGL |
| `blend` | blendFuncSeparate, blendEquationSeparate and blendColor; nil for no blending |
| `viewport` | In drawing-buffer pixels from the bottom left, as WebGL's; nil for all of it |

`ShaderFrame` also carries the context's attributes: `alpha` (false makes the result opaque),
`premultipliedAlpha` (false has the colours multiplied by their alpha before they are handed on)
and `antialias` (four samples on the edges of triangles, lines and points), each as WebGL's default.

## Conventions kept

- **gl_FragCoord** reads drawing-buffer pixels from the bottom left, pixel centres at .5, however
  the output is scaled or which region of it is drawn: a uniform Bezzle adds maps Metal's
  position onto it where the shader reads it. Its z and w are WebGL's (depth range 0 to 1, 1/w).
  Derivatives follow the output's pixels, so at twice the size `dFdx(gl_FragCoord.x)` is 0.5;
  `dFdy` runs up as in WebGL.
- **Geometry**: clip space as the vertex shader gives it lands as in WebGL, +y at the top of the
  picture and z from -w to w; the viewport's part of clip space is mapped onto the region drawn,
  and what falls outside the viewport is cut. Counter-clockwise triangles face the front.
  `gl_PointSize` grows with the output; lines stay one output pixel wide.
- **Textures** sample as WebGL's: without UNPACK_FLIP_Y_WEBGL, t = 0 is the picture's top row;
  with it, the picture is turned upside down on upload. Colours are taken in sRGB and, unless
  UNPACK_PREMULTIPLY_ALPHA_WEBGL, not premultiplied.
- **The result** is a CGImage, top row first, RGBA in sRGB, premultiplied as the canvas
  composites it: with `premultipliedAlpha` (WebGL's default) what the shaders wrote is taken as
  premultiplied as it is, exactly as the browser takes it, so colours brighter than their alpha
  add light over what is behind, as on the page. With `premultipliedAlpha: false` the colours are
  multiplied by alpha first; with `alpha: false` alpha is 1. `draw(into:)` writes the same into a
  BGRA8 or RGBA8 texture (not an sRGB format, which would encode the values a second time).

## How it works

Shared by both platforms: `Upgrade.swift`, `Scanner.swift`, `Layout.swift` (what the compilers
laid out), `Plan.swift` (each draw worked out: vertex buffers, fans and loops as indices, the
viewport's cut, uniforms packed), `Cache.swift`, `Types.swift`, and in C++ `Bridge/GLSL.cpp`,
`Common.cpp` and `Cross.cpp` (SPIRV-Cross's reflection). Each platform builds its own back end
alone (`Package.swift`): `Metal/` with `Bridge/MSL.cpp`, or `Direct3D/` with `Bridge/HLSL.cpp` and
the C++ target `ShaderDirect3D`.

1. **Upgrade** (`Upgrade.swift`, `Scanner.swift`). glslang makes SPIR-V only from GLSL ES 3.10,
   so the page's GLSL ES 1.00 or 3.00 is rewritten token by token, leaving comments, macros and
   the preprocessor to glslang: the version line becomes 3.10 (`#line 1` keeps the page's line
   numbers in messages, `__VERSION__` still reads 100 or 300); in WebGL 1, `attribute` and
   `varying` become `in` and `out`, `gl_FragColor` and `gl_FragData` declared outputs,
   `texture2D`, `textureCube`, `texture2DLodEXT` and their kin `texture`, `textureLod`, ..., and
   extension lines for what 3.10 has built in go. Names a page may use for its own things in its
   version but 3.10 keeps for itself (`texture`, `sample`, `round`, `uint`, `buffer`, ...) get a
   `bezzle_` before them and are named back in reflection; the lists were found by asking glslang
   which words each version takes (`LanguageTests.howTheListsWereFound`, with `bz_parses`), and
   a test translates every word in them. So are 226 names WebGL allows that SPIRV-Cross leaves
   as they are and the Metal or HLSL compiler refuses (C++'s keywords, `float2`, `private`,
   `register`...: `keptByTheBackEnds`, found by building each with both and tested so, values
   and all), on both platforms alike. lowp and mediump become highp, as Metal computes in 32
   bits anyway. The page's `main` is called from one of Bezzle's, which maps clip space and
   gl_FragCoord as above. A depth written goes to a plain variable, as no depth buffer is kept.
   Globals may start from uniforms and other globals, which is not GLSL ES but which browsers
   take in WebGL 1 (glslang's `GL_EXT_shader_non_constant_global_initializers`).
2. **GLSL to SPIR-V** (`Bridge/GLSL.cpp`): glslang under relaxed Vulkan rules, as
   `glslangValidator -V -R --auto-map-locations --auto-map-bindings`: loose uniforms land in one
   default uniform block, both stages are linked, and varyings get one location in both by name.
   glslang's reflection gives the interface as WebGL lists it (active uniforms and attributes).
3. **SPIR-V to MSL** (`Bridge/MSL.cpp`): SPIRV-Cross, MSL 2.3 for macOS, clip space z fixed up
   for Metal; uniform blocks at `buffer(0)` on, textures and samplers at `texture(0)` and
   `sampler(0)` on, vertex buffers from `buffer(14)`. Each stage's layout (every member's offset,
   array and matrix stride, read before SPIRV-Cross renames anything, so a uniform keeps its
   page's name) goes back to Swift as JSON (`Bridge/Cross.cpp`). The C API
   (`include/ShaderCompiler.h`) is plain C; calls into glslang and SPIRV-Cross are serialised inside.
4. **Metal** (`Program.swift`, `Renderer.swift`): the MSL is compiled with safe math, pipeline
   states are made per vertex layout, pixel format, sample count and blending. A draw's uniforms
   are packed into each stage's blocks by name. Programs, pipeline states, uploaded pictures
   (at most 48 and 512 MB) and sampler states are kept by what they are made of, made once
   however many threads ask for them at the same moment, so the tiles of one frame share them.
   `image(of:)` and `draw(into:)` may be called from any thread, many at once.

On Windows, 3 and 4 are:

3. **SPIR-V to HLSL** (`Bridge/HLSL.cpp`): SPIRV-Cross, shader model 5.0, the same clip space fix
   and the layout in the same JSON; uniform blocks at `b0` on, textures and samplers at `t0` and
   `s0` on, attributes at `TEXCOORD<location>` (a matrix's columns each its own). Then three
   things Direct3D 11 needs that Metal does not: the pixel stage's inputs are declared as the
   vertex stage's outputs are, in their order and with their interpolation, a placeholder where
   it reads nothing, since Direct3D links the stages by register (WebGL by name); its derivatives
   are fine ones (`ddx_fine`), as Metal's are, where WARP's `ddx` is coarse; and two geometry
   shaders are written from the vertex stage's outputs: one draws each point as a square
   `gl_PointSize` pixels across with `gl_PointCoord` (Direct3D 11 draws points one pixel big;
   the upgrade gives the point size and coordinate as varyings for it), none whose centre is out
   of clip space and none over 511 pixels, as Metal; the other draws lines with antialias as
   rectangles one pixel wide, as Metal does (Direct3D's own are wider).
4. **Direct3D 11** (`Direct3D/`, `Sources/ShaderDirect3D/Direct3D.cpp`): Windows' own HLSL
   compiler (d3dcompiler_47, with IEEE strictness as Metal's safe math), input layouts per vertex
   layout (a constant attribute read once per instance, of one instance), blend and sampler
   states, textures uploaded as the Mac's (`Packing.straighten`, the same flip and cube faces) and
   kept the same way, four samples with the standard pattern, the opaque and premultiplying passes
   by blending, and the frame read back from a staging texture. The device's context is used under
   a lock; everything else may be made on any thread. Direct3D has one blend constant, so
   CONSTANT_ALPHA factors take its alpha as the colour, which is exact unless a draw also takes
   CONSTANT_COLOR.

## What WebGL does that this does not (yet)

- **Framebuffers and render to texture**: a frame is what was drawn to the canvas; passes into
  textures that later draws read (feedback, blur chains, ping-pong simulations) are not drawn.
- **Depth and stencil**: no depth or stencil buffer, so no depth test (WebGL's is off by
  default) and `gl_FragDepth` has no effect. No face culling, `colorMask`, scissor test,
  `polygonOffset`, `sampleCoverage` or `lineWidth` other than 1.
- **Instanced drawing**, transform feedback, `drawBuffers` beyond the first output, multiple
  clears within a frame (only the first, as `clear`).
- **WebGL 2 textures** other than sampler2D and samplerCube with float results: 3D, array,
  shadow and integer samplers make `interface` and `check` throw. Textures come from pictures,
  so data textures uploaded from typed arrays (float textures, LUMINANCE, ALPHA) need the app
  to make a picture of them. Texture LOD clamps, anisotropy and `texelFetch` beyond the picture
  are as Metal does them.
- **WebGL 2 uniform blocks** are filled member by member from `uniforms`, not from the bytes the
  page gave `bufferData`.
- **preserveDrawingBuffer**: every frame starts from its clear.
- WebGL 1 rules ES 3.10 no longer has: user functions that overload a built-in with a new
  signature, and the few constants ES 3.00 renamed (`gl_MaxVaryingVectors`).

## Agreement

`AgreementTests` draws 51 frames that cover what the two back ends could part on: gl_FragCoord at
two and four times and in uneven regions, depth, w and perspective, derivatives, faces, the
viewport, points (sized, with gl_PointCoord, cut by a tile, antialiased), lines, fans, antialiased
edges, pictures (nearest, linear, flipped, premultiplied, repeated, mirrored, mipmapped, cubes),
every blend factor and equation and the constant, the canvas not premultiplied and opaque,
indices, matrices, attributes, uniforms of every kind and WebGL 2 blocks, and the real-world
shaders whole and in tiles. `Windows/VM/shader-agreement.sh` draws them with Metal here, then with
Direct3D in the VM, and compares.

On 2026-11-13 (WARP in the VM against an M5 Pro), of 255: 31 samples alike to the byte; 16 at most
1 or 2 apart (linear filtering weighs texels its own way, blending rounds); the gradient mesh at
most 4 on 0.006% of its channels (simplex noise in the vertex stage); one film grain pixel 21
apart (a hash through `fract` that the last bit of a float turns); lines one pixel wide differ in
the pixel a tie lights (0.1% of the channels) and antialiased lines in the samples a line passes
exactly through (1.9%). Each sample's tolerance, and why where it is more than rounding, is in
the test.

## Measured

On an M5 Pro, 2026-11-13 (`swift test --filter MeasureTests` prints them):

| | |
|---|---|
| Build from clean | 13 s (`swift build`, debug or release alike: the C++ is always built with -O2) |
| The first program in a process | 60 ms, glslang setting up its tables once |
| A typical program, after that | GLSL to MSL 1 to 3 ms, Metal's compiler 7 to 25 ms (a grain shader 8 ms, a gradient mesh with simplex noise 24 ms) |
| A 1440 by 900 frame, into a CGImage | 0.4 to 0.8 ms for full-surface shaders, 1.7 ms for a 2,400 triangle mesh with noise in its vertex shader; 2880 by 1800, 2.2 ms |

On Windows, in the test VM (WARP on the processor, 8 Arm cores shared with other builds,
2026-11-13): GLSL to HLSL 2 to 5 ms, Direct3D's compiler 5 to 9 ms (the gradient mesh 50 to
120 ms); a 1440 by 900 frame 2 to 9 ms for the grain, 9 to 20 ms for the Shadertoy, 7 to 10 ms
for the mesh, which at 2880 by 1800 takes 27 to 39 ms. A graphics card draws them far faster.

## Working on it

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
MTL_DEBUG_LAYER=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # with Metal's validation
```

On Windows (in the VM, in a folder `Windows/VM/sync.sh` filled), `swift test -j 2` in
`Packages\Shaders` runs the same tests with Direct3D, all but the one that draws into a Metal
texture; `Windows/VM/shader-agreement.sh` compares the two.

The tests check pixels: WebGL's conventions (`ConventionsTests`), GLSL as pages write it
(`LanguageTests`), WebGL's state (`DrawingTests`, sixteen tiles drawn at once among them),
shaders as sites write them for hero backgrounds (`RealWorldTests`) and the two back ends
against each other (`AgreementTests`).

## Vendored

| | Version | Licence |
|---|---|---|
| glslang | 16.6.0 (https://github.com/KhronosGroup/glslang, tag 16.6.0, e1b562a) | BSD 3-Clause for its core; parts under BSD 2-Clause, MIT and Apache 2.0 (Khronos); the preprocessor also under NVIDIA's 2002 licence; `glslang_tab.cpp`, made by Bison, under GPL 3 with Bison's exception, which lets it be part of any program. All in `glslang/LICENSE.txt` and `glslang/LICENSES` |
| SPIRV-Cross | vulkan-sdk-1.4.363.0 (https://github.com/KhronosGroup/SPIRV-Cross, f11ba9f) | Apache 2.0 or MIT, at the user's choice (Arm Limited, Hans-Kristian Arntzen, The Brenwill Workshop); the SPIR-V headers MIT (Khronos). `SPIRV-Cross/LICENSE` and `SPIRV-Cross/LICENSES` |

Taken from glslang: `glslang/Include`, `glslang/Public` (`ShaderLang.h`, `ResourceLimits.h`),
`glslang/MachineIndependent` with its preprocessor (without the grammar `glslang.y` and
`pch.h`), `glslang/GenericCodeGen`, `glslang/OSDependent/osinclude.h`, `Unix/ossource.cpp` and `Windows/ossource.cpp`,
`glslang/ResourceLimits/ResourceLimits.cpp`, and `SPIRV` without its C interface and without
`SpvTools.cpp` (SPIRV-Tools, the optimizer, is left out: `ENABLE_OPT=0`). Not taken: HLSL, the C
interfaces, the command line, tests and test shaders. `glslang/glslang/build_info.h` is made
from `build_info.h.tmpl` with the version, by hand. From SPIRV-Cross: the parser, the common
compiler, its GLSL, MSL and HLSL back ends and their headers (`spirv_cfg`, `spirv_common`,
`spirv_cross`, `spirv_cross_containers`, `spirv_cross_error_handling`, `spirv_cross_parsed_ir`,
`spirv_glsl`, `spirv_msl`, `spirv_hlsl`, `spirv_parser`, `spirv.hpp`, `GLSL.std.450.h`,
`NonSemanticShaderDebugInfo100.h`); not its C API, C++ and reflection back ends, tests or
shaders. The Mac builds the MSL back end and glslang's Unix file alone, Windows the HLSL one and
its Windows file. Bezzle for Windows shows the licences in About Bezzle (`Windows/Credits`). Nothing in them is changed. They are built with `NDEBUG` (an assertion in glslang
otherwise stops the process on some inputs) and without warnings shown.

`Bridge/`, `include/ShaderCompiler.h` and `Sources/ShaderDirect3D` are Bezzle's own.

To update: clone a newer release of each with `git clone --depth 1 --branch <tag>` into a
scratch folder outside the repository, copy the same files over these (only copying, running none
of their scripts), write `build_info.h` from the new template with the new version, copy the
licence files, and run the tests. When glslang adds words to a version, the lists in
`Upgrade.swift` may need them: `howTheListsWereFound` shows how to ask glslang.
