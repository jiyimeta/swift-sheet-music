@testable import SheetMusicCore
import Testing

@Suite("SetDotsInRange")
struct SetDotsInRangeTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int, measure: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ pitch: Int, _ tpc: Int, _ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    /// One 4/4 bar, exactly full: `[ts, C4 q, r e, D4 e, r e, r q, r e]`. Two chords of DIFFERENT base lengths,
    /// each followed by rests a dot can grow into, which is what makes "every element keeps its own base" visible.
    private static func mixedBases() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            chord(60, 14, .quarter), .rest(duration: .eighth),
            chord(62, 16, .eighth), .rest(duration: .eighth),
            .rest(duration: .quarter), .rest(duration: .eighth),
        ])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])])
        return Score(division: 480, parts: [part])
    }

    private static func duration(_ score: Score, _ element: Int, measure: Int = 0) -> NoteDuration? {
        guard case let .chord(chord)? = score[slot(element, measure: measure)] else { return nil }
        return chord.duration
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    private static let bothChords = VoiceElementRange(start: slot(1), end: slot(3))

    @Test("each element keeps the base it is spelled with — a quarter and an eighth dot to 3/8 and 3/16")
    func eachElementKeepsItsBase() throws {
        var score = Self.mixedBases()
        _ = try SetDotsInRange(over: Self.bothChords, dots: 1).apply(to: &score)
        #expect(Self.duration(score, 1) == NoteDuration.quarter.dotted(1))
        #expect(Self.duration(score, 2) == NoteDuration.eighth.dotted(1))
    }

    @Test("dots 0 removes the dots, each element back to its own base")
    func zeroRemovesDots() throws {
        var score = Self.mixedBases()
        _ = try SetDotsInRange(over: Self.bothChords, dots: 1).apply(to: &score)
        let dotted = VoiceElementRange(start: Self.slot(1), end: Self.slot(2))
        _ = try SetDotsInRange(over: dotted, dots: 0).apply(to: &score)
        #expect(Self.duration(score, 1) == .quarter)
        #expect(Self.duration(score, 2) == .eighth)
    }

    @Test("a length with no dotted spelling is skipped, not refused — the rest of the range still moves")
    func measureRestIsSkipped() throws {
        var score = EditingFixtures.parityFixture() // m1 voice 1 is one `.measure` rest; m2 is two tied halves
        let range = VoiceElementRange(start: Self.slot(0, measure: 1), end: Self.slot(0, measure: 2))
        _ = try SetDotsInRange(over: range, dots: 1).apply(to: &score)
        // The measure rest is untouched…
        #expect(score[VoiceElementID(
            staff: Self.staff0, measureIndex: 1, voiceIndex: 1, elementIndex: 0,
        )] == .rest(duration: .measure))
        // …and the half that CAN be dotted was.
        #expect(Self.duration(score, 0, measure: 2) == NoteDuration.half.dotted(1))
    }

    @Test("an element inside a tuplet refuses the whole range before anything is written")
    func tupletRefusesWholeRange() throws {
        var score = Self.mixedBases()
        _ = try CreateTuplet(at: Self.slot(3), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let before = score
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try SetDotsInRange(over: Self.bothChords, dots: 1).apply(to: &score)
        }
        guard case .insideTuplet = Self.reason(of: refused) else {
            Issue.record("expected .insideTuplet, got \(String(describing: Self.reason(of: refused)))")
            return
        }
        #expect(score == before)
    }

    @Test("a count outside 0…3 is refused as notDottable, named at the range's head")
    func countOutOfRangeIsRefused() {
        var score = Self.mixedBases()
        let before = score
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try SetDotsInRange(over: Self.bothChords, dots: 4).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .notDottable(at: Self.slot(1)))
        #expect(score == before)
    }

    @Test("a range that resolves to nothing is refused as targetNotFound")
    func emptyRangeIsRefused() {
        var score = Self.mixedBases()
        let nowhere = VoiceElementRange(start: Self.slot(1), end: Self.slot(0, measure: 9))
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try SetDotsInRange(over: nowhere, dots: 1).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .targetNotFound(Self.slot(1)))
    }

    @Test("restating the dot count every element already has plans to nothing")
    func restatingIsNil() throws {
        let score = Self.mixedBases()
        #expect(try SetDotsInRange(over: Self.bothChords, dots: 0).plan(in: score, ids: EIDAllocator()) == nil)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = Self.mixedBases()
        let before = score
        let inverse = try SetDotsInRange(over: Self.bothChords, dots: 1).apply(to: &score)
        #expect(score != before)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the intent applies through the session as one undo step")
    func intentIsOneUndoStep() {
        let session = ScoreEditSession(score: Self.mixedBases())
        let before = session.score
        #expect(session.apply(.setDotsInRange(over: Self.bothChords, dots: 1)))
        #expect(session.score != before)
        #expect(session.undo())
        #expect(session.score == before)
    }
}
