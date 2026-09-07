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

    // MARK: - above (the chord-add rule)

    /// The case that made this exist: the nearest A to C4 is the A BELOW it, which is not what "add a note to this
    /// chord" means. Same letter, same reference, opposite answer from `nearestTo`.
    @Test func `an A above C4 is A4, where the nearest A would have been A3`() {
        #expect(NoteInputPlanner.pitch(forLetter: "a", nearestTo: 60)?.pitch == 57)

        let result = NoteInputPlanner.pitch(forLetter: "a", above: 60)

        #expect(result?.pitch == 69)
        #expect(result?.tpc == 17)
    }

    /// Strictly above, so the letter the reference already IS goes an octave up — MuseScore's
    /// `if (note <= tpc2step(tpc)) octave++`.
    @Test func `a C above C4 is C5, not C4 itself`() {
        #expect(NoteInputPlanner.pitch(forLetter: "c", above: 60)?.pitch == 72)
    }

    /// And a letter only a semitone up stays in the same octave rather than skipping one.
    @Test func `a D above C4 is D4`() {
        #expect(NoteInputPlanner.pitch(forLetter: "d", above: 60)?.pitch == 62)
    }

    @Test func `nothing fits above the top of the range`() {
        #expect(NoteInputPlanner.pitch(forLetter: "c", above: 127) == nil)
    }

    @Test func `an unrecognized letter returns nil above too`() {
        #expect(NoteInputPlanner.pitch(forLetter: "x", above: 60) == nil)
    }
}
