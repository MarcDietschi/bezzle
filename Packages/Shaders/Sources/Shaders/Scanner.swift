extension Upgrade {
    enum Token {
        /// Whitespace, punctuation, numbers, comments: copied as they are.
        case text(ArraySlice<UInt8>)
        case identifier(String)
        /// The `#version` line, and how many line breaks inside it (continued lines) it took.
        case version(Int, lines: Int)
        /// A directive's name and its whole line, before the line itself is handed on.
        case directive(String, String)
        /// A directive left out, and the line breaks inside it.
        case dropped(lines: Int)
    }

    /// Walks GLSL source token by token. Preprocessor lines are handed on token by token too
    /// (`#define` bodies are code), except `#version`, `#pragma`, `#line`, `#error` and
    /// `#extension`, which go whole; `drops` may leave a directive out.
    static func scan(_ bytes: [UInt8], _ emit: (Token) -> Void,
                     directive drops: (String, String) -> Bool = { _, _ in false }) {
        let n = bytes.count
        var i = 0
        var textStart = 0
        var lineStart = true
        var seenCode = false

        func flush(_ end: Int) {
            if end > textStart { emit(.text(bytes[textStart..<end])) }
            textStart = max(textStart, end)
        }
        func isIdentifierStart(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        func isIdentifierPart(_ c: UInt8) -> Bool { isIdentifierStart(c) || (c >= 0x30 && c <= 0x39) }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        /// The end of the comment at `at`, or nil when none starts there.
        func comment(_ at: Int) -> Int? {
            guard at + 1 < n, bytes[at] == 0x2F else { return nil }
            if bytes[at + 1] == 0x2F {
                var j = at
                while j < n && bytes[j] != 0x0A { j += 1 }
                return j
            }
            if bytes[at + 1] == 0x2A {
                var j = at + 2
                while j + 1 < n && !(bytes[j] == 0x2A && bytes[j + 1] == 0x2F) { j += 1 }
                return min(n, j + 2)
            }
            return nil
        }
        /// The identifier at `at`, handed on; returns its end.
        func identifier(_ at: Int) -> Int {
            flush(at)
            var k = at
            while k < n && isIdentifierPart(bytes[k]) { k += 1 }
            emit(.identifier(String(decoding: bytes[at..<k], as: UTF8.self)))
            textStart = k
            return k
        }
        /// The end of the number at `at`, its exponent's sign included.
        func number(_ at: Int) -> Int {
            let hex = bytes[at] == 0x30 && at + 1 < n && (bytes[at + 1] == 0x78 || bytes[at + 1] == 0x58)
            var k = at + 1
            while k < n {
                let d = bytes[k]
                if isIdentifierPart(d) || d == 0x2E {
                    k += 1
                } else if !hex && (d == 0x2B || d == 0x2D) && (bytes[k - 1] == 0x65 || bytes[k - 1] == 0x45) {
                    k += 1
                } else {
                    break
                }
            }
            return k
        }

        while i < n {
            let c = bytes[i]
            if let end = comment(i) {
                i = end
                continue
            }
            if c == 0x0A {
                lineStart = true
                i += 1
                continue
            }
            if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0B || c == 0x0C {
                i += 1
                continue
            }
            if c == 0x23 && lineStart {
                // A directive: its logical line, continued lines included, without its last break.
                flush(i)
                var end = i
                var breaks = 0
                while end < n {
                    if bytes[end] == 0x0A {
                        var back = end - 1
                        while back > i && bytes[back] == 0x0D { back -= 1 }
                        if back > i && bytes[back] == 0x5C {
                            breaks += 1
                            end += 1
                            continue
                        }
                        break
                    }
                    end += 1
                }
                let line = String(decoding: bytes[i..<end], as: UTF8.self)
                var nameStart = i + 1
                while nameStart < end && (bytes[nameStart] == 0x20 || bytes[nameStart] == 0x09) { nameStart += 1 }
                var nameEnd = nameStart
                while nameEnd < end && isIdentifierPart(bytes[nameEnd]) { nameEnd += 1 }
                let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                emit(.directive(name, line))
                if name == "version" && !seenCode {
                    let number = line.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 100
                    emit(.version(number, lines: breaks))
                    textStart = end
                } else if drops(name, line) {
                    emit(.dropped(lines: breaks))
                    textStart = end
                } else if ["pragma", "line", "error", "extension", "version"].contains(name) {
                    flush(end)
                } else {
                    // Its words go through like code's.
                    flush(nameEnd)
                    var j = nameEnd
                    while j < end {
                        if let close = comment(j) {
                            j = close
                        } else if isIdentifierStart(bytes[j]) {
                            j = identifier(j)
                        } else if isDigit(bytes[j]) {
                            j = number(j)
                        } else {
                            j += 1
                        }
                    }
                    end = max(end, j)
                    flush(end)
                }
                i = end
                continue
            }
            lineStart = false
            seenCode = true
            if isIdentifierStart(c) {
                i = identifier(i)
            } else if isDigit(c) || (c == 0x2E && i + 1 < n && isDigit(bytes[i + 1])) {
                i = number(i)
            } else {
                i += 1
            }
        }
        flush(n)
    }
}
