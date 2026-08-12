@testable import SheetMusicCore
import Testing

@Suite("NoteInputPlanner")
struct NoteInputPlannerTests {
    @Test func `nearest B below reference C4 wins over B4`() {
        let result = NoteInputPlanner.pitch(forLetter: "b", nearestTo: 60)

        #expect(result?.pitch == 59)
        #expect(result?.tpc == 19)
    }

    @Test func `nearest F above reference C4 wins`() {
        let result = NoteInputPlanner.pitch(forLetter: "f", nearestTo: 60)

        #expect(result?.pitch == 65)
        #expect(result?.tpc == 13)
    }

    @Test func `a tied distance between two F octaves resolves upward`() {
        let result = NoteInputPlanner.pitch(forLetter: "f", nearestTo: 59)

        #expect(result?.pitch == 65)
        #expect(result?.tpc == 13)
    }

    @Test func `nil reference defaults to octave 4`() {
        let result = NoteInputPlanner.pitch(forLetter: "c", nearestTo: nil)

        #expect(result?.pitch == 60)
        #expect(result?.tpc == 14)
    }

    @Test func `an unrecognized letter returns nil`() {
        #expect(NoteInputPlanner.pitch(forLetter: "x", nearestTo: 60) == nil)
    }
}
