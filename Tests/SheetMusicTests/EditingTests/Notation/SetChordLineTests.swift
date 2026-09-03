@testable import SheetMusicCore
import Testing

/// `SetChordLine` and `SetNoteParentheses` — spec rows 56 and 57, including the single-line-per-chord v1 rule and
/// the pre-image inverse that rule forces.
@Suite("SetChordLine")
struct SetChordLineTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func note(_ measure: Int, _ element: Int, _ note: Int) -> NoteID {
        NoteID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: note)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    private static func lines(_ score: Score, _ id: VoiceElementID) -> [ChordLine]? {
        guard case let .chord(chord)? = score[id] else { return nil }
        return chord.chordLines
    }

    /// The parity fixture's first chord, widened to two notes so the parenthesis sibling case has a sibling.
    private static func twoNoteScore() -> (Score, VoiceElementID) {
        var score = EditingFixtures.parityFixture()
        let target = slot(0, 1)
        score[target] = .chord(Chord(duration: .quarter, notes: [
            Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18),
        ]))
        return (score, target)
    }

    // MARK: - SetChordLine

    @Test("a write lands one line on the chord")
    func writesLine() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetChordLine(at: Self.slot(0, 1), kind: .fall, isStraight: false).apply(to: &score)
        #expect(Self.lines(score, Self.slot(0, 1)) == [ChordLine(kind: .fall, isStraight: false)])
    }

    @Test("a second write replaces rather than appends — one line per chord in v1")
    func writeReplaces() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        _ = try SetChordLine(at: target, kind: .fall, isStraight: false).apply(to: &score)
        _ = try SetChordLine(at: target, kind: .doit, isStraight: true).apply(to: &score)
        #expect(Self.lines(score, target)?.count == 1)
        #expect(Self.lines(score, target) == [ChordLine(kind: .doit, isStraight: true)])
    }

    @Test("nil clears every line")
    func clearsLines() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        _ = try SetChordLine(at: target, kind: .plop, isStraight: false).apply(to: &score)
        _ = try SetChordLine(at: target, kind: nil, isStraight: false).apply(to: &score)
        #expect(Self.lines(score, target) == [])
    }

    @Test("a write over a chord carrying two lines keeps only the new one, and undo restores both")
    func replacesASeededPair() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        guard case var .chord(chord) = score[target] else {
            Issue.record("expected a chord")
            return
        }
        chord.chordLines = [ChordLine(kind: .scoop), ChordLine(kind: .fall)]
        score[target] = .chord(chord)
        let before = score
        let inverse = try SetChordLine(at: target, kind: .doit, isStraight: false).apply(to: &score)
        #expect(Self.lines(score, target) == [ChordLine(kind: .doit, isStraight: false)])
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the siblings are untouched by a chord-line write")
    func lineSiblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetChordLine(at: Self.slot(0, 1), kind: .fall, isStraight: false).apply(to: &score)
        #expect(Self.lines(score, Self.slot(0, 2)) == [])
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }

    @Test("a rest and a missing element are refused")
    func lineRefusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetChordLine(at: Self.slot(0, 3), kind: .fall, isStraight: false).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetChordLine(at: Self.slot(0, 9), kind: nil, isStraight: false).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(score == before)
    }

    // MARK: - SetNoteParentheses

    @Test("a write lands on the note")
    func writesParentheses() throws {
        var (score, _) = Self.twoNoteScore()
        _ = try SetNoteParentheses(at: Self.note(0, 1, 0), parentheses: .both).apply(to: &score)
        #expect(score[Self.note(0, 1, 0)]?.parentheses == .both)
    }

    @Test(".none clears, undo restores, and the sibling note is untouched")
    func clearsAndUndoesParentheses() throws {
        var (score, _) = Self.twoNoteScore()
        let before = score
        let target = Self.note(0, 1, 0)
        let inverse = try SetNoteParentheses(at: target, parentheses: .left).apply(to: &score)
        #expect(score[Self.note(0, 1, 1)]?.parentheses == NoteParentheses.none)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        _ = try SetNoteParentheses(at: target, parentheses: .right).apply(to: &score)
        _ = try SetNoteParentheses(at: target, parentheses: .none).apply(to: &score)
        #expect(score[target]?.parentheses == NoteParentheses.none)
    }

    @Test("the siblings are untouched by a parenthesis write")
    func parenthesisSiblingsUntouched() throws {
        var (score, _) = Self.twoNoteScore()
        let before = score
        _ = try SetNoteParentheses(at: Self.note(0, 1, 0), parentheses: .both).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }

    @Test("a note index past the chord, and a rest, are refused")
    func parenthesisRefusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let missingNote = #expect(throws: SheetMusicError.self) {
            _ = try SetNoteParentheses(at: Self.note(0, 1, 3), parentheses: .both).apply(to: &score)
        }
        #expect(Self.reason(of: missingNote) == .noteNotFound(Self.note(0, 1, 3)))
        // A rest is a chord with no notes, so its note 0 does not resolve either.
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetNoteParentheses(at: Self.note(0, 3, 0), parentheses: .both).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .noteNotFound(Self.note(0, 3, 0)))
        #expect(score == before)
    }
}
