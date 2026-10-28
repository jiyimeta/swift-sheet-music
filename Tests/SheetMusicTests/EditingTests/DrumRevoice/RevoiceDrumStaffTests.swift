@testable import SheetMusicCore
import Testing

/// The command's skeleton, the target-form check and the bar writer (design 2026-10-26, drum voice conversion,
/// §4.1–§4.3, §4.6): a bar already in the target form is not touched, a rest-only voice beyond the target's count is
/// removed and nothing else changes, a measure repeat is left alone, every other bar is written afresh from its hits,
/// and the whole conversion undoes in one step.
@Suite("RevoiceDrumStaff")
struct RevoiceDrumStaffTests {
    private static func reason(_ body: () throws -> some Any) -> EditRefusal.Reason? {
        do {
            _ = try body()
            return nil
        } catch let SheetMusicError.invalidEdit(refusal) {
            return refusal.reason
        } catch {
            return nil
        }
    }

    /// Every identifier on the drum staff in stream order: each element's, each note's and each tuplet's.
    private static func identifiers(_ score: Score) -> [EID] {
        let measures = score[RevoiceFixtures.staff]?.measures ?? []
        return measures.flatMap(\.voices).flatMap { voice -> [EID] in
            let elements = voice.elements.indices.flatMap { index -> [EID] in
                let own = voice.elements.eid(at: index)
                guard case let .chord(chord) = voice.elements[index] else { return [own] }
                return [own] + chord.notes.indices.map { chord.notes.eid(at: $0) }
            }
            return elements + voice.tuplets.indices.map { voice.tuplets.eid(at: $0) }
        }
    }

    @Test func `a bar already in the target form plans to nothing`() throws {
        let score = RevoiceFixtures.score([["H/8 H/8 H+S/8 H/8 H/8 H/8 H+S/8 H/8", "K/4 r/4 K/8 K/8 r/4"]])
        #expect(try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet).plan == nil)
    }

    @Test func `a rest-only second voice goes under one voice and nothing else changes`() throws {
        let score = RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4", "r/m"]])
        let (after, plan) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(plan != nil)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H+K/4 H/4 H+S/4 H/4"])
        let before = score.parts[0].staves[0].measures[0].voices[0]
        #expect(after.parts[0].staves[0].measures[0].voices[0].elements.values == before.elements.values)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `a rest-only second voice stays under hands and feet`() throws {
        let score = RevoiceFixtures.score([["H/4 H/4 H+S/4 H/4", "r/m"]])
        #expect(try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet).plan == nil)
    }

    /// Bar 1's rest-only voice 2 would be removed under one voice, as bar 0's is, if the measure repeat did not keep
    /// the bar out of the conversion altogether.
    @Test func `a measure-repeat bar is untouched`() throws {
        var score = RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4", "r/m"], ["r/m", "r/m"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[1].voices[0] = Voice(elements: [
                    .measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure)),
                ])
                staff.measures[1].measureRepeatCount = 1
            }
        }
        let (after, plan) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(plan != nil)
        #expect(after.parts[0].staves[0].measures[0].voices.count == 1)
        #expect(after.parts[0].staves[0].measures[1].voices == score.parts[0].staves[0].measures[1].voices)
    }

    /// A hidden rest carries no marking, so its voice goes; a rest carrying an articulation would lose it with the
    /// voice, so that bar is left as written — and the preview says which is which.
    @Test func `a rest carrying a marking keeps its voice and a hidden rest does not`() throws {
        var score = RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4", "r/m"], ["H/4 H/4 H+S/4 H/4", "r/m"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[1].elements.updateValue(at: 0) { slot in
                    guard case var .chord(rest) = slot else { return }
                    rest.visible = false
                    slot = .chord(rest)
                }
                staff.measures[1].voices[1].elements.updateValue(at: 0) { slot in
                    guard case var .chord(rest) = slot else { return }
                    rest.articulations = [ChordArticulation(kind: .tenuto)]
                    slot = .chord(rest)
                }
            }
        }
        let command = RevoiceDrumStaff(
            staff: RevoiceFixtures.staff, voiceForPitch: RevoiceFixtures.oneVoice, policy: .default,
        )
        #expect(command.preview(in: score) == RevoicePreview(rewrittenMeasures: [0], measuresLeftAsWritten: [1]))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures.map(\.voices.count) == [1, 2])
    }

    @Test func `an out-of-range voice index is refused`() {
        var score = RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4", "r/m"]])
        let command = RevoiceDrumStaff(staff: RevoiceFixtures.staff, voiceForPitch: [36: 4], policy: .default)
        let refusal = Self.reason { try command.apply(to: &score) }
        #expect(refusal == .unexpected(description: "voice index out of range"))
    }

    @Test func `undo of the plan restores the score exactly`() throws {
        var score = RevoiceFixtures.score([
            ["H+K/4 H/4 H+S/4 H/4", "r/m"], ["H/2 H+S/2", "r/2 r/2", "r/m"], ["H+K/1"],
        ])
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        let original = score
        let command = RevoiceDrumStaff(
            staff: RevoiceFixtures.staff, voiceForPitch: RevoiceFixtures.oneVoice, policy: .default,
        )
        let plan = try #require(try command.plan(in: score, ids: ids))
        let inverse = try plan.apply(to: &score, ids: &ids)
        #expect(score.parts[0].staves[0].measures.map(\.voices.count) == [1, 1, 1])
        _ = try inverse.apply(to: &score, ids: &ids)
        #expect(score == original)
    }

    // MARK: Writing a bar from its hits (§4.1–§4.3)

    @Test func `case 1 — one voice to hands and feet`() throws {
        let score = RevoiceFixtures.score([["H+K/8 H/8 H+S/8 H/8 H+K/8 H+K/8 H+S/8 H/8"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0)
            == ["H/8 H/8 H+S/8 H/8 H/8 H/8 H+S/8 H/8", "K/4 r/4 K/8 K/8 r/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// Once its kick has gone, the hi-hat on 1 reaches the next onset of its voice, beat 2.
    @Test func `case 2 — a lone kick on the and of 1`() throws {
        let score = RevoiceFixtures.score([["H+K/8 K/8 H+S/4 H+K/4 H+S/4"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 H+S/4 H/4 H+S/4", "K/8 K/8 r/4 K/4 r/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The quarter kick on beat 1 is cut back to an eighth by the hi-hat on the "and".
    @Test func `case 3 — case 1's result back to one voice`() throws {
        let score = RevoiceFixtures.score([["H/8 H/8 H+S/8 H/8 H/8 H/8 H+S/8 H/8", "K/4 r/4 K/8 K/8 r/4"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H+K/8 H/8 H+S/8 H/8 H+K/8 H+K/8 H+S/8 H/8"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `case 4 — hands and feet to one voice`() throws {
        let score = RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "K/8 K/8 r/4 r/2"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H+K/8 K/8 H/4 H/4 H/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `case 5 — a converted staff converts to nothing`() throws {
        let score = RevoiceFixtures.score([["H+K/8 H/8 H+S/8 H/8 H+K/8 H+K/8 H+S/8 H/8"]])
        let once = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet).score
        #expect(once.parts[0].staves[0].measures[0].voices.count == 2)
        let (twice, plan) = try RevoiceFixtures.converted(once, to: RevoiceFixtures.handsAndFeet)
        #expect(plan == nil)
        #expect(twice == once)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: twice, staff: RevoiceFixtures.staff)
    }

    @Test func `spelling differences in the source give the same result`() throws {
        let quarter = RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]])
        let eighthAndRest = RevoiceFixtures.score([["H+K/8 r/8 H/4 H/4 H/4"]])
        let fromQuarter = try RevoiceFixtures.converted(quarter, to: RevoiceFixtures.handsAndFeet).score
        let fromEighth = try RevoiceFixtures.converted(eighthAndRest, to: RevoiceFixtures.handsAndFeet).score
        #expect(RevoiceFixtures.voices(fromQuarter, measure: 0) == ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.voices(fromEighth, measure: 0) == RevoiceFixtures.voices(fromQuarter, measure: 0))
        try RevoiceSoundGate.expectKeepsSound(before: quarter, after: fromQuarter, staff: RevoiceFixtures.staff)
        try RevoiceSoundGate.expectKeepsSound(before: eighthAndRest, after: fromEighth, staff: RevoiceFixtures.staff)
    }

    @Test func `three voices merge into one and split again`() throws {
        let score = RevoiceFixtures.score([
            ["H/8 H/8 H/8 H/8 H/8 H/8 H/8 H/8", "K/4 r/4 K/4 r/4", "r/4 S/4 r/4 S/4"],
        ])
        let merged = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice).score
        #expect(RevoiceFixtures.voices(merged, measure: 0) == ["H+K/8 H/8 H+S/8 H/8 H+K/8 H/8 H+S/8 H/8"])
        #expect(merged.parts[0].staves[0].measures[0].voices.count == 1)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: merged, staff: RevoiceFixtures.staff)
        let split = try RevoiceFixtures.converted(merged, to: RevoiceFixtures.handsAndFeet).score
        #expect(RevoiceFixtures.voices(split, measure: 0)
            == ["H/8 H/8 H+S/8 H/8 H/8 H/8 H+S/8 H/8", "K/4 r/4 K/4 r/4"])
        try RevoiceSoundGate.expectKeepsSound(before: merged, after: split, staff: RevoiceFixtures.staff)
    }

    @Test func `a voice below the highest one used is written as rests`() throws {
        let score = RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: [36: 2])
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 H/4 H/4 H/4", "r/m", "K/4 r/4 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// The half-note hit outlasts the beat after it, so the chord keeps its half; read to the next beat only, both
    /// parts would become `H/4 r/4 H/4 H/4` and `K/4 r/4 r/2`.
    @Test func `a hit longer than the next beat keeps its length`() throws {
        let score = RevoiceFixtures.score([["H+K/2 H/4 H/4"]])
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/2 H/4 H/4", "K/2 r/2"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// Both voices sound the snare on 1, each with its own notehead; one voice holds one snare there, the first
    /// voice's. The gate's model check sees the second voice's snare go — that is the merge — and nothing else: what
    /// plays is the same.
    @Test func `two hits of one pitch at one onset keep the lower voice's note`() throws {
        var score = RevoiceFixtures.score([["S/4 H/4 H/4 H/4", "S/4 r/4 r/2"]])
        score = RevoiceFixtures.editingChord(score, measure: 0, voice: 0, element: 1) { chord in
            chord.notes.updateNote(at: 0) { $0.headType = "cross" }
        }
        score = RevoiceFixtures.editingChord(score, measure: 0, voice: 1, element: 0) { chord in
            chord.notes.updateNote(at: 0) { $0.headType = "diamond" }
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["S/4 H/4 H/4 H/4"])
        let merged = try #require(after[RevoiceFixtures.staff]?.measures[0].voices[0].elements[1])
        guard case let .chord(snare) = merged else {
            Issue.record("element 1 is no chord: \(merged)")
            return
        }
        #expect(snare.notes.map(\.headType) == ["cross"])
        let problems = try RevoiceSoundGate.problems(before: score, after: after, staff: RevoiceFixtures.staff)
        #expect(problems.count == 1)
        #expect(problems.allSatisfy { $0.hasPrefix("hit lost: bar 0 tick 0 pitch 38") && $0.contains("diamond") })
    }

    @Test func `a location shift leaves the bar as written`() {
        var score = RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[1] = RevoiceFixtures.voice(
                    "K/4 r/2", leading: [.locationShift(delta: Fraction(numerator: 1, denominator: 4))],
                )
            }
        }
        let plan = RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
        #expect(plan == .leftAsWritten(.unsupported))
    }

    /// The snare sits in the second voice but this kit names it in the first, and no foot hit is left for the second:
    /// the rewrite writes one voice and removes the other, though the kit's form has two.
    @Test func `a voice below the target count goes when nothing lands in it`() throws {
        let kit = [35: 1, 36: 1, 44: 1, 38: 0]
        let score = RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "S/4 r/4 S/4 r/4"]])
        let (after, plan) = try RevoiceFixtures.converted(score, to: kit)
        #expect(plan != nil)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H+S/4 H/4 H+S/4 H/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `a bar with no foot hit gets no voice 2`() throws {
        let score = RevoiceFixtures.score([["H/8 H/8 H+S/8 H/8 H/8 H/8 H+S/8 H/8"]])
        let (after, plan) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(plan == nil)
        #expect(after.parts[0].staves[0].measures[0].voices.count == 1)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    @Test func `six-eight extends to the dotted-quarter beat`() throws {
        let score = RevoiceFixtures.score(
            [["H+K/8 H/8 H/8 H+K/8 H/8 H/8"]], meter: TimeSignature(numerator: 6, denominator: 8),
        )
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/8 H/8 H/8 H/8 H/8 H/8", "K/4. K/4."])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// A pickup a whole beat long reads its beats the same from either end of the bar, so a second pickup, a beat
    /// and a half long, tells the two apart: its kick on the notional "and" of 3 reaches only beat 4, an eighth away,
    /// where read from the pickup's own start it would reach a quarter.
    @Test func `a pickup bar reads its beats from the notional bar`() throws {
        let beat = RevoiceFixtures.score([["H+K/8 H/8"]], pickupTicks: 480)
        let fromBeat = try RevoiceFixtures.converted(beat, to: RevoiceFixtures.handsAndFeet).score
        #expect(RevoiceFixtures.voices(fromBeat, measure: 0) == ["H/8 H/8", "K/4"])
        try RevoiceSoundGate.expectKeepsSound(before: beat, after: fromBeat, staff: RevoiceFixtures.staff)
        let beatAndAHalf = RevoiceFixtures.score([["H+K/8 H/8 H/8"]], pickupTicks: 720)
        let fromBeatAndAHalf = try RevoiceFixtures.converted(beatAndAHalf, to: RevoiceFixtures.handsAndFeet).score
        #expect(RevoiceFixtures.voices(fromBeatAndAHalf, measure: 0) == ["H/8 H/8 H/8", "K/8 r/4"])
        try RevoiceSoundGate.expectKeepsSound(
            before: beatAndAHalf, after: fromBeatAndAHalf, staff: RevoiceFixtures.staff,
        )
    }

    @Test func `apply then inverse restores the score and its identifiers`() throws {
        var score = RevoiceFixtures.score([["H+K/8 H/8 H+S/8 H/8 H+K/8 H+K/8 H+S/8 H/8"]])
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        let original = score
        let command = RevoiceDrumStaff(
            staff: RevoiceFixtures.staff, voiceForPitch: RevoiceFixtures.handsAndFeet, policy: .default,
        )
        let plan = try #require(try command.plan(in: score, ids: ids))
        let inverse = try plan.apply(to: &score, ids: &ids)
        #expect(score.parts[0].staves[0].measures[0].voices.count == 2)
        try RevoiceSoundGate.expectKeepsSound(before: original, after: score, staff: RevoiceFixtures.staff)
        // D8: the hi-hat on the "and" of 1 stays whole in its own voice and keeps its identifier; the hi-hat on 1
        // lost its kick, so it is a new chord. Element 0 is the time signature.
        let before = original.parts[0].staves[0].measures[0].voices[0].elements
        let converted = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(converted.eid(at: 2) == before.eid(at: 2))
        #expect(converted.eid(at: 1) != before.eid(at: 1))
        _ = try inverse.apply(to: &score, ids: &ids)
        #expect(score == original)
        #expect(Self.identifiers(score) == Self.identifiers(original))
    }
}
