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

    /// A stream element that is not a chord or rest, and the tick it stands at.
    private struct Annotation {
        let tick: Int
        let element: VoiceElement
    }

    /// Every element of `voice` that is not a chord or rest, with the tick it stands at in a 4/4 bar.
    private static func annotations(of voice: Voice?) -> [Annotation] {
        let bar = Fraction(numerator: 1, denominator: 1)
        var tick = 0
        var found: [Annotation] = []
        for element in voice?.elements.values ?? [] {
            defer { tick += element.cursorAdvance(division: RevoiceFixtures.division, in: bar) }
            if case .chord = element { continue }
            found.append(Annotation(tick: tick, element: element))
        }
        return found
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

    /// Seven sixteenths in the time of four are 68 4/7 ticks each at 480 per quarter, so the group reads as 476 ticks
    /// rather than its quarter; carried member by member it would leave its voice off by the difference. Bar 1 still
    /// converts.
    @Test func `a septuplet that does not fill whole ticks leaves the bar as written`() throws {
        let score = RevoiceFixtures.score([
            ["7:4[H/16 H/16 H/16 H/16 H/16 H/16 H/16] H/4 H/2", "K/4 r/4 r/2"], ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"],
        ])
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [1], measuresLeftAsWritten: [0]))
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice) == .leftAsWritten(.tuplets))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures[0].voices == score.parts[0].staves[0].measures[0].voices)
        #expect(RevoiceFixtures.voices(after, measure: 1) == ["H+K/4 H/4 H/4 H/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The crash on 1 is tied to the one on beat 2, so it lasts a quarter, but it lands on the triplet's first member,
    /// a third of that: inside the triplet it can neither keep its length nor take the member's.
    @Test func `a tied hit that outlasts its triplet member leaves the bar as written`() {
        let score = RevoiceFixtures.score([["3:2[H/8 H/8 H/8] H/4 H/2", "C/4~ ~C/4 r/2"]])
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
        #expect(plan == .leftAsWritten(.audibleLength))
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [], measuresLeftAsWritten: [0]))
    }

    /// The triplet holds only hi-hats, so voice 2 receives nothing from it and reads that beat as an ordinary rest.
    @Test func `a tuplet with nothing for a voice is a plain rest there`() throws {
        let score = RevoiceFixtures.score([["3:2[H/8 H/8 H/8] H+K/4 H/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["3:2[H/8 H/8 H/8] H/4 H/2", "r/4 K/4 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The snare on 1 lands on the triplet's first member and joins it in voice 1. The kick on the "and" of 1 falls
    /// between members, but no hit of the triplet goes to voice 2, so there the beat is ordinary time and the kick a
    /// plain eighth beside voice 1's triplet.
    @Test func `a kick off the triplet's grid in the other voice stays a plain eighth`() throws {
        let score = RevoiceFixtures.score([["3:2[H/8 H/8 H/8] H/4 H/2", "S/8 K/8 r/4 r/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["3:2[H+S/8 H/8 H/8] H/4 H/2", "r/8 K/8 r/4 r/2"])
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

    /// A side a one-voice file forced would put voice 2's bracket above the staff, into voice 1, so as with stems
    /// (D3) the voice decides; the rest of how the tuplet is drawn travels.
    @Test func `a carried tuplet's direction is left to its voice`() throws {
        let forced = TupletAppearance(direction: .up, numberType: .ratio)
        var score = RevoiceFixtures.score([["3:2[H+K/8 H/8 H+K/8] H/4 H/2"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0].tuplets.updateValue(at: 0) { $0.appearance = forced }
            }
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        let appearances = after[RevoiceFixtures.staff]?.measures[0].voices.map { $0.tuplets.values.map(\.appearance) }
        let unforced = TupletAppearance(numberType: .ratio)
        #expect(appearances == [[unforced], [unforced]])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// A dynamic before the triplet and a sticking on its second member stay in voice 1 at their ticks. The tuplet
    /// spans its three members and the sticking between them, not the dynamic before them.
    @Test func `annotations beside and inside a carried tuplet keep their ticks`() throws {
        let meter = TimeSignature(numerator: 4, denominator: 4)
        let dynamic = Dynamic(subtype: "p", velocity: 49)
        let sticking = Sticking(text: "R")
        var score = RevoiceFixtures.score([["3:2[H+K/8 H/8 H+K/8] H/4 H/2"]], meter: meter)
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                // [meter, H+K, H, H+K, H/4, H/2] becomes [meter, dynamic, H+K, sticking, H, H+K, H/4, H/2].
                var elements = staff.measures[0].voices[0].elements.values
                elements.insert(.sticking(sticking), at: 2)
                elements.insert(.dynamic(dynamic), at: 1)
                let tuplets: [Tuplet] = [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 5)]
                staff.measures[0].voices[0] = Voice(elements: elements, tuplets: tuplets)
            }
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0)
            == ["3:2[H/8 H/8 H/8] H/4 H/2", "3:2[K/8 r/8 K/8] r/4 r/2"])
        let voices = after[RevoiceFixtures.staff]?.measures[0].voices ?? []
        let annotations = Self.annotations(of: voices.first)
        #expect(annotations.map(\.tick) == [0, 0, 160])
        #expect(annotations.map(\.element) == [.timeSignature(meter), .dynamic(dynamic), .sticking(sticking)])
        #expect(Self.annotations(of: voices.last).isEmpty)
        #expect(voices.first?.tupletSpans == [TupletSpan(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 5)])
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
