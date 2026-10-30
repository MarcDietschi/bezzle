import Foundation

/// Keys that put the layers of one artboard or group in order, bottom first, as strings sorted
/// byte by byte. There is always a key between two others, so a layer moved or added among others
/// takes a new key of its own and none of the others change: two people reordering the same list
/// at once each keep their move. Two keys made at once in the same place may come out the same;
/// layers with the same key are put in order by their ids, the same way everywhere.
///
/// A key is a whole part, whose first letter says how long it is, and then a fraction that never
/// ends in the lowest digit, so that adding at the top over and over keeps keys short.
nonisolated enum OrderKey {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let zero = digits[0]
    private static let smallestWhole: [UInt8] = [UInt8(ascii: "A")] + Array(repeating: zero, count: 26)

    static func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    /// A key after `a` and before `b`; nil for either end means there is nothing on that side.
    /// A key that is not well formed counts as missing, so a bad key never stops anything.
    static func between(_ a: String?, _ b: String?) -> String {
        let a = a.map { Array($0.utf8) }.flatMap { isValid($0) ? $0 : nil }
        var b = b.map { Array($0.utf8) }.flatMap { isValid($0) ? $0 : nil }
        // Out of order, which only a bad key can make: after `a` is the best that can be done.
        if let x = a, let y = b, !x.lexicographicallyPrecedes(y) { b = nil }
        return String(decoding: key(between: a, b), as: UTF8.self)
    }

    /// As many keys as asked for, in order, after `a` and before `b`.
    static func keys(_ count: Int, between a: String?, _ b: String?) -> [String] {
        var keys: [String] = []
        var last = a
        for _ in 0..<count {
            let k = between(last, b)
            keys.append(k)
            last = k
        }
        return keys
    }

    private static func key(between a: [UInt8]?, _ b: [UInt8]?) -> [UInt8] {
        guard let a else {
            guard let b else { return [UInt8(ascii: "a"), zero] }
            let ib = wholePart(b), fb = Array(b[ib.count...])
            if ib == smallestWhole { return ib + midpoint([], fb) }
            if ib.lexicographicallyPrecedes(b) { return ib }
            return decrement(ib) ?? ib + midpoint([], fb)
        }
        let ia = wholePart(a), fa = Array(a[ia.count...])
        guard let b else {
            return increment(ia) ?? ia + midpoint(fa, nil)
        }
        let ib = wholePart(b), fb = Array(b[ib.count...])
        if ia == ib { return ia + midpoint(fa, fb) }
        if let i = increment(ia), i.lexicographicallyPrecedes(b) { return i }
        return ia + midpoint(fa, nil)
    }

    /// A fraction between two others, with `b` nil for one.
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        if let b {
            var n = 0
            while n < b.count, (n < a.count ? a[n] : zero) == b[n] { n += 1 }
            if n > 0 { return Array(b[..<n]) + midpoint(Array(a[min(n, a.count)...]), Array(b[n...])) }
        }
        let da = a.first.flatMap(index) ?? 0
        let db = b.flatMap { $0.first.flatMap(index) } ?? digits.count
        if db - da > 1 { return [digits[(da + db + 1) / 2]] }
        if let b, b.count > 1 { return [b[0]] }
        return [digits[da]] + midpoint(Array(a.dropFirst()), nil)
    }

    private static func index(_ digit: UInt8) -> Int? { digits.firstIndex(of: digit) }

    private static func wholeLength(_ head: UInt8) -> Int? {
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(UInt8(ascii: "Z") - head) + 2
        default: nil
        }
    }

    private static func wholePart(_ key: [UInt8]) -> [UInt8] { Array(key.prefix(wholeLength(key[0]) ?? key.count)) }

    private static func isValid(_ key: [UInt8]) -> Bool {
        guard let head = key.first, let length = wholeLength(head), length <= key.count, key != smallestWhole,
              key.allSatisfy({ index($0) != nil }) else { return false }
        return key.count == length || key.last != zero
    }

    private static func increment(_ whole: [UInt8]) -> [UInt8]? {
        var head = whole[0]
        var digs = Array(whole.dropFirst())
        var carry = true
        var i = digs.count - 1
        while carry && i >= 0 {
            let d = index(digs[i])! + 1
            if d == digits.count { digs[i] = zero } else { digs[i] = digits[d]; carry = false }
            i -= 1
        }
        guard carry else { return [head] + digs }
        if head == UInt8(ascii: "Z") { return [UInt8(ascii: "a"), zero] }
        if head == UInt8(ascii: "z") { return nil }
        head += 1
        if head > UInt8(ascii: "a") { digs.append(zero) } else { digs.removeLast() }
        return [head] + digs
    }

    private static func decrement(_ whole: [UInt8]) -> [UInt8]? {
        var head = whole[0]
        var digs = Array(whole.dropFirst())
        var borrow = true
        var i = digs.count - 1
        while borrow && i >= 0 {
            let d = index(digs[i])! - 1
            if d == -1 { digs[i] = digits.last! } else { digs[i] = digits[d]; borrow = false }
            i -= 1
        }
        guard borrow else { return [head] + digs }
        if head == UInt8(ascii: "a") { return [UInt8(ascii: "Z"), digits.last!] }
        if head == UInt8(ascii: "A") { return nil }
        head -= 1
        if head < UInt8(ascii: "Z") { digs.append(digits.last!) } else { digs.removeLast() }
        return [head] + digs
    }
}

/// The indices of a longest run of `items` that only rises, each strictly after the one before.
nonisolated func longestRise<T>(_ items: [T], less: (T, T) -> Bool) -> Set<Int> {
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: items.count)
    for i in items.indices {
        var lo = 0, hi = tails.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if less(items[tails[mid]], items[i]) { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 { previous[i] = tails[lo - 1] }
        if lo == tails.count { tails.append(i) } else { tails[lo] = i }
    }
    var run = Set<Int>()
    var k = tails.last ?? -1
    while k >= 0 {
        run.insert(k)
        k = previous[k]
    }
    return run
}
