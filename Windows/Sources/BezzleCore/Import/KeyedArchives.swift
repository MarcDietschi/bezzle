import Foundation
import AppKit

// The texts Sketch 43 to 47 kept as keyed archives of attributed strings (SketchImporter.archived
// asks NSKeyedUnarchiver for them). Foundation here cannot read AppKit's fonts, colours and
// paragraph styles out of one, and traps on an attributed string with more than one run, so the
// archive is read here: its binary property list, and of that what a text's runs say.

/// Reads a keyed archive of an attributed string, as far as Sketch's texts need: the words, and
/// each run's font, font descriptor, colour, paragraph style and numbers. Anything else is nil.
final class NSKeyedUnarchiver {
    static func unarchivedObject(ofClasses classes: [AnyClass], from data: Data) throws -> Any? {
        guard case .dict(let archive)? = BinaryPlist.read(data), case .array(let objects)? = archive["$objects"],
              case .dict(let top)? = archive["$top"], case .uid(let root)? = top["root"] else { return nil }
        return KeyedArchive(objects: objects).attributedString(root)
    }
}

/// An attributed string read from an archive, its runs kept here rather than by Foundation.
nonisolated final class ArchivedText: NSAttributedString, @unchecked Sendable {
    private var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []

    init(_ string: String, runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])]) {
        super.init(string: string)
        self.runs = runs
    }

    required init?(coder: NSCoder) { nil }

    override func enumerateAttributes(in range: NSRange, options: NSAttributedString.EnumerationOptions = [],
                                      using block: ([NSAttributedString.Key: Any], NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for run in runs {
            let r = NSIntersectionRange(run.range, range)
            guard r.length > 0 else { continue }
            block(run.attributes, r, &stop)
            if stop.boolValue { return }
        }
    }
}

/// A value of a binary property list (bplist00), as keyed archives are written.
enum PlistValue {
    case null, bool(Bool), int(Int64), real(Double), date(Double), data(Data), string(String), uid(Int)
    case array([PlistValue]), dict([String: PlistValue])

    var number: Double? {
        switch self {
        case .int(let n): Double(n)
        case .real(let d): d
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }
}

enum BinaryPlist {
    static func read(_ data: Data) -> PlistValue? {
        let b = [UInt8](data)
        guard b.count >= 40, Array(b[0..<8]) == Array("bplist00".utf8) else { return nil }
        let t = b.count - 32
        let offsetSize = Int(b[t + 6]), refSize = Int(b[t + 7])
        func number(_ at: Int, _ size: Int) -> Int? {
            guard size > 0, size <= 8, at >= 0, at + size <= b.count else { return nil }
            var n = 0
            for i in 0..<size { n = n << 8 | Int(b[at + i]) }
            return n
        }
        guard let count = number(t + 8, 8), let top = number(t + 16, 8), let table = number(t + 24, 8),
              count > 0, count < 10_000_000, table + count * offsetSize <= t else { return nil }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count {
            guard let o = number(table + i * offsetSize, offsetSize) else { return nil }
            offsets.append(o)
        }
        var depth = 0
        func object(_ ref: Int) -> PlistValue? {
            guard ref >= 0, ref < offsets.count, depth < 512 else { return nil }
            depth += 1
            defer { depth -= 1 }
            var at = offsets[ref]
            guard at < t else { return nil }
            let marker = b[at], high = marker >> 4, low = Int(marker & 0x0F)
            at += 1
            func length() -> Int? {
                guard low == 0x0F else { return low }
                guard at < t, b[at] >> 4 == 1 else { return nil }
                let size = 1 << Int(b[at] & 0x0F)
                defer { at += 1 + size }
                return number(at + 1, size)
            }
            switch high {
            case 0x0:
                return marker == 0x08 ? .bool(false) : marker == 0x09 ? .bool(true) : .null
            case 0x1:
                let size = 1 << low
                guard let n = number(at, min(size, 8)) else { return nil }
                return .int(size == 8 ? Int64(bitPattern: UInt64(n)) : Int64(n))
            case 0x2, 0x3:
                let size = high == 0x3 ? 8 : 1 << low
                guard let n = number(at, size) else { return nil }
                let value = size == 4 ? Double(Float(bitPattern: UInt32(n))) : Double(bitPattern: UInt64(n))
                return high == 0x3 ? .date(value) : .real(value)
            case 0x4:
                guard let n = length(), at + n <= t else { return nil }
                return .data(Data(b[at..<at + n]))
            case 0x5:
                guard let n = length(), at + n <= t else { return nil }
                return .string(String(decoding: b[at..<at + n], as: UTF8.self))
            case 0x6:
                guard let n = length(), at + 2 * n <= t else { return nil }
                let units = (0..<n).map { UInt16(b[at + 2 * $0]) << 8 | UInt16(b[at + 2 * $0 + 1]) }
                return .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                guard let n = number(at, low + 1) else { return nil }
                return .uid(n)
            case 0xA:
                guard let n = length() else { return nil }
                var items: [PlistValue] = []
                for i in 0..<n {
                    guard let r = number(at + i * refSize, refSize), let v = object(r) else { return nil }
                    items.append(v)
                }
                return .array(items)
            case 0xD:
                guard let n = length() else { return nil }
                var items: [String: PlistValue] = [:]
                for i in 0..<n {
                    guard let k = number(at + i * refSize, refSize), let v = number(at + (n + i) * refSize, refSize),
                          case .string(let key)? = object(k), let value = object(v) else { return nil }
                    items[key] = value
                }
                return .dict(items)
            default:
                return nil
            }
        }
        return object(top)
    }
}

/// The objects of a keyed archive, each by its number, as NSKeyedArchiver writes them.
private struct KeyedArchive {
    let objects: [PlistValue]

    private func object(_ v: PlistValue?) -> PlistValue? {
        guard case .uid(let n)? = v else { return v }
        return n > 0 && n < objects.count ? objects[n] : nil
    }

    private func dict(_ v: PlistValue?) -> [String: PlistValue]? {
        guard case .dict(let d)? = object(v) else { return nil }
        return d
    }

    private func className(_ d: [String: PlistValue]) -> String? {
        guard let c = dict(d["$class"]), case .string(let name)? = c["$classname"] else { return nil }
        return name
    }

    private func string(_ v: PlistValue?) -> String? {
        switch object(v) {
        case .string(let s)?: return s
        case .dict(let d)?:
            if case .string(let s)? = object(d["NS.string"]) { return s }
            if case .data(let bytes)? = object(d["NS.bytes"]) { return String(decoding: bytes, as: UTF8.self) }
            return nil
        default: return nil
        }
    }

    private func data(_ v: PlistValue?) -> Data? {
        switch object(v) {
        case .data(let d)?: return d
        case .dict(let d)?:
            if case .data(let bytes)? = object(d["NS.data"]) { return bytes }
            return nil
        default: return nil
        }
    }

    private func list(_ v: PlistValue?) -> [PlistValue] {
        switch object(v) {
        case .array(let a)?: return a
        case .dict(let d)?:
            if case .array(let a)? = d["NS.objects"] { return a }
            return []
        default: return []
        }
    }

    private func number(_ v: PlistValue?) -> Double? { object(v)?.number }

    /// The words and their runs.
    func attributedString(_ root: Int) -> NSAttributedString? {
        guard root > 0, root < objects.count, case .dict(let d) = objects[root], let words = string(d["NSString"]) else { return nil }
        let length = (words as NSString).length
        // One dictionary for all of it, or a list of them that NSAttributeInfo hands out by run.
        var tables: [[NSAttributedString.Key: Any]] = []
        if let one = dict(d["NSAttributes"]), one["NS.keys"] != nil {
            tables = [attributes(one)]
        } else {
            tables = list(d["NSAttributes"]).map { dict($0).map(attributes) ?? [:] }
        }
        var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        if let info = data(d["NSAttributeInfo"]) {
            // Pairs of numbers, each seven bits a byte, low first: how long the run is, and its dictionary.
            let bytes = [UInt8](info)
            var at = 0, location = 0
            func next() -> Int? {
                var n = 0, shift = 0
                while at < bytes.count {
                    let byte = bytes[at]
                    at += 1
                    n |= Int(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return n }
                    shift += 7
                }
                return nil
            }
            while let count = next(), let index = next() {
                let run = NSRange(location: location, length: min(count, max(length - location, 0)))
                runs.append((run, index < tables.count ? tables[index] : [:]))
                location += count
            }
        } else if let first = tables.first {
            runs = [(NSRange(location: 0, length: length), first)]
        }
        return ArchivedText(words, runs: runs)
    }

    /// One run's attributes, as AppKit's objects stand in for here.
    private func attributes(_ d: [String: PlistValue]) -> [NSAttributedString.Key: Any] {
        let keys = list(d["NS.keys"]), values = list(d["NS.objects"])
        var out: [NSAttributedString.Key: Any] = [:]
        for (k, v) in zip(keys, values) {
            guard let key = string(k) else { continue }
            if let value = attribute(v) { out[NSAttributedString.Key(key)] = value }
        }
        return out
    }

    private func attribute(_ v: PlistValue) -> Any? {
        let value = object(v)
        if let n = value?.number { return NSNumber(value: n) }
        if case .string(let s)? = value { return s }
        guard case .dict(let d)? = value else { return nil }
        switch className(d) {
        case "NSFont":
            let name = string(d["NSName"]) ?? ""
            let size = CGFloat(number(d["NSSize"]) ?? 12)
            return NSFont(name: name, size: size) ?? NSFont(postscriptName: name, size: size)
        case "NSFontDescriptor":
            let a = dict(d["NSFontDescriptorAttributes"]).map(attributes) ?? [:]
            let name = a[NSAttributedString.Key("NSFontNameAttribute")] as? String
            let size = (a[NSAttributedString.Key("NSFontSizeAttribute")] as? NSNumber)?.doubleValue ?? 0
            return NSFontDescriptor(postscriptName: name, pointSize: CGFloat(size))
        case "NSColor":
            return color(d)
        case "NSParagraphStyle", "NSMutableParagraphStyle":
            let p = NSParagraphStyle()
            // As AppKit archives it: 0 left, 1 right, 2 centre, 3 justified, 4 natural.
            p.alignment = switch Int(number(d["NSAlignment"]) ?? 4) {
            case 0: .left
            case 1: .right
            case 2: .center
            case 3: .justified
            default: .natural
            }
            p.maximumLineHeight = CGFloat(number(d["NSMaxLineHeight"]) ?? 0)
            p.minimumLineHeight = CGFloat(number(d["NSMinLineHeight"]) ?? 0)
            p.paragraphSpacing = CGFloat(number(d["NSParagraphSpacing"]) ?? 0)
            return p
        default:
            return nil
        }
    }

    /// A colour as AppKit archives it: its own components when it has them, else as RGB or grey
    /// written out in words, all taken as sRGB.
    private func color(_ d: [String: PlistValue]) -> NSColor? {
        func numbers(_ key: String) -> [CGFloat] {
            guard let bytes = data(d[key]) else { return [] }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).split(separator: " ").compactMap { Double($0).map { CGFloat($0) } }
        }
        let space = Int(number(d["NSColorSpace"]) ?? 0)
        let components = numbers("NSComponents"), rgb = numbers("NSRGB"), white = numbers("NSWhite")
        if components.count >= 3, space == 1 || space == 2 {
            return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components.count > 3 ? components[3] : 1)
        }
        if rgb.count >= 3 { return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: rgb.count > 3 ? rgb[3] : 1) }
        if !white.isEmpty { return NSColor(white: white[0], alpha: white.count > 1 ? white[1] : 1) }
        return nil
    }
}
