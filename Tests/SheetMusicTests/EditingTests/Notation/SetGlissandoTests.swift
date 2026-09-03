@testable import SheetMusicCore
import Testing

/// `SetGlissando` — spec row 54, including the cross-bar destination check a write depends on.
@Suite("SetGlissando")
struct SetGlissandoTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func note(_ measure: Int, _ element: Int, _ note: Int) -> NoteID {
        NoteID(
            staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: note,
        )
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("a write lands on the note, with its style and visual type")
    func writes() throws {
        var score = EditingFixtures.parityFixture()
        let value = Glissando(style: .diatonic, visualType: .wavy, text: "gliss.")
        _ = try SetGlissando(at: Self.note(0, 1, 0), glissando: value).apply(to: &score)
        #expect(score[Self.note(0, 1, 0)]?.glissando == value)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetGlissando(at: Self.note(0, 1, 0), glissando: Glissando()).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("nil clears")
    func clears() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.note(0, 1, 0)
        _ = try SetGlissando(at: target, glissando: Glissando()).apply(to: &score)
        _ = try SetGlissando(at: target, glissando: nil).apply(to: &score)
        #expect(score[target]?.glissando == nil)
    }

    @Test("the siblings are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetGlissando(at: Self.note(0, 1, 0), glissando: Glissando()).apply(to: &score)
        #expect(score[Self.note(0, 2, 0)]?.glissando == nil)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
    }

    @Test("a write on the last sounding chord of the voice is refused — the destination is implicit")
    func refusedWithNoDestination() {
        var score = EditingFixtures.parityFixture()
        let before = score
        // m2's tied tail is the staff's last sounding chord: m3 is a measure rest.
        let noDestination = #expect(throws: SheetMusicError.self) {
            _ = try SetGlissando(at: Self.note(2, 1, 0), glissando: Glissando()).apply(to: &score)
        }
        #expect(Self.reason(of: noDestination) == .noNextChord(at: Self.slot(2, 1)))
        #expect(score == before)
    }

    @Test("a clear at that same note is allowed")
    func clearNeedsNoDestination() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.note(2, 1, 0)
        // Plant one directly: no write could put it there, which is exactly the case the clear exists for.
        guard case var .chord(chord) = score[Self.slot(2, 1)] else {
            Issue.record("expected a chord")
            return
        }
        chord.notes[0].glissando = Glissando()
        score[Self.slot(2, 1)] = .chord(chord)
        #expect(score[target]?.glissando != nil)
        _ = try SetGlissando(at: target, glissando: nil).apply(to: &score)
        #expect(score[target]?.glissando == nil)
    }

    @Test("a note index past the chord, and a rest, are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let missingNote = #expect(throws: SheetMusicError.self) {
            _ = try SetGlissando(at: Self.note(0, 1, 3), glissando: Glissando()).apply(to: &score)
        }
        #expect(Self.reason(of: missingNote) == .noteNotFound(Self.note(0, 1, 3)))
        // A rest is a chord with no notes, so its note 0 does not resolve either.
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetGlissando(at: Self.note(0, 3, 0), glissando: Glissando()).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .noteNotFound(Self.note(0, 3, 0)))
        #expect(score == before)
    }
}
