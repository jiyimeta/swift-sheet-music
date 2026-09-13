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

    @Test("the covered slots become the rests that spell their combined length")
    func deletedRunIsRespelled() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4 q, D4 q, r, r]
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(Self.voice(score, 0).tuplets.isEmpty)
    }

    /// The rule this command exists to keep: the two quarter rests the range did NOT cover are still two quarter
    /// rests. Before 2026-09-13 deleting the two notes collapsed the whole bar to a measure rest, swallowing them.
    @Test("rests outside the range are left exactly as they are")
    func restsOutsideTheRangeSurvive() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    /// The spec's own example: two dotted eighths deleted together total 6/16, which reads as a quarter rest plus an
    /// eighth rest — not as the two dotted eighth rests a slot-by-slot delete would leave.
    @Test("two dotted eighths come back as a quarter rest plus an eighth rest")
    func dottedRunIsRespelledOnTheGrid() throws {
        var score = Self.dottedEighthBar()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter), .rest(duration: .eighth),
            .rest(duration: .quarter), .rest(duration: .eighth), .rest(duration: .quarter),
        ])
    }

    /// The mirror of `restsOutsideTheRangeSurvive`: the survivor sits at tick 0 rather than after the deleted slot.
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

    @Test("deleting beats 2-4 of a full bar keeps beat 1 and spells the rest as one quarter plus one half")
    func deletingTailKeepsBeatOne() throws {
        var score = Self.fourChordBar()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 4))).apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter), .rest(duration: .half),
        ])
    }

    @Test("deleting all four beats collapses to one measure rest")
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

    /// A 4/4 bar opening with two dotted eighths (3/16 + 3/16), then rests filling the remaining 10/16.
    private static func dottedEighthBar() -> Score {
        let dotted = NoteDuration.eighth.dotted(1)
        return VoiceIdentityFixtures.score([[Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: dotted, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: dotted, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .eighth), .rest(duration: .quarter),
        ])]])
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

    /// A range that holds nothing but rests is not inert: covering the bar's whole rhythm means the bar is silent,
    /// and a silent bar is one measure rest. `parityFixture`'s bar 1 is four quarter rests.
    @Test("a bar's worth of rests collapses to one measure rest")
    func coveredRestsCollapse() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3))).apply(to: &score)
        #expect(Self.voice(score, 1).elements == [.rest(duration: .measure)])
        #expect(Self.voice(score, 1, 1).elements == [.rest(duration: .measure)])
    }

    /// Part of that same bar, though, is re-spelled and nothing else moves: the first two quarter rests total a
    /// half, the last two stay put.
    @Test("part of a bar's rests is re-spelled without touching the rest of it")
    func partOfTheRestsIsRespelled() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 1))).apply(to: &score)
        #expect(Self.voice(score, 1).elements == [
            .rest(duration: .half), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    /// A `.measure` rest the range covers on its own is already the spelling the collapse would write, so the
    /// command has nothing to do — and must not rewrite it as the literal `.whole` that totals the same ticks.
    @Test("a measure rest covered on its own is left as it is")
    func measureRestIsInert() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0))).apply(to: &score)
        #expect(score == before)
    }

    /// Tuplet members keep their own length and their bracket: folding them into a metric fill would be dissolving
    /// the tuplet, which is not what deleting its notes means.
    @Test("a partly covered triplet keeps its bracket and its member lengths")
    func tupletMembersAreClearedInPlace() throws {
        var score = TupletIdentityFixtures.score([
            VoiceIdentityFixtures.chord(), VoiceIdentityFixtures.chord(), VoiceIdentityFixtures.chord(),
        ])
        let range = VoiceElementRange(
            start: VoiceIdentityFixtures.location(0), end: VoiceIdentityFixtures.location(1),
        )
        _ = try DeleteRange(over: range).apply(to: &score)
        let voice = TupletIdentityFixtures.voice(score)
        #expect(voice.elements.values == [
            .rest(duration: .quarter), .rest(duration: .quarter), VoiceIdentityFixtures.chord(),
        ])
        #expect(voice.tupletSpans.map(\.startIndex) == [0])
        #expect(voice.tupletSpans.map(\.endIndex) == [2])
    }

    /// What a host collapses its range selection onto after ⌫. `DeleteRange.affectedLocation` can only report
    /// `range.start`, which is the anchor of a backward-drawn range and, after a collapse, an index that no longer
    /// exists — so the session plans `.deleteRange` to its composite and reports the planner's own answer.
    @Test("the session reports the first rest the delete wrote, whichever way the range was drawn")
    func reportsTheFirstRest() {
        let forward = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(forward.apply(.deleteRange(over: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 3)))))
        #expect(forward.lastAffectedLocation == Self.slot(0, 2))

        // Shift+← draws this one: the anchor is element 3 and the target element 2, so `range.start` is the LATER
        // slot and naming it would land the selection one beat past the rest the delete wrote.
        let backward = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(backward.apply(.deleteRange(over: VoiceElementRange(start: Self.slot(0, 3), end: Self.slot(0, 2)))))
        #expect(backward.lastAffectedLocation == Self.slot(0, 2))

        // The whole bar-voice, so it collapses: the measure rest lands right after the time signature, at element
        // 1, and the range's own start (element 4) is not an index the bar still has.
        let collapsed = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(collapsed.apply(.deleteRange(over: VoiceElementRange(start: Self.slot(0, 4), end: Self.slot(0, 1)))))
        #expect(collapsed.lastAffectedLocation == Self.slot(0, 1))
    }

    @Test("a range that resolves to nothing is refused")
    func refusesUnresolvable() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try DeleteRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(8, 0))).apply(to: &score)
        }
    }
}
