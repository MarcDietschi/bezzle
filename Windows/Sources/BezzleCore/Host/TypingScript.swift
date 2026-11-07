import Foundation

// Typing driven by words instead of keys, for trying the typing session without the window
// (bezzle-render's BEZZLE_TYPING): each step separated by "|", answered in the log it returns.
//
//   begin:<words or name>[#k]    types into the k-th text (from 0) whose name or words hold them
//   type:<letters>               typed at the caret, letter by letter, over what is picked out
//   back                         Backspace
//   pick:<at>,<length>           picks letters out (or puts the caret)
//   fmt:<bold|italic|underline|strike|bigger|smaller|bullets|numbers>
//   size:<n> family:<f> face:<f> tracking:<n> colour:<RRGGBB> align:<left|center|right>
//   dial:<n>,<n>,…               the Text card's dial dragged through sizes, one change
//   undo  redo                   the editor's own, while typing
//   end                          typing is done
//   undoall                      the design's Undo (after typing)
//   grid:<columns>               the text made a repeat grid of that many columns
//   post                         a post added to the text's artboard (a deck)
//   hit:<x>,<y>                  where a click there on the canvas puts the caret
//   spell:<i>                    the misspelt word at letter i, and its spellings
//   spelling:on|off grammar:on|off  checking while typing, and words said twice
//   fix:<at>,<length>,<words>    words put in place of some letters, as a spelling chosen
//   texts:<words>                every text holding them, and its runs
//   print                        the words, runs, what the cards show and the marks

extension WindowsCore {
    public static func typingScript(_ script: String) -> String {
        var log: [String] = []
        var last: UUID?
        func say(_ s: String) { log.append(s) }
        func words() -> String { typingWords ?? "" }
        func spans(of id: UUID?) -> String {
            guard let id, let node = design?.node(id) else { return "no layer" }
            let runs = node.runs.map { run -> String in
                var parts: [String] = []
                let l = run.look
                if let f = l.family { parts.append(f) }
                if let f = l.face { parts.append(f) }
                if let s = l.size { parts.append("\(s)pt") }
                if let c = l.color { parts.append("#\(c.hex)") }
                if l.underline == true { parts.append("under") }
                if l.strikethrough == true { parts.append("strike") }
                if let t = l.tracking { parts.append("track \(t)") }
                if let li = l.list { parts.append(li.rawValue) }
                return "[\(run.text.replacingOccurrences(of: "\n", with: "⏎"))]" + (parts.isEmpty ? "" : "{\(parts.joined(separator: " "))}")
            }
            let s = node.style ?? TextStyle()
            return "\(runs.joined()) style \(s.family) \(s.face) \(s.size)pt #\(node.fill.color.hex)"
        }
        func typeOne(_ c: String) {
            guard let t = typing else { return }
            let ns = words() as NSString
            let r = NSRange(location: min(t.picked.location, ns.length), length: min(t.picked.length, ns.length - min(t.picked.location, ns.length)))
            let next = ns.replacingCharacters(in: r, with: c)
            typed(next, caret: NSRange(location: r.location + (c as NSString).length, length: 0))
        }
        for step in script.split(separator: "|").map(String.init) {
            let (verb, arg): (String, String) = {
                guard let k = step.firstIndex(of: ":") else { return (step, "") }
                return (String(step[..<k]), String(step[step.index(after: k)...]))
            }()
            switch verb {
            case "begin":
                var name = arg, k = 0
                if let hash = arg.lastIndex(of: "#"), let n = Int(arg[arg.index(after: hash)...]) { name = String(arg[..<hash]); k = n }
                let texts = (design?.allNodes ?? []).filter { $0.kind == .text && ($0.name.contains(name) || ($0.text ?? "").contains(name)) }
                guard texts.indices.contains(k) else { say("begin: no text \(arg)"); continue }
                last = texts[k].id
                beginTyping(texts[k].id)
                say("begin \(texts[k].name): \(words().debugDescription)")
            case "type":
                for c in arg { typeOne(String(c)) }
            case "back":
                guard let t = typing else { continue }
                let ns = words() as NSString
                var r = t.picked
                if r.length == 0, r.location > 0 { r = NSRange(location: r.location - 1, length: 1) }
                typed(ns.replacingCharacters(in: r, with: ""), caret: NSRange(location: r.location, length: 0))
            case "pick":
                let v = arg.split(separator: ",").compactMap { Int($0) }
                if v.count == 2 { pick(NSRange(location: v[0], length: v[1])) }
            case "fmt":
                let f: TextFormat? = ["bold": .bold, "italic": .italic, "underline": .underline, "strike": .strikethrough,
                                      "bigger": .bigger, "smaller": .smaller, "bullets": .bulletList, "numbers": .numberList][arg]
                if let f, let id = typing?.id ?? last { say("fmt \(arg): \(format(f, [id]))") }
            case "size", "family", "face", "tracking", "align":
                guard let id = typing?.id ?? last else { continue }
                let c: TextChange? = switch verb {
                case "size": Double(arg).map { .size($0) }
                case "family": .family(arg)
                case "face": .face(arg)
                case "tracking": Double(arg).map { .tracking($0) }
                default: .align(arg)
                }
                if let c { change([id], c) }
            case "colour":
                guard let id = typing?.id ?? last, let c = Colour(hex: arg, alpha: 1) else { continue }
                change([id], .fillColour(0, c))
            case "dial":
                guard let id = typing?.id ?? last else { continue }
                beginGesture()
                for v in arg.split(separator: ",").compactMap({ Double($0) }) { change([id], .size(v)) }
                endGesture()
            case "undo":
                say("undo: \(undoTyping().map { "\($0.words.debugDescription) picked \($0.picked)" } ?? "nothing")")
            case "redo":
                say("redo: \(redoTyping().map { "\($0.words.debugDescription) picked \($0.picked)" } ?? "nothing")")
            case "end":
                endTyping()
            case "undoall":
                say("undo all: \(undo())")
            case "grid":
                guard let id = last, let columns = Int(arg), let grid = makeRepeatGrid([id]) else { say("grid: not made"); continue }
                changeGrid(grid, .columns(columns))
                say("grid \(grid) with \(columns) columns")
            case "post":
                guard let id = last, let doc = design, let board = doc.nodes.first(where: { b in b.isArtboard && (b.id == id || doc.ancestors(of: id).contains { $0.id == b.id }) }) else { say("post: none"); continue }
                _ = addPost(to: board.id, selection: [id])
                say("post added to \(board.name)")
            case "hit":
                let v = arg.split(separator: ",").compactMap { Double($0) }
                if v.count == 2 { say("hit \(arg): \(typingIndex(at: CGPoint(x: v[0], y: v[1]), slack: 4).map(String.init) ?? "off the text")") }
            case "enter":
                if typingEndsList(onReturn: true) { say("enter: the list ends") } else { typeOne("\n") }
            case "tab":
                if let next = typingNextPost(forward: arg != "back") {
                    endTyping()
                    _ = turn(next.deck, to: next.post, selection: [])
                    beginTyping(next.id)
                    say("tab to post \(next.post): \(words().debugDescription)")
                } else {
                    say("tab: no post there")
                }
            case "spell":
                let found = Int(arg).flatMap { typingMisspelt(at: $0) }
                let said = found.map { f in "\(f.word) \(f.range) " + (f.repeated ? "repeated" : "guesses \(f.guesses.prefix(4))") } ?? "nothing"
                say("spell \(arg): \(said)")
            case "spelling": checksSpelling = arg == "on"
            case "grammar": checksGrammar = arg == "on"
            case "fix":
                let v = arg.split(separator: ",")
                if v.count == 3, let a = Int(v[0]), let n = Int(v[1]) {
                    say("fix: \(replaceTyped(NSRange(location: a, length: n), with: String(v[2])).map { $0.words.debugDescription } ?? "nothing")")
                }
            case "texts":
                for n in (design?.allNodes ?? []) where n.kind == .text && (n.text ?? "").contains(arg) { say("  text \(n.id.uuidString.prefix(8)) \(spans(of: n.id))") }
            case "print":
                let id = typing?.id ?? last
                say("words \(words().debugDescription) picked \(typing.map { "\($0.picked)" } ?? "-")")
                say("runs \(spans(of: id))")
                if let id, let card = textCard([id]) {
                    say("card \(card.familyShown) · \(card.face ?? "Several") · \(card.size.map { "\($0)" } ?? "Several") pt · underline \(card.underline) · picked \(card.picked.map(String.init) ?? "none")")
                }
                if let id, let looks = looks([id]) { say("fill \(looks.fills.first?.summary ?? "-") picked \(looks.lettersPicked)") }
                if let marks = typingMarks(zoom: 1) {
                    say("marks caret \(marks.caret.map { "\($0[0]) to \($0[3])" } ?? "none") picked \(marks.picked.count) misspelt \(marks.misspelt.count) repeated \(marks.repeated.count)")
                }
                // Every copy of the text in a grid or a deck, and their runs.
                if let id, let doc = design, let grid = doc.grid(holding: id) {
                    func flat(_ n: [Node]) -> [Node] { n.flatMap { [$0] + flat($0.children) } }
                    for cell in flat(grid.children) where cell.kind == .text { say("  cell \(spans(of: cell.id))") }
                }
            default:
                say("unknown step \(step)")
            }
        }
        return log.joined(separator: "\n")
    }
}
