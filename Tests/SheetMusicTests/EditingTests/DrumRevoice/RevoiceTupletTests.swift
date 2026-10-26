@testable import SheetMusicCore
import Testing

/// Tuplets on a drum staff (design 2026-10-26, drum voice conversion, §4.5): a tuplet is carried as a unit into every
/// voice that receives a hit from it, with rests for the members that voice does not receive, and a voice that
/// receives nothing from it reads its span as ordinary time. Two tuplets merge member by member only when they share
/// span, ratio and grid, and a plain hit joins one only on a member onset; otherwise the bar is left as written, as it
/// is when tuplets nest.
@Suite("RevoiceDrumStaff tuplets")
struct RevoiceTupletTests {
    private static func preview(_ score: Score, to map: [Int: Int]) -> RevoicePreview {
        RevoiceDrumStaff(staff: RevoiceFixtures.staff, voiceForPitch: map, policy: .default).preview(in: score)
    }

    @Test func `a one-voice triplet sends its kicks to voice 2 as a triplet`() throws {
        let score = RevoiceFixtures.score([["3:2[H+K/8 H/8 H+K/8] H/4 H/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0)
            == ["3:2[H/8 H/8 H/8] H/4 H/2", "3:2[K/8 r/8 K/8] r/4 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `matching triplets in two voices merge member by member`() throws {
        let score = RevoiceFixtures.score([["3:2[H/8 H/8 H/8] H/4 H/2", "3:2[K/8 r/8 K/8] r/4 r/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["3:2[H+K/8 H/8 H+K/8] H/4 H/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The kick is written as a quarter but lands on the triplet's first member, so it takes that member's value.
    @Test func `a plain kick on a member onset joins the triplet`() throws {
        let score = RevoiceFixtures.score([["3:2[H/8 H/8 H/8] H/4 H/2", "K/4 r/4 r/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["3:2[H+K/8 H/8 H/8] H/4 H/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The kick on the second sixteenth falls between the triplet's first two members. Bar 1, whose kick lands on a
    /// member, still converts.
    @Test func `a kick between triplet members leaves the bar as written`() throws {
        let score = RevoiceFixtures.score([
            ["3:2[H/8 H/8 H/8] H/4 H/2", "r/16 K/16 r/8 r/4 r/2"], ["3:2[H/8 H/8 H/8] H/4 H/2", "K/4 r/4 r/2"],
        ])
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [1], measuresLeftAsWritten: [0]))
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice) == .leftAsWritten(.tuplets))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures[0].voices == score.parts[0].staves[0].measures[0].voices)
        #expect(RevoiceFixtures.voices(after, measure: 1) == ["3:2[H+K/8 H/8 H/8] H/4 H/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// A triplet and a quintuplet over the same beat cannot merge member by member. Bar 1's two triplets can.
    @Test func `mismatched tuplets leave the bar as written`() throws {
        let score = RevoiceFixtures.score([
            ["3:2[H/8 H/8 H/8] H/4 H/2", "5:4[K/16 K/16 K/16 K/16 K/16] r/4 r/2"],
            ["3:2[H/8 H/8 H/8] H/4 H/2", "3:2[K/8 r/8 K/8] r/4 r/2"],
        ])
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [1], measuresLeftAsWritten: [0]))
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice) == .leftAsWritten(.tuplets))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures[0].voices == score.parts[0].staves[0].measures[0].voices)
        #expect(RevoiceFixtures.voices(after, measure: 1) == ["3:2[H+K/8 H/8 H+K/8] H/4 H/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The triplet holds only hi-hats, so voice 2 receives nothing from it and reads that beat as an ordinary rest.
    @Test func `a tuplet with nothing for a voice is a plain rest there`() throws {
        let score = RevoiceFixtures.score([["3:2[H/8 H/8 H/8] H+K/4 H/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["3:2[H/8 H/8 H/8] H/4 H/2", "r/4 K/4 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// Voice 2's next kick is the triplet's second member, but the triplet starts on the "and" of 1 with a rest for
    /// voice 2, so the kick on 1 stops there: an eighth, not the span up to that kick.
    @Test func `a chord before a tuplet stops at its edge`() throws {
        let score = RevoiceFixtures.score([["H+K/16 H/16 3:2[H/8 H+K/8 H/8] H/8 H/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0)
            == ["H/16 H/16 3:2[H/8 H/8 H/8] H/8 H/2", "K/8 3:2[r/8 K/8 r/8] r/8 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `a carried tuplet keeps how it is drawn`() throws {
        let drawn = TupletAppearance(numberType: .ratio, bracketType: .bracket)
        var score = RevoiceFixtures.score([["3:2[H+K/8 H/8 H+K/8] H/4 H/2"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0].tuplets.updateValue(at: 0) { $0.appearance = drawn }
            }
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        let appearances = after[RevoiceFixtures.staff]?.measures[0].voices.map { $0.tuplets.values.map(\.appearance) }
        #expect(appearances == [[drawn], [drawn]])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// Voice 2 already holds the kick on 1 at the triplet's value, with rests after it, but no tuplet. Its rewrite
    /// reads the same element by element and differs only in the tuplet it gains, so it must still be written.
    @Test func `a voice whose elements stay but which gains a tuplet is written`() throws {
        var score = RevoiceFixtures.score([["3:2[H+K/8 H/8 H/8] H/4 H/2", "3:2[K/8 r/8 r/8] r/4 r/2"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[1].tuplets = []
            }
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0)
            == ["3:2[H/8 H/8 H/8] H/4 H/2", "3:2[K/8 r/8 r/8] r/4 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The fixtures' text cannot nest a tuplet, so the inner one is added by hand over the triplet's first two
    /// members (elements 1 and 2; element 0 is the time signature). Their values stay as the outer triplet wrote
    /// them: nesting is read from the members a tuplet spans.
    @Test func `nested tuplets leave the bar as written`() {
        var score = RevoiceFixtures.score([["3:2[H+K/8 H/8 H/8] H/4 H/2"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                let voice = staff.measures[0].voices[0]
                let inner = Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 2)
                staff.measures[0].voices[0] = Voice(elements: voice.elements, tuplets: voice.tuplets.values + [inner])
            }
        }
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
        #expect(plan == .leftAsWritten(.unsupported))
    }
}
