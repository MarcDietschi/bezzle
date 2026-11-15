import Testing
import Foundation
@testable import Bezzle

/// Animate's words in the app's other languages. Every one of them is there in German, French
/// and Italian, takes the same values in the same order, and is written the way Bezzle writes:
/// no dashes as punctuation and no exclamation marks.
@MainActor
struct AnimateWordsTests {
    /// The names the film's own parts go by, told from the parts themselves: a property, a pace
    /// or a move added later has to bring its words along.
    static var named: [String] {
        MotionProperty.allCases.map { p in
            p.isCamera ? "animate.camera." + p.rawValue.dropFirst("camera".count).lowercased() : "animate." + p.rawValue
        } + MotionEase.Kind.allCases.map { "ease." + $0.rawValue } + MotionMove.allCases.map { "move." + $0.rawValue }
            + LookTrack.words.map(\.key)
    }

    /// What Animate says anywhere else: its mode, the panel, the timeline, the menus and what the Edit menu undoes.
    static let said = [
        "mode.animate", "animate.camera",
        "Animate the design: its layers and a camera, posed along a timeline  ⌃A",
        "Pause", "Play Film", "Play the film, or stop it  Space", "Play the film  Space", "Stop the film  Space",
        "Hold Here", "Hold it here: a key at the playhead  K",
        "Plays once and stops. Click to play it round and round.", "Plays round and round. Click to play it once.",
        "Where the film ends. Drag to set its length; double click to let it follow the keys.",
        "Add Key", "Add Key Here", "Remove Key", "Move Key", "Change Pace",
        "Bounce", "How far a spring goes past its key before it comes to rest", "Spring. Drag sideways to set its bounce.",
        "Remove Motion", "Remove All Motion", "Remove the Camera's Motion",
        "Film", "Film Length", "Length", "Follow the Keys", "Round and Round", "Once", "Play Once", "Play Round and Round",
        "Backdrop", "What shows past the artboard's edges when the camera sees them",
        "Pictures a second", "%@ × %@ pixels, %lld a second", "Save as Movie…", "Stop Saving", "Save the Film as a Movie",
        "This film is too long to save as a movie.",
        "H.264", "HEVC 10 bit",
        "H.264 plays everywhere. HEVC with 10 bits keeps gentle gradients, soft shadows and slow fades smooth where H.264 shows bands, and plays on Apple devices and in most browsers.",
        "This Mac cannot save a movie of this kind.", "Save it as H.264 instead.",
        "A movie runs for an hour at most. Give the film a shorter length, or take away the keys that come later.",
        "Moves", "Everything", "Comes On", "Goes", "One After Another",
        "Pose", "Set a key here", "A key here. Click to take it away.",
        "Fly the Camera Here", "The camera looks at what is picked from the playhead on, and flies there from where it was before",
        "Focus the Camera Here", "The camera is sharp on what is picked from the playhead on, and what stands nearer or further shows blurred",
        "The camera is sharp this many points nearer than where it looks. Below 0, further away.",
        "Points of blur for every hundred points a thing stands off the focus",
        "See the Whole Artboard", "Turn the Scene", "Look Straight Down",
        "Drag to tip the scene back and swing it round under the camera. Double click to look straight down.",
        "Edit Points", "Done", "Move its points on the canvas to give it another shape at the playhead",
        "animate.shape.from", "Give it the outline of another shape at the playhead",
        "Add Point", "Delete Point", "Delete Points", "Move Points",
        // How layers look, keyed on the design's own cards: what those say only here.
        "Drag to move this colour",
        "Changed in the design", "No key can hold this change, so it changed the design itself, for the whole film.",
    ]

    /// The values a string takes, in order: `%@`, `%lld` and the like.
    private func values(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let at = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: at)...]
            let spec = rest.prefix { $0 == "l" || $0 == "d" || $0 == "@" || $0 == "f" || $0 == "." || $0.isNumber }
            if !spec.isEmpty { out.append(String(spec)) }
            rest = rest.dropFirst(spec.count)
        }
        return out
    }

    @Test(arguments: ["de", "fr", "it"])
    func everyWordOfAnimateIsThere(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        let english = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en")
            .flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
        for key in Self.named + Self.said {
            guard let word = table[key], !word.isEmpty else {
                Issue.record("\(language) has no words for \(key)")
                continue
            }
            #expect(!word.contains("—") && !word.contains(" – ") && !word.contains(" - ") && !word.contains("!"), "\(language): \(word)")
            // A key that is a name, such as mode.animate, has its English beside it; any other is its own English.
            #expect(values(in: word) == values(in: english[key] ?? key), "\(language): \(word)")
            // A shortcut named at the end of a tip is the same key in every language.
            if let keys = key.range(of: "  ", options: .backwards).map({ key[$0.upperBound...] }), keys.unicodeScalars.contains(where: { "⌃⌘⌥⇧".unicodeScalars.contains($0) }) {
                #expect(word.hasSuffix("  " + keys), "\(language): \(word)")
            }
        }
    }

    @Test func theFilmsPartsAreNamedInEnglishToo() {
        // The tests run in English: a name is never its own key.
        for p in MotionProperty.allCases { #expect(!p.title.contains("animate.") && !p.title.isEmpty) }
        for kind in MotionEase.Kind.allCases { #expect(!MotionEase(kind: kind).title.contains("ease.")) }
        for move in MotionMove.allCases { #expect(!move.title.contains("move.")) }
        // Every look's line says one of the words kept for them, in English as written there.
        let english = Set(LookTrack.words.map(\.english))
        let looks: [LookTrack] = [.fill(0), .fillStops(0), .border(0), .borderStops(0), .borderWidth(0), .shadow(0), .corners]
        for look in looks { for line in [false, true] { #expect(english.contains(look.title(line: line))) } }
        #expect(Set(looks.flatMap { [$0.title(), $0.title(line: true)] }) == english)
        #expect(Set(Self.named).count == Self.named.count)
    }
}
