import SheetMusicCore
import Testing

@Suite("PitchSpelling")
struct PitchSpellingTests {
    // TPC reminder: 13=F 14=C 15=G 16=D 17=A 18=E 19=B
    //               20=F# 21=C# 22=G# 23=D# 24=A# 25=E# 26=B#
    //               6=Fb 7=Cb 8=Gb 9=Db 10=Ab 11=Eb 12=Bb

    @Test("ascending +1 from a natural picks # of same letter")
    func ascendingFromNatural() {
        // C4 (60, tpc 14) +1 → C#4 (61, tpc 21)
        #expect(PitchSpelling.shiftedTpc(
            from: 60, priorTpc: 14, to: 61) == 21)
        // D4 (62, tpc 16) +1 → D#4 (63, tpc 23)
        #expect(PitchSpelling.shiftedTpc(
            from: 62, priorTpc: 16, to: 63) == 23)
        // F4 (65, tpc 13) +1 → F#4 (66, tpc 20)
        #expect(PitchSpelling.shiftedTpc(
            from: 65, priorTpc: 13, to: 66) == 20)
    }

    @Test("descending −1 from a natural picks b of same letter")
    func descendingFromNatural() {
        // D4 (62, tpc 16) −1 → Db4 (61, tpc 9)
        #expect(PitchSpelling.shiftedTpc(
            from: 62, priorTpc: 16, to: 61) == 9)
        // E4 (64, tpc 18) −1 → Eb4 (63, tpc 11)
        #expect(PitchSpelling.shiftedTpc(
            from: 64, priorTpc: 18, to: 63) == 11)
        // A4 (69, tpc 17) −1 → Ab4 (68, tpc 10)
        #expect(PitchSpelling.shiftedTpc(
            from: 69, priorTpc: 17, to: 68) == 10)
    }

    @Test("ascending across naturals lands on the natural letter")
    func ascendingNaturalLetter() {
        // E4 (64) +1 → F4 (65, tpc 13)
        #expect(PitchSpelling.shiftedTpc(
            from: 64, priorTpc: 18, to: 65) == 13)
        // B4 (71) +1 → C5 (72, tpc 14)
        #expect(PitchSpelling.shiftedTpc(
            from: 71, priorTpc: 19, to: 72) == 14)
    }

    @Test("descending across naturals lands on the natural letter")
    func descendingNaturalLetter() {
        // F4 (65) −1 → E4 (64, tpc 18)
        #expect(PitchSpelling.shiftedTpc(
            from: 65, priorTpc: 13, to: 64) == 18)
        // C4 (60) −1 → B3 (59, tpc 19)
        #expect(PitchSpelling.shiftedTpc(
            from: 60, priorTpc: 14, to: 59) == 19)
    }

    @Test("ascending from a sharp note advances to the natural")
    func ascendingFromSharp() {
        // C#4 (61, tpc 21) +1 → D4 (62, tpc 16)
        #expect(PitchSpelling.shiftedTpc(
            from: 61, priorTpc: 21, to: 62) == 16)
        // D#4 (63, tpc 23) +1 → E4 (64, tpc 18)
        #expect(PitchSpelling.shiftedTpc(
            from: 63, priorTpc: 23, to: 64) == 18)
    }

    @Test("Note.shifted updates pitch + tpc and clamps at MIDI bounds")
    func noteShiftedConvenience() {
        let c4 = Note(pitch: 60, tpc: 14)
        let cSharp4 = c4.shifted(bySemitones: 1)
        #expect(cSharp4?.pitch == 61)
        #expect(cSharp4?.tpc == 21)
        // Out of range above
        let high = Note(pitch: 127, tpc: 19)
        #expect(high.shifted(bySemitones: 1) == nil)
        // Out of range below
        let low = Note(pitch: 0, tpc: 14)
        #expect(low.shifted(bySemitones: -1) == nil)
    }

    @Test("Note.shifted preserves ties / accidental override / glissando")
    func noteShiftedPreservesMetadata() {
        let original = Note(
            pitch: 60, tpc: 14,
            accidental: .natural,
            tieForward: 1)
        let shifted = original.shifted(bySemitones: 2)
        #expect(shifted?.pitch == 62)
        #expect(shifted?.tpc == 16)
        #expect(shifted?.accidental == .natural)
        #expect(shifted?.tieForward == 1)
    }
}
