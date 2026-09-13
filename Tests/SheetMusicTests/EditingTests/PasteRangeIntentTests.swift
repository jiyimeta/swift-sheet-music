@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// Tests `.pasteRange`, the `EditIntent` a host's ⌘V relays — index 86 on the wire, the sibling of `.duplicateRange`
/// at 85. Its own file rather than folded into the range-intent codec tests: unlike every other range intent it
/// needs a `payloadReader`, and the reader itself is what these tests are mostly about.
@Suite("PasteRange intent")
struct PasteRangeIntentTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func payloadText(_ range: VoiceElementRange, in score: Score) throws -> String {
        let payload = try #require(RangeCopyPayload.score(for: range, in: score))
        return try #require(String(data: MSCXEncoder.encode(payload), encoding: .utf8))
    }

    /// A session that carries a real reader — the shape a host wires at the seam where it already links
    /// `SheetMusicMSCX` — applies a well-formed payload as one undo step.
    @Test("the intent applies as one undo step when the session carries a payload reader")
    func appliesAsOneStep() throws {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture(), payloadReader: MSCXParser.parse)
        let before = session.score.stableFingerprint
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: session.score,
        )
        #expect(session.apply(.pasteRange(at: Self.slot(1, 0), payload: text)))
        #expect(session.score.stableFingerprint != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    /// Bytes `MSCXParser.parse` cannot read at all are `.unreadablePayload` — a session WITH a reader ran it and
    /// the reader itself rejected the bytes, distinct from a session that never had a reader to run.
    @Test("an unreadable payload refuses and leaves the score alone")
    func refusesGarbage() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture(), payloadReader: MSCXParser.parse)
        let before = session.score.stableFingerprint
        #expect(!session.apply(.pasteRange(at: Self.slot(1, 0), payload: "<nonsense/>")))
        #expect(session.score.stableFingerprint == before)
        #expect(session.lastRefusal?.reason == .unreadablePayload)
    }

    /// A session built with the plain `ScoreEditSession(score:)` initializer — every existing caller in this
    /// package and in a host that hasn't wired paste yet — carries the DEFAULT reader, which refuses without
    /// looking at the bytes at all. Even a byte-for-byte VALID payload is refused here, and specifically with
    /// `.noPayloadReader`, not `.unreadablePayload`: the failure is "nobody wired a reader in", not "the
    /// clipboard held garbage", and a host's copy has to be able to tell the two apart.
    @Test("a session with no payload reader refuses with the no-reader reason, not the unreadable one")
    func refusesWithoutPayloadReader() throws {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score.stableFingerprint
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: session.score,
        )
        #expect(!session.apply(.pasteRange(at: Self.slot(1, 0), payload: text)))
        #expect(session.score.stableFingerprint == before)
        #expect(session.lastRefusal?.reason == .noPayloadReader)
    }
}
