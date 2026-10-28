@testable import SheetMusicCore
import Testing

/// Lengths a drum staff makes heard (design 2026-10-26, drum voice conversion, §4.4, §4.7): a tied note must end
/// where its partner starts and a roll lasts its written length, so a chord holding either keeps its source length
/// and value; a bar where that cannot be kept is left exactly as written, and the rest of the staff still converts.
@Suite("RevoiceDrumStaff audible lengths")
struct RevoiceAudibleLengthTests {
    private static let roll = Tremolo(subtype: .r16)

    /// `score` with a roll of `span` on the chord at `element` of bar 0's voice `voice`.
    private static func rolling(
        _ score: Score, voice: Int = 0, element: Int, span: Tremolo.Span = .single,
    ) -> Score {
        RevoiceFixtures.editingChord(score, measure: 0, voice: voice, element: element) { chord in
            chord.tremolo = Tremolo(subtype: roll.subtype, span: span)
        }
    }

    /// The roll of each chord and rest of bar 0's voice `voice`, in order.
    private static func rolls(_ score: Score, voice: Int) -> [Tremolo?] {
        guard let voices = score[RevoiceFixtures.staff]?.measures[0].voices, voices.indices.contains(voice) else {
            return []
        }
        var result: [Tremolo?] = []
        for case let .chord(chord) in voices[voice].elements {
            result.append(chord.tremolo)
        }
        return result
    }

    private static func preview(_ score: Score, to map: [Int: Int]) -> RevoicePreview {
        RevoiceDrumStaff(staff: RevoiceFixtures.staff, voiceForPitch: map, policy: .default).preview(in: score)
    }

    @Test func `a tied crash keeps its length and its tie`() throws {
        let score = RevoiceFixtures.score([
            ["H/8 H/8 H/8 H/8 H/8 H/8 C/4~", "K/4 r/4 K/4 r/4"], ["~C/4 H/4 H/4 H/4"],
        ])
        #expect(FormatRhythmsGate.danglingTies(in: score) == 0)
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H+K/8 H/8 H/8 H/8 H+K/8 H/8 C/4~"])
        #expect(RevoiceFixtures.voices(after, measure: 1) == ["~C/4 H/4 H/4 H/4"])
        #expect(FormatRhythmsGate.danglingTies(in: after) == 0)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The crash on beat 2 ends the tie from beat 1, so it keeps its eighth. Were its length free, it would reach
    /// beat 3 as a quarter and ring an eighth longer.
    @Test func `a tie arriving in a bar keeps the tied note's length`() throws {
        let score = RevoiceFixtures.score([["C/4~ ~C/8 r/8 r/2", "K/4 r/4 r/2"]])
        #expect(FormatRhythmsGate.danglingTies(in: score) == 0)
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["C+K/4 ~C/8 r/8 r/2"])
        #expect(FormatRhythmsGate.danglingTies(in: after) == 0)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The design's own example (§4.4): in one voice the kick on the "and" of 1 would start inside the snare roll on
    /// 1, so bar 0 stays as written and bar 1 still converts.
    @Test func `a roll with a kick inside it leaves the bar as written`() throws {
        let score = Self.rolling(RevoiceFixtures.score([
            ["S/4 S/4 S/4 S/4", "K/8 K/8 r/4 r/2"], ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"],
        ]), element: 1)
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [1], measuresLeftAsWritten: [0]))
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
        #expect(plan == .leftAsWritten(.audibleLength))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures[0].voices == score.parts[0].staves[0].measures[0].voices)
        #expect(RevoiceFixtures.voices(after, measure: 1) == ["H+K/4 H/4 H/4 H/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `a roll that splits keeps rolling in both voices`() throws {
        let score = Self.rolling(RevoiceFixtures.score([["S+K/4 H/4 H/4 H/4"]]), element: 1)
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(Self.rolls(after, voice: 0) == [Self.roll, nil, nil, nil])
        #expect(Self.rolls(after, voice: 1) == [Self.roll, nil, nil])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// Were its length free, the snare on beat 2 would be written as the first value the meter spells for its span —
    /// a quarter, since a half there crosses the middle of the bar — and the roll would stop half-way. It keeps the
    /// half it was written as.
    @Test func `a roll keeps the value it was written as`() throws {
        let score = Self.rolling(RevoiceFixtures.score([["H+K/4 S/2 H/4"]]), element: 2)
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 S/2 H/4", "K/4 r/4 r/2"])
        #expect(Self.rolls(after, voice: 0) == [nil, Self.roll, nil])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// A crash tied over beat 2 and a ride tied over beat 3 start together; in one voice a single chord would have to
    /// end at both partners.
    @Test func `tied hits of different lengths at one onset leave the bar as written`() {
        let score = RevoiceFixtures.score([["C/4~ ~C/4 r/2", "R/2~ ~R/2"]])
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
        #expect(plan == .leftAsWritten(.audibleLength))
    }

    /// Both voices sound the crash on 4 and only the second voice's is tied into bar 1. In one voice the two are one
    /// note, the first voice's, which would drop the tie.
    @Test func `a doubled hit whose ties differ leaves the bar as written`() {
        let score = RevoiceFixtures.score([["H/4 H/4 H/4 C/4", "r/2. C/4~"], ["~C/4 H/4 H/4 H/4"]])
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
        #expect(plan == .leftAsWritten(.audibleLength))
    }

    /// A plain kick merged onto a rolled snare would roll with it, or the snare would stop rolling; either changes
    /// what plays (§4.5).
    @Test func `a kick merged onto a rolled snare leaves the bar as written`() {
        let score = Self.rolling(RevoiceFixtures.score([["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"]]), element: 1)
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
        #expect(plan == .leftAsWritten(.markings))
    }

    @Test func `a glissando leaves the bar as written`() {
        let score = RevoiceFixtures.editingChord(
            RevoiceFixtures.score([["H+K/4 T/4 T/4 H/4"]]), measure: 0, voice: 0, element: 2,
        ) { chord in
            chord.notes.updateNote(at: 0) { $0.glissando = Glissando() }
        }
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
        #expect(plan == .leftAsWritten(.unsupported))
    }

    @Test func `a two-note tremolo leaves the bar as written`() {
        let score = Self.rolling(RevoiceFixtures.score([["S+K/4 S/4 H/4 H/4"]]), element: 1, span: .between)
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
        #expect(plan == .leftAsWritten(.unsupported))
    }

    @Test func `a bar with nothing convertible plans to nothing but is reported`() throws {
        let score = Self.rolling(RevoiceFixtures.score([["S/4 S/4 S/4 S/4", "K/8 K/8 r/4 r/2"]]), element: 1)
        #expect(try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice).plan == nil)
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [], measuresLeftAsWritten: [0]))
    }
}
