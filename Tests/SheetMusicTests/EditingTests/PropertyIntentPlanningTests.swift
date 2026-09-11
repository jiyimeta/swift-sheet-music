@testable import SheetMusicCore
@testable import SheetMusicEditWire
import Testing

@Suite("Property intents: planning and wire")
struct PropertyIntentPlanningTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let chord = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let note = NoteID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    )

    private static func populated() throws -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        try SetLyric(at: chord, verse: 0, text: "la", syllabic: .single).apply(to: &score)
        return score
    }

    private static let intents: [EditIntent] = [
        .setNoteSmall(at: note, isSmall: true),
        .setNotePlay(at: note, play: false),
        .setElementOffset(target: .lyric(anchor: chord, verse: 0), offset: ScoreOffset(x: 1, y: -2)),
        .setElementOffset(target: .lyric(anchor: chord, verse: 0), offset: nil),
        .setElementAutoplace(target: .lyric(anchor: chord, verse: 0), autoplace: false),
        .setElementAutoplace(target: .lyric(anchor: chord, verse: 0), autoplace: nil),
    ]

    @Test("each intent survives an encode and decode unchanged", arguments: intents)
    func wireRoundTrips(_ intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// `ScoreEditSession.apply` returns false for BOTH "nothing to do" and "refused", so the two are told apart
    /// by `lastRefusal.reason`. That distinction is the whole point of the planner unwrapping the carrier rather
    /// than the property's optional value, and it is what this pair of tests pins.
    @Test("a value the score already has is nothing to apply")
    func noOpReportsNothingToApply() throws {
        let session = try ScoreEditSession(score: Self.populated())
        #expect(session.apply(.setNotePlay(at: Self.note, play: true)) == false)
        #expect(session.lastRefusal?.reason == .nothingToApply)

        #expect(session.apply(
            .setElementOffset(target: .lyric(anchor: Self.chord, verse: 0), offset: nil),
        ) == false)
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("an absent carrier is refused by the command, not skipped by the planner")
    func absentCarrierIsRefusedNotSkipped() throws {
        let session = try ScoreEditSession(score: Self.populated())
        #expect(session.apply(
            .setElementOffset(target: .lyric(anchor: Self.chord, verse: 9), offset: nil),
        ) == false)
        let reason = try #require(session.lastRefusal?.reason)
        #expect(reason != .nothingToApply)
    }

    @Test("a written value is readable back through the session's score")
    func appliesThrough() throws {
        let session = try ScoreEditSession(score: Self.populated())
        #expect(session.apply(.setNoteSmall(at: Self.note, isSmall: true)))
        #expect(session.score[Self.note]?.isSmall == true)
    }
}
