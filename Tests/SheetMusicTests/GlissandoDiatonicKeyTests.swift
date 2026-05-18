import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct GlissandoDiatonicKeyTests {
    @Test func cMajor_includes_E_not_Eflat() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 60, endPitch: 72, keySignature: 0,
        )
        let absolutePitches = offsets.map { 60 + $0 }
        #expect(absolutePitches.contains(64)) // E4
        #expect(!absolutePitches.contains(63)) // Eb4
    }

    @Test func gMajor_includes_FSharp_not_F() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 67, endPitch: 79, keySignature: 1,
        )
        let absolutePitches = offsets.map { 67 + $0 }
        #expect(absolutePitches.contains(78)) // F#5
        #expect(!absolutePitches.contains(77)) // F5
    }

    @Test func fMinor_includes_Ab_Bb_Db_Eb() {
        // F minor / Ab major has signature -4: PCs {0,1,3,5,7,8,10}.
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 53, endPitch: 65, keySignature: -4,
        )
        let absolutePitches = Set(offsets.map { 53 + $0 })
        #expect(absolutePitches.contains(56)) // Ab3
        #expect(absolutePitches.contains(58)) // Bb3
        #expect(absolutePitches.contains(61)) // Db4
        #expect(absolutePitches.contains(63)) // Eb4
        #expect(!absolutePitches.contains(57)) // A3
        #expect(!absolutePitches.contains(62)) // D4
    }
}
