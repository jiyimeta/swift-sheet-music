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
}
