import Foundation

/// What the page keeps for the core, and when it may let go: the pictures it made of what the
/// core described (`CGImage`) and the texts it set (`HostTexts`). The page holds each for as
/// long as something here does: an artboard's picture until the next is drawn, a film's while
/// the film shows them, a blur or a developed photo as long as its cache keeps it, a text while
/// its layout is kept or a picture draws it. When the last hold goes, its number is noted here,
/// and the next answer to the page hands the numbers over (`gone`).
///
/// Only here, in the browser's core: Bezzle for Windows lets go of its pictures in its own way
/// (`CGImage.released` in its host) and keeps its texts.
nonisolated enum PageKeeps {
    nonisolated(unsafe) private static var pictures: [Int] = []
    nonisolated(unsafe) private static var texts: [Int] = []
    nonisolated(unsafe) private static var listening = false

    /// From now on, a picture or a text nothing holds any more is noted for the page.
    static func listen() {
        guard !listening else { return }
        listening = true
        CGImage.released = { pictures.append($0) }
        HostTexts.released = { texts.append(contentsOf: $0) }
    }

    /// The pictures and texts let go since this was last asked, as the members of an answer:
    /// `"drop":[…],"dropTexts":[…]`.
    static func gone() -> String {
        defer {
            pictures = []
            texts = []
        }
        return "\"drop\":[" + pictures.map(String.init).joined(separator: ",") + "],\"dropTexts\":[" + texts.map(String.init).joined(separator: ",") + "]"
    }

    /// Runs what draws, and answers the pictures made since the page was last told of any, as it
    /// reads them (`Images.json`). They are taken off the list of every picture then, so that
    /// each lives only as long as what was drawn is held, or a picture that is made of it. Ask
    /// for `gone` after this, not before: a picture made on the way and held by nothing is let
    /// go here, and the page is to hear of that in the same answer.
    static func listing<T>(_ work: () -> T) -> (T, images: String) {
        listen()
        let result = work()
        let images = Images.shared.json()
        Images.shared.list.removeAll()
        return (result, images)
    }
}
