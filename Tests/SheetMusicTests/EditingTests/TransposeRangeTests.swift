@testable import SheetMusicCore
import Testing

@Suite("TransposeRange")
struct TransposeRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func note(_ score: Score, _ measure: Int, _ element: Int) -> Note? {
        guard case let .chord(chord)? = score[slot(measure, element)] else { return nil }
        return chord.notes.first
    }

    @Test("every note in the range moves, spelled by the chromatic rule")
    func transposesUp() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4 q, D4 q, r, r]
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))
        _ = try TransposeRange(over: range, semitones: 2, respellInKey: false).apply(to: &score)
        #expect(Self.note(score, 0, 1)?.pitch == 62)
        #expect(Self.note(score, 0, 1)?.tpc == 16)
        #expect(Self.note(score, 0, 2)?.pitch == 64)
        #expect(Self.note(score, 0, 2)?.tpc == 18)
        #expect(Self.note(score, 0, 2)?.accidental == nil)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(2, 1))
        let inverse = try TransposeRange(over: range, semitones: -5, respellInKey: true).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a tie chain moves whole when only one member is in range, accidental on the head only")
    func tieChainMovesTogether() throws {
        var score = EditingFixtures.parityFixture() // m2: E4 h tied → E4 h
        let range = VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 0))
        _ = try TransposeRange(over: range, semitones: 3, respellInKey: false).apply(to: &score)
        let head = Self.note(score, 2, 0)
        let tail = Self.note(score, 2, 1)
        #expect(head?.pitch == 67)
        #expect(tail?.pitch == 67)
        #expect(head?.tpc == tail?.tpc)
        #expect(tail?.accidental == nil)
        #expect(head?.tieForward == 1)
        #expect(tail?.tieBack == 1)
    }

    @Test("respellInKey replaces the chromatic rule's double-alteration spelling with the simplest one")
    func respellInKey() throws {
        var chromatic = EditingFixtures.parityFixture()
        var respelled = chromatic
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1)) // C4
        _ = try TransposeRange(over: range, semitones: 3, respellInKey: false).apply(to: &chromatic)
        _ = try TransposeRange(over: range, semitones: 3, respellInKey: true).apply(to: &respelled)
        #expect(Self.note(chromatic, 0, 1)?.pitch == 63)
        #expect(Self.note(chromatic, 0, 1)?.tpc == 23) // D♯ — the rule alternates letter and alteration
        #expect(Self.note(respelled, 0, 1)?.pitch == 63)
        #expect(Self.note(respelled, 0, 1)?.tpc == 11) // E♭ — simplest in C major
        #expect(Self.note(respelled, 0, 1)?.accidental == .flat)
    }

    @Test("a range holding only rests changes nothing")
    func restsAreLeftAlone() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let range = VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3))
        _ = try TransposeRange(over: range, semitones: 4, respellInKey: false).apply(to: &score)
        #expect(score == before)
    }

    @Test("more than two octaves, or a range that resolves to nothing, is refused and leaves the score untouched")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))
        let tooFar = #expect(throws: SheetMusicError.self) {
            _ = try TransposeRange(over: range, semitones: 25, respellInKey: false).apply(to: &score)
        }
        #expect(Self.reason(of: tooFar) == .invalidTransposition(semitones: 25))
        let nowhere = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try TransposeRange(over: nowhere, semitones: 1, respellInKey: false).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 1)))
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
