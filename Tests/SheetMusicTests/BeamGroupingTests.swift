@testable import SheetMusicCore
import Testing

@Suite("BeamGrouping")
struct BeamGroupingTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("two adjacent eighths in 4/4 are one group of level 1 — BeamingTests.twoEighths, through the moved rule")
    func twoEighths() {
        let c = Chord(duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4)), .chord(c), .chord(c)])
        let groups = BeamGrouping.groups(
            voice: voice, timeSignature: TimeSignature(numerator: 4, denominator: 4), division: 480,
        )
        #expect(groups == [BeamGroup(memberIndices: [1, 2], level: 1)])
    }

    @Test("the explicit time signature is the bar's own element, in any voice, or nil")
    func explicitTimeSignature() {
        let measure = Measure(voices: [
            Voice(elements: [.rest(duration: .measure)]),
            Voice(elements: [.timeSignature(TimeSignature(numerator: 6, denominator: 8)), .rest(duration: .measure)]),
        ])
        #expect(BeamGrouping.explicitTimeSignature(in: measure) == TimeSignature(numerator: 6, denominator: 8))
        #expect(BeamGrouping.explicitTimeSignature(in: Measure(voices: [Voice(elements: [])])) == nil)
    }

    @Test("the leader of a follower is the group's first chord; an unbeamed slot has none")
    func leader() {
        let score = EditingFixtures.twoBeamedEighths() // [ts, C4 e, D4 e, r q, r h]
        #expect(BeamGrouping.leader(of: Self.slot(2), in: score) == Self.slot(1))
        #expect(BeamGrouping.leader(of: Self.slot(1), in: score) == Self.slot(1))
        #expect(BeamGrouping.leader(of: Self.slot(3), in: score) == nil) // a rest
        #expect(BeamGrouping.leader(of: Self.slot(0), in: score) == nil) // the meter
        #expect(BeamGrouping.leader(of: Self.slot(9), in: score) == nil)
        #expect(BeamGrouping.leader(of: Self.slot(1), in: EditingFixtures.chordAtIndex1()) == nil) // a lone quarter
    }
}
