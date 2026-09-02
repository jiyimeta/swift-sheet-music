@testable import SheetMusicCore
import Testing

@Suite("DeleteRange")
struct DeleteRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int, _ index: Int = 0) -> Voice {
        score.parts[0].staves[0].measures[measure].voices[index]
    }

    @Test("every chord becomes a rest; a bar left all-rests collapses to one measure rest")
    func deletesAndCollapses() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4 q, D4 q, r, r]
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)), .rest(duration: .measure),
        ])
        #expect(Self.voice(score, 0).tuplets.isEmpty)
    }

    @Test("a bar that still holds a note keeps its rhythm")
    func partialDeleteKeepsRhythm() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    /// The mirror of `partialDeleteKeepsRhythm`: the survivor sits at tick 0 rather than after the deleted slot.
    /// The collapse used to be planned against whatever element started at tick 0 — which here is the C4 nobody
    /// deleted — and `FullMeasureRestCollapse` exempts the slot it is named with from its all-rests check, so the
    /// bar collapsed and took the C4 with it.
    @Test("a survivor on beat 1 is kept when a later beat is deleted")
    func survivorOnBeatOneIsKept() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4 q, D4 q, r, r]
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 2))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    @Test("deleting beats 2-4 of a full bar keeps beat 1 and its rhythm")
    func deletingTailKeepsBeatOne() throws {
        var score = Self.fourChordBar()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 4))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    @Test("deleting all four beats still collapses to one measure rest")
    func deletingEveryBeatCollapses() throws {
        var score = Self.fourChordBar()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)), .rest(duration: .measure),
        ])
    }

    @Test("a one-slot DeleteRange and a click-delete of the same slot agree")
    func agreesWithClickDelete() throws {
        var ranged = EditingFixtures.parityFixture()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 2))).apply(to: &ranged)
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.delete(at: Self.slot(0, 2))))
        #expect(ranged.stableFingerprint == session.score.stableFingerprint)
    }

    /// `parityFixture`'s bar 0 with its two trailing rests overwritten as E4 and F4 quarters — a bar of four
    /// chords, so a tail delete has a survivor on beat 1 and a whole-bar delete has nothing left.
    private static func fourChordBar() -> Score {
        var score = EditingFixtures.parityFixture()
        score[slot(0, 3)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)]))
        score[slot(0, 4)] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)]))
        return score
    }

    @Test("undo restores the score exactly, collapse included")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(2, 1)))
            .apply(to: &score)
        #expect(Self.voice(score, 2).elements == [.rest(duration: .measure)])
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a second voice is deleted with the first, and each collapses on its own")
    func everyVoiceInTheBand() throws {
        var score = EditingFixtures.parityFixture()
        _ = try MoveToVoice(at: Self.slot(0, 2), to: VoiceRef(staff: Self.flute, measureIndex: 0, voiceIndex: 1))
            .apply(to: &score) // v0: [ts, C4, r, r, r]; v1: [r q, D4 q, r h]
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)), .rest(duration: .measure),
        ])
        #expect(Self.voice(score, 0, 1).elements == [.rest(duration: .measure)])
    }

    @Test("a range of rests is left exactly as it is")
    func restsAreLeftAlone() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3))).apply(to: &score)
        #expect(score == before)
    }

    @Test("a range that resolves to nothing is refused")
    func refusesUnresolvable() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(8, 0))).apply(to: &score)
        }
    }
}
