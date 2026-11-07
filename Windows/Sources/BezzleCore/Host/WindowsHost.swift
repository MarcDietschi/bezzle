import Foundation
import CBezzleHost

// What the core asks of Windows that Swift does not do here: path operations, pictures and text,
// which Skia does (CBezzleHost, in C++). The same calls as the browser's page answers in
// Web/Platform/WebHost.swift, which this replaces: each call hands over bytes and gets bytes back.
// Text comes as the page's JSON (Web/WebText.swift) and goes on to Skia as structs.

nonisolated public enum Host {
    /// What the host is asked to do.
    public enum Function: Int32 {
        case pathOp = 1
        case image = 2
        case textLayout = 3
        case log = 4
    }

    public static func call(_ function: Function, bytes: [UInt8]) -> [UInt8] {
        if function == .textLayout { return Array(TextHost.answer(String(decoding: bytes, as: UTF8.self)).utf8) }
        let count = bytes.withUnsafeBytes { bz_host_call(function.rawValue, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: Int(count))
        out.withUnsafeMutableBytes { bz_host_take($0.baseAddress) }
        return out
    }

    public static func call(_ function: Function, doubles: [Double]) -> [Double] {
        let count = doubles.withUnsafeBytes { bz_host_call(function.rawValue, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var out = [Double](repeating: 0, count: Int(count) / 8)
        out.withUnsafeMutableBytes { bz_host_take($0.baseAddress) }
        return out
    }

    public static func call(_ function: Function, string: String) -> String {
        String(decoding: call(function, bytes: Array(string.utf8)), as: UTF8.self)
    }

    public static func log(_ message: String) {
        _ = call(.log, bytes: Array(message.utf8))
    }
}

/// The system font's stand-in (Inter, see Web/tools/openfonts.py): its weight by face, and the
/// optical sizes it has, which a size is held to.
nonisolated enum SystemFont {
    nonisolated(unsafe) static var weights: [String: Double] = [:]
    nonisolated(unsafe) static var opticalSizes: ClosedRange<Double>?
}

/// Text as WebText.swift asks for it, set by Skia's paragraphs (bezzle.mjs's textCall).
nonisolated enum TextHost {
    static func answer(_ json: String) -> String {
        guard let spec = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return "" }
        if let id = spec["place"] as? Int {
            let baselines = (spec["baselines"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            baselines.withUnsafeBufferPointer { bz_text_place(Int32(id), $0.baseAddress, Int32($0.count)) }
            return ""
        }
        let runs = spec["runs"] as? [[String: Any]] ?? []
        if spec["glyphs"] as? Bool == true { return glyphs(runs) }
        let width = (spec["width"] as? NSNumber)?.doubleValue ?? 100_000
        let align: Int32 = switch spec["align"] as? String {
            case "center": 1
            case "right": 2
            case "justify": 3
            default: 0
        }
        let capacity = 512
        var lines = [Double](repeating: 0, count: capacity * 6)
        var count: Int32 = 0
        let id = given(runs) { runs in
            lines.withUnsafeMutableBufferPointer { bz_text_lay(runs.baseAddress, Int32(runs.count), width, align, $0.baseAddress, Int32(capacity), &count) }
        }
        let laid = (0..<min(Int(count), capacity)).map { k in "[" + lines[k * 6..<k * 6 + 6].map { String($0) }.joined(separator: ",") + "]" }
        return "{\"id\":\(id),\"lines\":[" + laid.joined(separator: ",") + "]}"
    }

    /// The runs as one line, for a text along a curve (WebCurvedText.swift): the line's id, its
    /// width, ascent, descent and cap height, and ten numbers for each letter (BezzleHost.h).
    private static func glyphs(_ runs: [[String: Any]]) -> String {
        var capacity = 256
        while true {
            var glyphs = [Double](repeating: 0, count: capacity * 10)
            var line = [Double](repeating: 0, count: 4)
            var count: Int32 = 0
            let id = given(runs) { runs in
                glyphs.withUnsafeMutableBufferPointer { g in
                    line.withUnsafeMutableBufferPointer { bz_text_glyphs(runs.baseAddress, Int32(runs.count), g.baseAddress, Int32(capacity), &count, $0.baseAddress) }
                }
            }
            // More letters than there was room for: set again with room for all.
            if Int(count) > capacity { capacity = Int(count); continue }
            let each = (0..<Int(count)).map { k in "[" + glyphs[k * 10..<k * 10 + 10].map { String($0) }.joined(separator: ",") + "]" }
            return "{\"id\":\(id),\"line\":[" + line.map { String($0) }.joined(separator: ",") + "],\"glyphs\":[" + each.joined(separator: ",") + "]}"
        }
    }

    /// The runs as the host takes them, for as long as `body` runs.
    private static func given<Result>(_ runs: [[String: Any]], _ body: (UnsafeBufferPointer<bz_text_run>) -> Result) -> Result {
        // The runs' strings, kept alive for the call: the system font's runs ask for "System",
        // which bz_font_add registered the system font's stand-in as.
        let strings = runs.map { run -> [UnsafeMutablePointer<CChar>] in
            let family = run["family"] as? String ?? TextStyle.system
            return [run["text"] as? String ?? "", family == TextStyle.system ? "System" : family, run["face"] as? String ?? "",
                    run["features"] as? String ?? "", run["axes"] as? String ?? ""].map { strdup($0)! }
        }
        defer { strings.joined().forEach { free($0) } }
        let given: [bz_text_run] = zip(runs, strings).map { run, s in
            let system = (run["family"] as? String ?? TextStyle.system) == TextStyle.system
            let size = (run["size"] as? NSNumber)?.doubleValue ?? 12
            let face = (run["face"] as? String ?? "").replacingOccurrences(of: " Italic", with: "")
            let color = (run["color"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            return bz_text_run(
                text: s[0], family: s[1], face: s[2], size: size,
                tracking: (run["tracking"] as? NSNumber)?.doubleValue ?? 0,
                weight: system ? SystemFont.weights[face] ?? 400 : 0,
                opticalSize: system ? SystemFont.opticalSizes.map { min(max(size, $0.lowerBound), $0.upperBound) } ?? 0 : 0,
                underline: (run["underline"] as? Bool ?? false) ? 1 : 0, strike: (run["strike"] as? Bool ?? false) ? 1 : 0,
                hasColor: color.count == 4 ? 1 : 0,
                color: color.count == 4 ? (color[0], color[1], color[2], color[3]) : (0, 0, 0, 1),
                features: s[3], axes: s[4])
        }
        return given.withUnsafeBufferPointer(body)
    }
}

public typealias CFString = String
public typealias CFArray = [Any]
public typealias CFData = Data
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = AnyObject
