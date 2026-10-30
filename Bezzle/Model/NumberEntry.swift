import Foundation

/// What can be typed into a number field: a value or a sum ("120/3"), a change to what is
/// there ("+10", "×2", "/2", "+10%"), or a share of the whole it is measured against ("50%").
enum NumberEntry: Equatable {
    case value(Double)
    case add(Double)
    case multiply(Double)
    case share(Double)

    /// What it comes to for a layer whose value is `old`. A share is of `whole` when the field
    /// has one, such as the artboard's width for a layer's, and of the value itself when not.
    func applied(to old: Double, whole: Double? = nil) -> Double {
        switch self {
        case .value(let v): v
        case .add(let v): old + v
        case .multiply(let f): old * f
        case .share(let f): (whole ?? old) * f
        }
    }

    /// Reads what was typed. `negatives` tells whether a leading minus makes a negative number,
    /// as in a position, or takes away from what is there, as in a width. A field measured in
    /// percent takes "%" as its unit and nothing more.
    static func parse(_ text: String, unit: String = "", negatives: Bool = true) -> NumberEntry? {
        var s = text.replacingOccurrences(of: ",", with: ".")
        if !unit.isEmpty && unit != "%" { s = s.replacingOccurrences(of: unit, with: "") }
        for (sign, plain) in [("×", "*"), ("x", "*"), ("X", "*"), ("÷", "/"), ("−", "-"), ("–", "-")] {
            s = s.replacingOccurrences(of: sign, with: plain)
        }
        s = s.filter { !$0.isWhitespace }
        let percent = unit != "%" && s.hasSuffix("%")
        if s.hasSuffix("%") { s.removeLast() }
        guard let first = s.first else { return nil }

        let rest = String(s.dropFirst())
        switch first {
        case "+":
            guard let v = Arithmetic.evaluate(rest) else { return nil }
            return percent ? .multiply(1 + v / 100) : .add(v)
        case "-" where !negatives:
            guard let v = Arithmetic.evaluate(rest) else { return nil }
            return percent ? .multiply(1 - v / 100) : .add(-v)
        case "*":
            guard let v = Arithmetic.evaluate(rest) else { return nil }
            return .multiply(percent ? v / 100 : v)
        case "/":
            guard let v = Arithmetic.evaluate(rest), v != 0 else { return nil }
            return .multiply(1 / v)
        default:
            guard let v = Arithmetic.evaluate(s) else { return nil }
            return percent ? .share(v / 100) : .value(v)
        }
    }
}

/// Sums of plain numbers, read the way a calculator does: × and ÷ before + and −, and brackets.
private struct Arithmetic {
    let chars: [Character]
    var i = 0

    static func evaluate(_ text: String) -> Double? {
        var a = Arithmetic(chars: Array(text))
        guard let v = a.sum(), a.i == a.chars.count, v.isFinite else { return nil }
        return v
    }

    private var next: Character? { i < chars.count ? chars[i] : nil }

    private mutating func sum() -> Double? {
        guard var v = product() else { return nil }
        while let op = next, op == "+" || op == "-" {
            i += 1
            guard let r = product() else { return nil }
            v = op == "+" ? v + r : v - r
        }
        return v
    }

    private mutating func product() -> Double? {
        guard var v = factor() else { return nil }
        while let op = next, op == "*" || op == "/" {
            i += 1
            guard let r = factor() else { return nil }
            v = op == "*" ? v * r : v / r
        }
        return v
    }

    private mutating func factor() -> Double? {
        switch next {
        case "-":
            i += 1
            return factor().map { -$0 }
        case "+":
            i += 1
            return factor()
        case "(":
            i += 1
            guard let v = sum(), next == ")" else { return nil }
            i += 1
            return v
        default:
            let start = i
            while let c = next, c.isASCII, c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}
