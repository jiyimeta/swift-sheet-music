@testable import SheetMusicCore
import Testing

@Suite("Range planning")
struct RangePlanningTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static let chords = VoiceElementRange(start: slot(0, 1), end: slot(0, 2)) // C4, D4
    private static let rests = VoiceElementRange(start: slot(1, 0), end: slot(1, 3))

    @Test("each range intent applies through the session and undoes")
    func appliesAndUndoes() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        #expect(session.apply(.transposeRange(over: Self.chords, semitones: 2, respellInKey: false)))
        #expect(session.apply(.addIntervalToSelection(over: Self.chords, steps: 3)))
        #expect(session.apply(.setAccidentalsInRange(over: Self.chords, accidental: .sharp)))
        #expect(session.apply(.respellRange(over: Self.chords, mode: .preferFlats)))
        #expect(session.apply(.setDurationInRange(over: Self.rests, duration: .half)))
        #expect(session.apply(.deleteRange(over: Self.chords)))
        for _ in 0 ..< 6 {
            #expect(session.undo())
        }
        #expect(session.score == before)
    }

    @Test("restating what the score already says plans to nothing")
    func restatingIsNothingToApply() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.transposeRange(over: Self.chords, semitones: 0, respellInKey: false)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(!session.apply(.transposeRange(over: Self.rests, semitones: 5, respellInKey: false)))
        #expect(!session.apply(.addIntervalToSelection(over: Self.chords, steps: 1)))
        #expect(!session.apply(.deleteRange(over: Self.rests)))
        #expect(!session.apply(.setAccidentalsInRange(over: Self.chords, accidental: nil)))
        // Not `Self.rests`: measure 1 also holds a second voice — one whole-measure rest — whose onset falls
        // inside `Self.rests`' tick span too (`Score.voiceElements(in:)` resolves every voice, by design), so no
        // single duration can already match both that rest and voice 0's four quarters. Measure 3 has one voice
        // only, already a measure rest, so asking for `.measure` there is a genuine no-op.
        #expect(!session.apply(.setDurationInRange(
            over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)), duration: .measure,
        )))
        #expect(!session.apply(.respellRange(over: Self.chords, mode: .simplest)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("a refused command surfaces its reason, not nothingToApply and not a crash")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.transposeRange(over: Self.chords, semitones: 30, respellInKey: false)))
        #expect(session.lastRefusal?.reason == .invalidTransposition(semitones: 30))
        let nowhere = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0))
        #expect(!session.apply(.deleteRange(over: nowhere)))
        #expect(session.lastRefusal?.reason == .targetNotFound(Self.slot(0, 1)))
    }

    @Test("glyphs come out right through the session, repair pass included")
    func glyphsThroughTheSession() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.transposeRange(over: Self.chords, semitones: 1, respellInKey: false)))
        guard case let .chord(first)? = session.score[Self.slot(0, 1)],
              case let .chord(second)? = session.score[Self.slot(0, 2)]
        else { Issue.record("expected chords"); return }
        #expect(first.notes[0].accidental == .sharp) // C♯
        #expect(second.notes[0].accidental == .sharp) // D♯ on a fresh line still needs its glyph
    }
}
