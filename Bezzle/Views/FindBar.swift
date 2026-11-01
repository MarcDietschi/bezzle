import SwiftUI
import AppKit

/// Looking through the design's words, laid over the top of the canvas: what to find and what to
/// put in its place, or, turned to spelling, each misspelt word in turn and how it might be spelt.
/// What it finds is lit on the canvas (`CanvasView.drawFound`), and Return goes on to the next.
struct FindBar: View {
    let store: DocumentStore
    @Bindable var finder: TextFinder
    @Environment(MenuHost.self) private var menus
    @FocusState private var focus: Field?
    @State private var replaced: Int?

    private enum Field { case find, replace }

    var body: some View {
        let matches = store.foundText
        let current = finder.current.flatMap { matches.indices.contains($0) ? $0 : nil }
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                IconChoice(selection: finder.spelling, options: [
                    (false, "magnifyingglass", "Find and replace words"),
                    (true, "textformat.abc.dottedunderline", "Check spelling"),
                ]) { spelling in
                    finder.spelling = spelling
                    finder.current = nil
                    replaced = nil
                    if spelling { store.findNext() } else { focus = .find }
                }
                .frame(width: 60)
                if finder.spelling {
                    misspelt
                } else {
                    field("Find", text: $finder.query, field: .find) { store.findNext(forward: !$0) }
                }
                Text(count(matches.count, current: current))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .fixedSize()
                IconButton(symbol: "chevron.up", help: "Previous  ⇧↩", size: 24) { store.findNext(forward: false) }
                IconButton(symbol: "chevron.down", help: "Next  ↩", size: 24) { store.findNext() }
                IconButton(symbol: "xmark", help: "Close  esc", size: 24) { store.closeFind() }
            }
            HStack(spacing: 6) {
                if finder.spelling {
                    field("Spell it as", text: $finder.replacement, field: .replace) { _ in store.replaceFound() }
                    guessesMenu
                    ChipButton(title: "Change", height: 26) { store.replaceFound() }
                    ChipButton(title: "Ignore", height: 26) { store.ignoreMisspelt() }
                        .help("Leave this word as it is, everywhere in the design while it is open")
                    ChipButton(title: "Learn", height: 26) { store.learnMisspelt() }
                        .help("Add this word to the Mac's dictionary")
                } else {
                    IconToggles(options: [
                        ("textformat", "Match case", finder.matchCase, { finder.matchCase.toggle(); finder.current = nil }),
                        ("text.word.spacing", "Whole words only", finder.wholeWords, { finder.wholeWords.toggle(); finder.current = nil }),
                    ])
                    .frame(width: 60)
                    field("Replace with", text: $finder.replacement, field: .replace) { _ in store.replaceFound() }
                    ChipButton(title: "Replace", height: 26) { store.replaceFound() }
                    ChipButton(title: "All", height: 26) { replaced = store.replaceAllFound() }
                        .help("Replace everything found, as one step")
                }
            }
            if let replaced, !finder.spelling {
                Text(replaced == 1 ? "Replaced 1 time." : "Replaced \(replaced) times.")
                    .prose(11)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 66)
                    .transition(.unfold)
            }
        }
        .padding(8)
        .frame(width: 420)
        .card(radius: 14, lifted: true)
        .onExitCommand { store.closeFind() }
        .onAppear { focus = finder.spelling ? .replace : .find }
        .onChange(of: finder.focus) { focus = finder.spelling ? .replace : .find }
        .onChange(of: finder.query) { finder.current = nil; replaced = nil }
        // A misspelt word picked out offers its likeliest spelling to change it to.
        .task(id: store.misspeltWord) {
            guard finder.spelling, let word = store.misspeltWord else { return }
            finder.replacement = store.spellingGuesses.first ?? word
        }
        .animation(Theme.unfold, value: replaced)
        .animation(Theme.spring, value: finder.spelling)
    }

    private func count(_ n: Int, current: Int?) -> LocalizedStringResource {
        if finder.spelling && n == 0 { return "No misspelt words" }
        if n == 0 { return finder.query.isEmpty ? .verbatim("") : "Not found" }
        if let current { return "\(current + 1) of \(n)" }
        return n == 1 ? "1 found" : "\(n) found"
    }

    /// The misspelt word picked out, in the red it is marked with on the canvas.
    private var misspelt: some View {
        HStack(spacing: 6) {
            if let word = store.misspeltWord {
                Text(verbatim: word)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.8, green: 0.16, blue: 0.16))
                    .lineLimit(1)
            } else {
                Text(store.foundText.isEmpty ? "Every word is spelt right." : "Press Return for the next misspelt word.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .well(radius: 8)
    }

    /// The spellings the Mac offers for the misspelt word picked out.
    private var guessesMenu: some View {
        let guesses = store.spellingGuesses
        return MenuButton(id: "spelling-guesses", title: "Spellings", width: 200) {
            guesses.isEmpty ? [.note("The Mac has no spellings to offer for this word.")] : guesses.map { guess in
                MenuEntry.item(.verbatim(guess), checked: guess == finder.replacement) { store.replaceFound(with: guess) }
            }
        }
        .fixedSize()
    }

    /// A field in a well. Return does `submit`, told whether Shift was held.
    private func field(_ prompt: LocalizedStringResource, text: Binding<String>, field: Field, submit: @escaping (Bool) -> Void) -> some View {
        TextField(String(localized: prompt), text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.ink)
            .focused($focus, equals: field)
            .onKeyPress(.return, phases: .down) { press in
                submit(press.modifiers.contains(.shift))
                return .handled
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .well(radius: 8)
    }
}
