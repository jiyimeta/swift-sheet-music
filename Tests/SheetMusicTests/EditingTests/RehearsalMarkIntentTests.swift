@testable import SheetMusicCore
import Testing

/// The two rehearsal-mark intents as a session plans and applies them: what lands, what resolves to nothing, and
/// that undo/redo round-trips the lane.
@Suite("Rehearsal mark intents")
struct RehearsalMarkIntentTests {
    private static func blankScore() -> Score {
        let staff = Staff(measures: (0 ..< 4).map { _ in
            Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        })
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    private static func markText(in score: Score, measureIndex: Int) -> String? {
        RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.text
    }

    @Test("setting a mark lands and undo takes it back out")
    func setAndUndo() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(Self.markText(in: session.score, measureIndex: 1) == "A")
        #expect(session.undo())
        #expect(session.score.systemMeasures.isEmpty)
        #expect(session.redo())
        #expect(Self.markText(in: session.score, measureIndex: 1) == "A")
    }

    @Test("renaming replaces the text in place")
    func rename() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "Bridge")))
        #expect(Self.markText(in: session.score, measureIndex: 1) == "Bridge")
        #expect(session.score.systemMeasures[1].elements.count == 1)
    }

    @Test("restating the same text is nothing to apply, not a refusal")
    func restatingIsNoOp() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(!session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    /// The no-op is decided against the TRIMMED text — the text the command would go on to write — so a field
    /// re-submitted with a stray space is the same no-op as re-submitting it untouched. Comparing the raw text
    /// instead would leave every one of the other tests green while pushing a dead undo entry here.
    @Test("a re-submitted mark with stray whitespace is the same no-op")
    func restatingWithStrayWhitespaceIsNoOp() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(!session.apply(.setRehearsalMark(measureIndex: 1, text: "  A  ")))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("removing where there is no mark is nothing to apply")
    func removingNothingIsNoOp() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(!session.apply(.removeRehearsalMark(measureIndex: 2)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("removing a mark lands and undo puts it back")
    func removeAndUndo() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 2, text: "C")))
        #expect(session.apply(.removeRehearsalMark(measureIndex: 2)))
        #expect(Self.markText(in: session.score, measureIndex: 2) == nil)
        #expect(session.undo())
        #expect(Self.markText(in: session.score, measureIndex: 2) == "C")
    }

    @Test("empty text reaches the command and is refused")
    func emptyTextRefused() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(!session.apply(.setRehearsalMark(measureIndex: 0, text: "  ")))
        #expect(session.lastRefusal?.reason == .emptyRehearsalMarkText)
    }

    /// `EditIntent.setRehearsalMark`'s doc says an out-of-range bar surfaces as `.targetNotFound`, and only the
    /// command states that range — the planner deliberately does not. Pinned here because a range guard added to
    /// `setRehearsalMarkCommand` would return `nil` instead, quietly turning the refusal into `.nothingToApply`
    /// with every other test in this suite still green.
    @Test("an out-of-range bar is refused as targetNotFound, not planned away")
    func outOfRangeIsRefused() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(!session.apply(.setRehearsalMark(measureIndex: 4, text: "A")))
        #expect(session.lastRefusal?.reason == .targetNotFound(VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 4, voiceIndex: 0, elementIndex: 0,
        )))
    }

    @Test("a mark changes the score's fingerprint")
    func fingerprintMoves() {
        let session = ScoreEditSession(score: Self.blankScore())
        let before = session.score.stableFingerprint
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(session.score.stableFingerprint != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }
}
