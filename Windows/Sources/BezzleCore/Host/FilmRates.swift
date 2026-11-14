import Foundation

// Animate: how many frames a second a movie of a given size can have on Windows. Media
// Foundation's H.264 encoder keeps to the standard's levels, up to 5.2, and takes no movie that
// asks for more: no picture shorter than a 172nd of a second (the levels' least picture time),
// and no more than 2 073 600 macroblocks, 16 by 16 pixels each, a second. Tried in the VM at 960
// by 540, 1920 by 1080 and 3840 by 2160: 172 written and 173 refused at the first, 121 written
// and 180 refused at the second, 61 written and 120 refused at the third, each refusal as the
// writer's input is set (MF_E_INVALIDMEDIATYPE). The Mac's encoder asks for no level and writes
// 240. Numbers in and numbers out, so Windows/Tests checks it on a Mac too.

nonisolated public enum FilmRates {
    /// The most frames a second at any size.
    public static let fastest = 172
    /// The most macroblocks a second, level 5.2's.
    public static let blocksASecond = 2_073_600

    /// The most frames a second for a frame of that many pixels: `fastest` up to 1920 by 1080 and
    /// some way past it, 144 at 2560 by 1440, 64 at 3840 by 2160.
    public static func fastest(width: Int, height: Int) -> Int {
        let blocks = max(1, (max(width, 1) + 15) / 16) * max(1, (max(height, 1) + 15) / 16)
        return max(1, min(fastest, blocksASecond / blocks))
    }
}
