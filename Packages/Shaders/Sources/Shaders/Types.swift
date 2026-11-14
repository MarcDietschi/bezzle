#if os(Windows)
import Foundation

/// A picture a draw samples, or the one a frame draws: RGBA, 8 bits a channel, rows top first,
/// each colour multiplied by its alpha, in sRGB, as Core Graphics keeps a picture on the Mac.
/// Kept by identity, as the Mac keeps its pictures: the same picture is uploaded once.
public final class ShaderPicture: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// `width` times `height` times 4 bytes.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "A picture's pixels are width times height times 4 bytes.")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
#else
import CoreGraphics

/// A picture a draw samples: on the Mac, Core Graphics' own.
public typealias ShaderPicture = CGImage
#endif

/// A stage of a WebGL program.
public enum ShaderStage: Sendable { case vertex, fragment }

/// The type of a uniform or an attribute, as GLSL names it.
public enum ShaderType: Sendable, Equatable {
    case float, vec2, vec3, vec4
    case int, ivec2, ivec3, ivec4
    case bool, bvec2, bvec3, bvec4
    case mat2, mat3, mat4
    case sampler2D, samplerCube
    // WebGL 2 adds these.
    case uint, uvec2, uvec3, uvec4
    case mat2x3, mat2x4, mat3x2, mat3x4, mat4x2, mat4x3

    /// How many numbers one value takes in `ShaderDraw.uniforms`: a mat3 nine, a sampler one.
    public var components: Int {
        switch self {
        case .float, .int, .bool, .uint, .sampler2D, .samplerCube: 1
        case .vec2, .ivec2, .bvec2, .uvec2: 2
        case .vec3, .ivec3, .bvec3, .uvec3: 3
        case .vec4, .ivec4, .bvec4, .uvec4, .mat2: 4
        case .mat2x3, .mat3x2: 6
        case .mat2x4, .mat4x2: 8
        case .mat3: 9
        case .mat3x4, .mat4x3: 12
        case .mat4: 16
        }
    }

    public var isSampler: Bool { self == .sampler2D || self == .samplerCube }

    /// From the OpenGL constant WebGL's getActiveUniform and getActiveAttrib answer with.
    init?(glType: Int) {
        switch glType {
        case 0x1406: self = .float
        case 0x8B50: self = .vec2
        case 0x8B51: self = .vec3
        case 0x8B52: self = .vec4
        case 0x1404: self = .int
        case 0x8B53: self = .ivec2
        case 0x8B54: self = .ivec3
        case 0x8B55: self = .ivec4
        case 0x8B56: self = .bool
        case 0x8B57: self = .bvec2
        case 0x8B58: self = .bvec3
        case 0x8B59: self = .bvec4
        case 0x8B5A: self = .mat2
        case 0x8B5B: self = .mat3
        case 0x8B5C: self = .mat4
        case 0x8B5E: self = .sampler2D
        case 0x8B60: self = .samplerCube
        case 0x1405: self = .uint
        case 0x8DC6: self = .uvec2
        case 0x8DC7: self = .uvec3
        case 0x8DC8: self = .uvec4
        case 0x8B65: self = .mat2x3
        case 0x8B66: self = .mat2x4
        case 0x8B67: self = .mat3x2
        case 0x8B68: self = .mat3x4
        case 0x8B69: self = .mat4x2
        case 0x8B6A: self = .mat4x3
        default: return nil
        }
    }
}

public struct ShaderUniform: Sendable, Equatable {
    /// As WebGL names it, without the `[0]` WebGL puts after an array: `u_time`, `u_colors`,
    /// `u_light.color`, `u_lights[1].color`.
    public var name: String
    public var type: ShaderType
    /// The array's length; 1 when it is not an array.
    public var count: Int

    public init(name: String, type: ShaderType, count: Int = 1) {
        self.name = name
        self.type = type
        self.count = count
    }
}

public struct ShaderAttribute: Sendable, Equatable {
    public var name: String
    public var type: ShaderType

    public init(name: String, type: ShaderType) {
        self.name = name
        self.type = type
    }
}

/// What a program takes, as WebGL names it: the active uniforms and attributes, those the
/// shaders really use, as getActiveUniform and getActiveAttrib list them.
public struct ShaderInterface: Sendable, Equatable {
    public var uniforms: [ShaderUniform]
    public var attributes: [ShaderAttribute]

    public init(uniforms: [ShaderUniform], attributes: [ShaderAttribute]) {
        self.uniforms = uniforms
        self.attributes = attributes
    }
}

/// A program that does not translate, does not build, or a frame that cannot be drawn. The
/// description carries the compiler's log.
public struct ShaderError: Error, CustomStringConvertible, Sendable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// One drawArrays or drawElements call, with everything WebGL's state gave it.
public struct ShaderDraw: Sendable {
    public enum Mode: Sendable { case triangles, triangleStrip, triangleFan, lines, lineStrip, lineLoop, points }

    /// One attribute's data: what vertexAttribPointer reads, or the constant of a disabled array.
    public struct Attribute: Sendable {
        /// Numbers per vertex, 1 to 4 (a matrix attribute: its columns times its rows).
        public var components: Int
        /// Tightly packed, vertex after vertex. Integer attributes as floats.
        public var values: [Float]
        /// A disabled array's constant (vertexAttrib4f and its kin), used instead when set.
        public var constant: [Float]?
        /// vertexAttribDivisor: 0 for a value a vertex, n for one every n instances.
        public var divisor: Int

        public init(components: Int, values: [Float], constant: [Float]? = nil, divisor: Int = 0) {
            self.components = components
            self.values = values
            self.constant = constant
            self.divisor = divisor
        }

        /// A disabled array: every vertex reads `value`.
        public static func constant(_ value: [Float]) -> Attribute {
            Attribute(components: value.count, values: [], constant: value)
        }
    }

    /// blendFuncSeparate, blendEquationSeparate and blendColor.
    public struct Blend: Sendable, Equatable {
        public enum Factor: Sendable {
            case zero, one
            case sourceColor, oneMinusSourceColor, destinationColor, oneMinusDestinationColor
            case sourceAlpha, oneMinusSourceAlpha, destinationAlpha, oneMinusDestinationAlpha
            case constantColor, oneMinusConstantColor, constantAlpha, oneMinusConstantAlpha
            case sourceAlphaSaturate
        }

        public enum Equation: Sendable { case add, subtract, reverseSubtract, min, max }

        public var source: Factor, destination: Factor, sourceAlpha: Factor, destinationAlpha: Factor
        public var equation: Equation, equationAlpha: Equation
        /// blendColor, for the constant factors.
        public var color: [Float]

        public init(source: Factor, destination: Factor, sourceAlpha: Factor? = nil, destinationAlpha: Factor? = nil,
                    equation: Equation = .add, equationAlpha: Equation? = nil, color: [Float] = [0, 0, 0, 0]) {
            self.source = source
            self.destination = destination
            self.sourceAlpha = sourceAlpha ?? source
            self.destinationAlpha = destinationAlpha ?? destination
            self.equation = equation
            self.equationAlpha = equationAlpha ?? equation
            self.color = color
        }

        /// blendFunc(ONE, ONE_MINUS_SRC_ALPHA): premultiplied colours over what is there.
        public static let premultipliedOver = Blend(source: .one, destination: .oneMinusSourceAlpha)
        /// blendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA).
        public static let over = Blend(source: .sourceAlpha, destination: .oneMinusSourceAlpha)
    }

    /// How a texture is read: what texParameteri left on the texture bound to the sampler.
    public struct Sampling: Sendable, Hashable {
        public enum Wrap: Sendable, Hashable { case `repeat`, clampToEdge, mirroredRepeat }
        public enum Filter: Sendable, Hashable { case nearest, linear }

        public var wrapS: Wrap, wrapT: Wrap
        public var magnify: Filter, minify: Filter
        /// Between mipmap levels (a MIPMAP minifying filter); nil without mipmaps.
        public var mipmap: Filter?

        public init(wrapS: Wrap = .clampToEdge, wrapT: Wrap = .clampToEdge, magnify: Filter = .linear,
                    minify: Filter = .linear, mipmap: Filter? = nil) {
            self.wrapS = wrapS
            self.wrapT = wrapT
            self.magnify = magnify
            self.minify = minify
            self.mipmap = mipmap
        }
    }

    /// depthFunc's and stencilFunc's comparisons.
    public enum Compare: Sendable, Hashable { case never, less, equal, lessEqual, greater, notEqual, greaterEqual, always }

    /// The depth test, as enable(DEPTH_TEST), depthFunc, depthMask and depthRange left it.
    public struct Depth: Sendable, Hashable {
        public var compare: Compare
        /// depthMask: whether what passes is written.
        public var writes: Bool
        /// depthRange's near and far.
        public var near: Float, far: Float

        public init(compare: Compare = .less, writes: Bool = true, near: Float = 0, far: Float = 1) {
            self.compare = compare
            self.writes = writes
            self.near = near
            self.far = far
        }
    }

    /// The stencil test, as enable(STENCIL_TEST), stencilFuncSeparate, stencilOpSeparate and
    /// stencilMaskSeparate left it, for the faces that look at the viewer and those that look away.
    public struct Stencil: Sendable, Hashable {
        public enum Operation: Sendable, Hashable {
            case keep, zero, replace, increment, incrementWrap, decrement, decrementWrap, invert
        }

        public struct Face: Sendable, Hashable {
            public var compare: Compare
            public var reference: Int
            /// stencilFunc's mask, which both the reference and what is there are cut with.
            public var readMask: UInt32
            /// stencilMask: which bits may be written.
            public var writeMask: UInt32
            public var fail: Operation, depthFail: Operation, pass: Operation

            public init(compare: Compare = .always, reference: Int = 0, readMask: UInt32 = 0xFF, writeMask: UInt32 = 0xFF,
                        fail: Operation = .keep, depthFail: Operation = .keep, pass: Operation = .keep) {
                self.compare = compare
                self.reference = reference
                self.readMask = readMask
                self.writeMask = writeMask
                self.fail = fail
                self.depthFail = depthFail
                self.pass = pass
            }
        }

        public var front: Face, back: Face

        public init(front: Face = Face(), back: Face? = nil) {
            self.front = front
            self.back = back ?? front
        }
    }

    /// cullFace, with enable(CULL_FACE).
    public enum Cull: Sendable, Hashable { case front, back, both }

    /// polygonOffset, with enable(POLYGON_OFFSET_FILL).
    public struct Offset: Sendable, Hashable {
        public var factor: Float, units: Float

        public init(factor: Float, units: Float) {
            self.factor = factor
            self.units = units
        }
    }

    /// colorMask: which of red, green, blue and alpha a draw writes.
    public struct Channels: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let red = Channels(rawValue: 1), green = Channels(rawValue: 2), blue = Channels(rawValue: 4)
        public static let alpha = Channels(rawValue: 8)
        public static let all: Channels = [.red, .green, .blue, .alpha]
    }

    /// GLSL as the page gave it: WebGL 1 (GLSL ES 1.00) or WebGL 2 (`#version 300 es`).
    public var vertex: String
    public var fragment: String
    /// By GLSL name: "u_time". An array whole as "u_colors" (flattened) or from an element on as
    /// "u_colors[1]", as uniform3fv does; a struct's members as "u_light.color". Ints and bools
    /// as floats; matrices column-major. Samplers need nothing here: see `textures`.
    public var uniforms: [String: [Float]]
    public var attributes: [String: Attribute]
    /// drawElements' indices; nil for drawArrays.
    public var indices: [UInt32]?
    public var mode: Mode
    /// The first vertex (drawArrays) or the first index (drawElements: its offset divided by
    /// the size of an index).
    public var first: Int
    public var count: Int
    /// Sampler uniform name to its picture: "u_image", or "u_images[1]" for an array's element.
    /// A samplerCube takes its six faces stacked top to bottom (+X, -X, +Y, -Y, +Z, -Z); any
    /// other picture is used for all six. A sampler without a picture reads opaque black.
    public var textures: [String: ShaderPicture]
    /// UNPACK_FLIP_Y_WEBGL was on: pictures are turned upside down on upload.
    public var flipsTextures: Bool
    /// UNPACK_PREMULTIPLY_ALPHA_WEBGL was on: pictures are uploaded premultiplied.
    public var premultipliesTextures: Bool
    /// Sampler uniform name to how its texture is read; missing ones are clamped and linear.
    public var sampling: [String: Sampling]
    /// nil: no blending.
    public var blend: Blend?
    /// In drawing-buffer pixels, bottom-left origin as WebGL's; nil: all of it.
    public var viewport: CGRect?
    /// Sampler uniform name to the frame's target it reads (`ShaderFrame.targets`): what an
    /// earlier pass drew there, or what the frame before left.
    public var targets: [String: Int] = [:]
    /// Sampler uniform name to the numbers the page gave as a texture.
    public var data: [String: ShaderData] = [:]
    /// Samplers whose picture or numbers are kept as sRGB and read as light (WebGL 2's
    /// SRGB8_ALPHA8).
    public var decodes: Set<String> = []
    /// The depth test; nil: off, and nothing is written to the depth buffer.
    public var depth: Depth?
    /// The stencil test; nil: off.
    public var stencil: Stencil?
    /// Which faces are left out; nil: none.
    public var cull: Cull?
    /// frontFace(CW): clockwise triangles face the front.
    public var clockwiseFront = false
    /// colorMask.
    public var channels: Channels = .all
    /// The scissor box, in drawing-buffer pixels from the bottom left; nil: no scissor test.
    public var scissor: CGRect?
    public var offset: Offset?
    /// drawArraysInstanced's and drawElementsInstanced's instances.
    public var instances = 1

    public init(vertex: String, fragment: String, uniforms: [String: [Float]] = [:],
                attributes: [String: Attribute] = [:], indices: [UInt32]? = nil, mode: Mode = .triangles,
                first: Int = 0, count: Int, textures: [String: ShaderPicture] = [:], flipsTextures: Bool = false,
                premultipliesTextures: Bool = false, sampling: [String: Sampling] = [:], blend: Blend? = nil,
                viewport: CGRect? = nil) {
        self.vertex = vertex
        self.fragment = fragment
        self.uniforms = uniforms
        self.attributes = attributes
        self.indices = indices
        self.mode = mode
        self.first = first
        self.count = count
        self.textures = textures
        self.flipsTextures = flipsTextures
        self.premultipliesTextures = premultipliesTextures
        self.sampling = sampling
        self.blend = blend
        self.viewport = viewport
    }

    /// A WebGL 1 vertex shader that covers the drawing buffer with whatever `a_position` gives
    /// it, for pages that draw a fragment shader alone.
    public static let fullSurfaceVertex = """
        attribute vec2 a_position;
        void main() {
            gl_Position = vec4(a_position, 0.0, 1.0);
        }
        """

    /// Two triangles over all of clip space, for `fullSurfaceVertex`'s `a_position`.
    public static let fullSurfacePositions = Attribute(components: 2, values: [-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1])

    /// A fragment shader drawn over the whole drawing buffer with `fullSurfaceVertex`.
    public static func fullSurface(fragment: String, uniforms: [String: [Float]] = [:],
                                   textures: [String: ShaderPicture] = [:], blend: Blend? = nil) -> ShaderDraw {
        ShaderDraw(vertex: fullSurfaceVertex, fragment: fragment, uniforms: uniforms,
                   attributes: ["a_position": fullSurfacePositions], count: 6, textures: textures, blend: blend)
    }
}

/// What one frame of a WebGL canvas drew: onto the canvas alone (`clear` and `draws`), or pass
/// by pass, into textures of its own that later passes read and onto the canvas (`targets` and
/// `passes`, see Targets.swift).
public struct ShaderFrame: Sendable {
    /// Which frame of which recording this is, for a frame with passes into targets: the tiles of
    /// one frame draw those passes once, and a frame whose targets keep what the frame before
    /// left there finds it.
    public struct Identity: Hashable, Sendable {
        /// What tells the recording from every other.
        public var recording: Int
        /// What tells this frame from the recording's others. Where targets keep, its step: 0
        /// is drawn from the targets' `contents`, each step after from what the step before left.
        public var moment: Int

        public init(recording: Int, moment: Int) {
            self.recording = recording
            self.moment = moment
        }
    }

    /// The drawing buffer, in pixels.
    public var size: CGSize
    /// The RGBA it is cleared to first; nil: transparent. With `passes`, they say it.
    public var clear: [Float]?
    /// What it draws onto the canvas. With `passes`, they hold every draw and this is empty.
    public var draws: [ShaderDraw]
    /// The textures its passes draw into, by their place.
    public var targets: [ShaderTarget] = []
    /// Everything it drew, in order, when that is more than one pass onto the canvas.
    public var passes: [ShaderPass] = []
    public var identity: Identity?
    /// The context's `alpha`: false makes the canvas opaque, whatever alpha the draws leave.
    public var alpha: Bool
    /// The context's `premultipliedAlpha`: false has the canvas take its colours as not
    /// premultiplied, so they are premultiplied before they are handed on.
    public var premultipliedAlpha: Bool
    /// The context's `antialias`: edges of triangles, lines and points drawn with four samples.
    public var antialias: Bool

    public init(size: CGSize, clear: [Float]? = nil, draws: [ShaderDraw], alpha: Bool = true,
                premultipliedAlpha: Bool = true, antialias: Bool = true) {
        self.size = size
        self.clear = clear
        self.draws = draws
        self.alpha = alpha
        self.premultipliedAlpha = premultipliedAlpha
        self.antialias = antialias
    }
}
