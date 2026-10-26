@testable import SheetMusicCore
import Testing

/// The command's skeleton and the target-form check (design 2026-10-26, drum voice conversion, §4.6): a bar
/// already in the target form is not touched, a rest-only voice beyond the target's count is removed and nothing
/// else changes, a measure repeat is left alone, and the whole conversion undoes in one step.
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
}
