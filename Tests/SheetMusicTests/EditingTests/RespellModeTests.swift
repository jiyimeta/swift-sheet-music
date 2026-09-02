@testable import SheetMusicCore
import Testing

@Suite("RespellMode")
struct RespellModeTests {
    @Test("simplest in C major puts one accidental on every black key, flats low and sharps high", arguments: [
        (61, 21), (63, 11), (66, 20), (68, 22), (70, 12), (60, 14), (65, 13),
    ] as [(Int, Int)])
    func simplestInCMajor(pitch: Int, tpc: Int) {
        #expect(PitchSpelling.tpc(forPitch: pitch, keySig: 0, mode: .simplest) == tpc)
    }

    @Test("prefer flats and prefer sharps each stay on their side of the circle")
    func preferences() {
        #expect(PitchSpelling.tpc(forPitch: 61, keySig: 0, mode: .preferFlats) == 9) // D♭
        #expect(PitchSpelling.tpc(forPitch: 66, keySig: 0, mode: .preferFlats) == 8) // G♭
        #expect(PitchSpelling.tpc(forPitch: 68, keySig: 0, mode: .preferFlats) == 10) // A♭
        #expect(PitchSpelling.tpc(forPitch: 63, keySig: 0, mode: .preferSharps) == 23) // D♯
        #expect(PitchSpelling.tpc(forPitch: 70, keySig: 0, mode: .preferSharps) == 24) // A♯
        #expect(PitchSpelling.tpc(forPitch: 64, keySig: 0, mode: .preferFlats) == 18) // E stays E
    }

    @Test("the key signature slides the window")
    func keySlidesWindow() {
        #expect(PitchSpelling.tpc(forPitch: 63, keySig: 2, mode: .simplest) == 23) // D major: D♯
        #expect(PitchSpelling.tpc(forPitch: 63, keySig: -3, mode: .simplest) == 11) // E♭ major: E♭
        #expect(PitchSpelling.tpc(forPitch: 71, keySig: -6, mode: .simplest) == 7) // G♭ major: C♭
    }

    @Test("every result is the same pitch class it was asked for")
    func pitchClassPreserved() {
        for pitch in 48 ... 72 {
            for mode in RespellMode.allCases {
                for keySig in -7 ... 7 {
                    let tpc = PitchSpelling.tpc(forPitch: pitch, keySig: keySig, mode: mode)
                    // tpc → pitch class: 7 fifths per tpc step, F (13) is pitch class 5.
                    #expect((((tpc - 13) * 7 + 5) % 12 + 12) % 12 == pitch % 12)
                }
            }
        }
    }
}
