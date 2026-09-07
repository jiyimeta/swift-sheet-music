@testable import SheetMusicCore
import Testing

/// `EditIntent.setLyricSyllables` — the plural intent that carries one lyric keystroke.
///
/// The plurality is the whole point: `LyricInputPlanner` repairs the syllables on either side of the one being
/// typed, and a host that applies intents rather than commands would otherwise have to issue those repairs as
/// separate intents, making one keystroke two or three undo steps.
@Suite("Lyric syllable intent")
struct LyricSyllableIntentTests {
    private static let first = id(element: 1)
    private static let second = id(element: 2)

    /// A hyphen-terminated syllable plans two writes — the syllable itself and the destination repair — and the
    /// intent applies both as one session step, so one undo takes both back.
    @Test func hyphenPlansTwoWritesAndUndoesAsOne() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        // Seed the destination so the planner has something to repair.
        _ = try SetLyric(at: Self.second, verse: 0, text: "so", syllabic: .single).apply(to: &score)

        let cursor = LyricInputPlanner.Cursor(location: Self.first, verse: 0)
        let plan = LyricInputPlanner.plan(typing: "glo", terminatedBy: .syllable, at: cursor, in: score)
        #expect(plan.writes.count == 2)

        let session = ScoreEditSession(score: score)
        #expect(session.apply(.setLyricSyllables(writes: plan.writes)))
        #expect(SetLyric.current(at: cursor.location, verse: 0, in: session.score)?.syllabic == .begin)
        let destination = try #require(plan.next).location
        #expect(SetLyric.current(at: destination, verse: 0, in: session.score)?.syllabic == .end)

        #expect(session.undo())
        #expect(SetLyric.current(at: cursor.location, verse: 0, in: session.score) == nil)
        #expect(SetLyric.current(at: destination, verse: 0, in: session.score)?.syllabic == .single)
    }

    /// An empty write list is a no-op the session reports as unapplied, so a host that types nothing does not
    /// mint an empty undo step.
    @Test func emptyWriteListIsNotApplied() {
        let session = ScoreEditSession(score: EditingFixtures.twoConsecutiveC4Chords())
        #expect(!session.apply(.setLyricSyllables(writes: [])))
    }

    /// Every write the planner emits is scalar, so the intent can be wire-projected without carrying model types.
    @Test func planWritesMatchTheBundledCommand() {
        let score = EditingFixtures.twoConsecutiveC4Chords()
        let cursor = LyricInputPlanner.Cursor(location: Self.first, verse: 0)
        let plan = LyricInputPlanner.plan(typing: "la", terminatedBy: .word, at: cursor, in: score)
        #expect(plan.writes.map(\.location) == [cursor.location])
        #expect(plan.writes.first?.text == "la")
        #expect((plan.command == nil) == plan.writes.isEmpty)
    }

    private static func id(measure: Int = 0, element: Int) -> VoiceElementID {
        VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: element,
        )
    }
}
