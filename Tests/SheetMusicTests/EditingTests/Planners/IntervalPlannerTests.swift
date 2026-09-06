@testable import SheetMusicCore
import Testing

@Suite("IntervalPlanner")
struct IntervalPlannerTests {
    // MARK: - diatonicThirdAbove

    @Test func `diatonic third above C4 in C major lands on E4`() {
        let result = IntervalPlanner.diatonicThirdAbove(Note(pitch: 60, tpc: 14), keySig: 0)

        #expect(result?.pitch == 64)
        #expect(result?.tpc == 18)
    }

    @Test func `diatonic third above E4 in C major lands on G4`() {
        let result = IntervalPlanner.diatonicThirdAbove(Note(pitch: 64, tpc: 18), keySig: 0)

        #expect(result?.pitch == 67)
        #expect(result?.tpc == 15)
    }

    @Test func `diatonic third above D4 in D major lands on F sharp 4`() {
        let result = IntervalPlanner.diatonicThirdAbove(Note(pitch: 62, tpc: 16), keySig: 2)

        #expect(result?.pitch == 66)
        #expect(result?.tpc == 20)
    }

    @Test func `diatonic third above A4 in F major carries the octave to C5`() {
        let result = IntervalPlanner.diatonicThirdAbove(Note(pitch: 69, tpc: 17), keySig: -1)

        #expect(result?.pitch == 72)
        #expect(result?.tpc == 14)
    }

    @Test func `diatonic third past the MIDI ceiling returns nil`() {
        let result = IntervalPlanner.diatonicThirdAbove(Note(pitch: 127, tpc: 15), keySig: 0)

        #expect(result == nil)
    }

    // MARK: - octaveAbove

    @Test func `octave above C4 lands on C5 with the same tpc`() {
        let result = IntervalPlanner.octaveAbove(Note(pitch: 60, tpc: 14))

        #expect(result?.pitch == 72)
        #expect(result?.tpc == 14)
    }

    @Test func `octave above pitch 115 stays within the MIDI ceiling`() {
        let result = IntervalPlanner.octaveAbove(Note(pitch: 115, tpc: 22))

        #expect(result?.pitch == 127)
        #expect(result?.tpc == 22)
    }

    @Test func `octave above pitch 116 returns nil`() {
        let result = IntervalPlanner.octaveAbove(Note(pitch: 116, tpc: 22))

        #expect(result == nil)
    }

    // MARK: - note(_:above:keySig:)

    /// MuseScore's `Alt`+1…0, every degree it offers, read off C4 in C major. The interval NUMBER is the argument,
    /// so the step count is one less — which is why 8 is the octave and 10 the tenth (`Alt+0`), not the other way
    /// round.
    @Test(arguments: [
        (1, 60, 14), (2, 62, 16), (3, 64, 18), (4, 65, 13), (5, 67, 15),
        (6, 69, 17), (7, 71, 19), (8, 72, 14), (9, 74, 16), (10, 76, 18),
    ])
    func `every degree above C4 in C major`(degrees: Int, pitch: Int, tpc: Int) {
        let result = IntervalPlanner.note(degrees, above: Note(pitch: 60, tpc: 14), keySig: 0)

        #expect(result?.pitch == pitch)
        #expect(result?.tpc == tpc)
    }

    /// The octave rule, and the only case where it is observable: an octave keeps the reference's OWN spelling
    /// rather than the one the key would give. C♯4 in C major (tpc 21) → C♯5, not the C♮ the signature spells.
    /// MuseScore's `useOctaveRule` (`engraving/editing/cmd.cpp`).
    @Test func `an octave keeps an altered note's spelling instead of re-reading the key`() {
        let result = IntervalPlanner.note(8, above: Note(pitch: 61, tpc: 21), keySig: 0)

        #expect(result?.pitch == 73)
        #expect(result?.tpc == 21)
    }

    /// And the contrast that makes the rule mean something: a NON-octave degree above the same C♯ is read from the
    /// key, so the alteration is not carried.
    @Test func `a third above an altered note is spelled in key`() {
        let result = IntervalPlanner.note(3, above: Note(pitch: 61, tpc: 21), keySig: 0)

        #expect(result?.pitch == 64)
        #expect(result?.tpc == 18)
    }

    /// Negative degrees read downward — what `AddIntervalToSelection` uses for MuseScore's `Shift+Alt` row.
    @Test func `a negative degree reads downward`() {
        let result = IntervalPlanner.note(-3, above: Note(pitch: 64, tpc: 18), keySig: 0)

        #expect(result?.pitch == 60)
        #expect(result?.tpc == 14)
    }
}
