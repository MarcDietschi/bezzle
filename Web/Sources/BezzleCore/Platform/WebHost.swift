import Foundation

// The page around the WebAssembly: what it does for Bezzle that Swift cannot here, such as path
// operations, which Skia does, and reading pictures and fonts. Each call hands it bytes and gets
// bytes back, synchronously: the page keeps the answer until it is taken.

@_extern(wasm, module: "bezzle", name: "call")
nonisolated private func hostCall(_ function: Int32, _ bytes: UnsafeRawPointer?, _ count: Int32) -> Int32

@_extern(wasm, module: "bezzle", name: "take")
nonisolated private func hostTake(_ into: UnsafeMutableRawPointer?)

nonisolated public enum Host {
    /// What the page is asked to do.
    public enum Function: Int32 {
        case pathOp = 1
        case image = 2
        case textLayout = 3
        case log = 4
    }

    public static func call(_ function: Function, bytes: [UInt8]) -> [UInt8] {
        let count = bytes.withUnsafeBytes { hostCall(function.rawValue, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: Int(count))
        out.withUnsafeMutableBytes { hostTake($0.baseAddress) }
        return out
    }

    public static func call(_ function: Function, doubles: [Double]) -> [Double] {
        let count = doubles.withUnsafeBytes { hostCall(function.rawValue, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var out = [Double](repeating: 0, count: Int(count) / 8)
        out.withUnsafeMutableBytes { hostTake($0.baseAddress) }
        return out
    }

    public static func call(_ function: Function, string: String) -> String {
        String(decoding: call(function, bytes: Array(string.utf8)), as: UTF8.self)
    }

    public static func log(_ message: String) {
        _ = call(.log, bytes: Array(message.utf8))
    }
}

public typealias CFString = String
public typealias CFArray = [Any]
public typealias CFData = Data
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = AnyObject
