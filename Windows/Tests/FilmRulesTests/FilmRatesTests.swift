import Foundation
import Testing
@testable import FilmRules

/// How many frames a second a movie of a size can have on Windows (Host/FilmRates.swift): what
/// the encoder wrote and refused in the VM lies on the right side of the rule.
struct FilmRatesTests {
    @Test func noMovieHasMoreThan172FramesASecond() {
        #expect(FilmRates.fastest(width: 960, height: 540) == 172)
        #expect(FilmRates.fastest(width: 2, height: 2) == 172)
        // 1920 by 1080 is 120 by 68 macroblocks, 8160: 254 a second by the blocks, so 172.
        #expect(FilmRates.fastest(width: 1920, height: 1080) == 172)
    }

    @Test func aLargeFrameLeavesFewer() {
        #expect(FilmRates.fastest(width: 2560, height: 1440) == 144)
        #expect(FilmRates.fastest(width: 3840, height: 2160) == 64)
        #expect(FilmRates.fastest(width: 2160, height: 3840) == 64)
        // Never none, whatever is asked.
        #expect(FilmRates.fastest(width: 100_000, height: 100_000) == 1)
    }

    /// Written in the VM: 172 at 960 by 540, 121 at 1920 by 1080, 61 at 3840 by 2160. Refused:
    /// 173 at the first, 180 at the second, 120 at the third.
    @Test func whatTheEncoderWroteIsAllowedAndWhatItRefusedIsNot() {
        #expect(FilmRates.fastest(width: 960, height: 540) >= 172 && FilmRates.fastest(width: 960, height: 540) < 173)
        #expect(FilmRates.fastest(width: 1920, height: 1080) >= 121 && FilmRates.fastest(width: 1920, height: 1080) < 180)
        #expect(FilmRates.fastest(width: 3840, height: 2160) >= 61 && FilmRates.fastest(width: 3840, height: 2160) < 120)
    }
}
