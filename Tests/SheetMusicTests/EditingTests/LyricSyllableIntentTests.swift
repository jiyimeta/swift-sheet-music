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
    private static let third = id(element: 3)

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
        let written = SetLyric.current(at: cursor.location, verse: 0, in: session.score)
        #expect(written?.text == "glo")
        #expect(written?.syllabic == .begin)
        let destination = try #require(plan.next).location
        let repaired = SetLyric.current(at: destination, verse: 0, in: session.score)
        // The repair moves the destination's syllabic and leaves its text alone — it is the same syllable, now
        // spelled as the end of the hyphenated word rather than as a word of its own.
        #expect(repaired?.text == "so")
        #expect(repaired?.syllabic == .end)

        #expect(session.undo())
        #expect(SetLyric.current(at: cursor.location, verse: 0, in: session.score) == nil)
        let restored = SetLyric.current(at: destination, verse: 0, in: session.score)
        #expect(restored?.text == "so")
        #expect(restored?.syllabic == .single)
    }

    /// An empty write list is a no-op the session reports as unapplied, so a host that types nothing does not
    /// mint an empty undo step.
    @Test func emptyWriteListIsNotApplied() {
        let session = ScoreEditSession(score: EditingFixtures.twoConsecutiveC4Chords())
        #expect(!session.apply(.setLyricSyllables(writes: [])))
    }

    /// The plan's `command` and the command the INTENT plans to are the same edit — the same members in the same
    /// order, and the same anchor.
    ///
    /// Exercised on the three-write shape, which is the one that can tell the two apart: deleting a syllable that
    /// has both a preceding and a destination repair. `CompositeEditCommand.location` is what a host scrolls into
    /// view, so an anchor that differed between the two routes would be host-visible.
    @Test func planWritesMatchTheBundledCommand() throws {
        let score = Self.threeSyllableWord()
        let cursor = LyricInputPlanner.Cursor(location: Self.second, verse: 0)
        let plan = LyricInputPlanner.plan(typing: "", terminatedBy: .word, at: cursor, in: score)

        // The caret's own write leads; the two neighbor repairs follow it.
        #expect(plan.writes.map(\.location) == [Self.second, Self.first, Self.third])
        #expect(plan.writes.first?.text == nil)
        #expect(plan.writes.dropFirst().map(\.text) == ["glo", "a"])

        let composite = try #require(plan.command as? CompositeEditCommand)
        #expect(composite.commands.count == plan.writes.count)
        #expect(composite.commands.map(\.affectedLocation) == plan.writes.map(\.location))
        #expect(composite.location == cursor.location)

        // The same list, planned as an intent, has to come back as the same composite — this is what stops the
        // two bundling sites drifting apart.
        let viaIntent = try ScoreEditSession.command(
            for: .setLyricSyllables(writes: plan.writes), in: score, ids: EIDAllocator(), depth: 0,
        )
        let viaIntentComposite = try #require(viaIntent as? CompositeEditCommand)
        #expect(viaIntentComposite.location == composite.location)
        #expect(viaIntentComposite.commands.map(\.affectedLocation) == plan.writes.map(\.location))

        // "Empty exactly when `command` is `nil`", asserted from both ends rather than only the populated one.
        #expect((plan.command == nil) == plan.writes.isEmpty)
        // Typing nothing at a chord that carries no syllable, with no advance to repair into: the empty plan.
        let nothing = LyricInputPlanner.plan(
            typing: "",
            terminatedBy: .none,
            at: .init(location: Self.first, verse: 0),
            in: EditingFixtures.twoConsecutiveC4Chords(),
        )
        #expect(nothing.writes.isEmpty)
        #expect(nothing.command == nil)
    }

    /// Three consecutive C4 quarters carrying one hyphenated word — `glo-ri-a`, spelled begin / middle / end.
    /// The shape a deletion in the middle has to repair on both sides.
    private static func threeSyllableWord() -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        score[third] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        for (location, text, syllabic) in [
            (first, "glo", Syllabic.begin),
            (second, "ri", .middle),
            (third, "a", .end),
        ] {
            guard case var .chord(chord) = score[location] else {
                Issue.record("expected a chord at \(location)")
                continue
            }
            chord.lyrics = [Lyric(text: text, syllabic: syllabic)]
            score[location] = .chord(chord)
        }
        return score
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
