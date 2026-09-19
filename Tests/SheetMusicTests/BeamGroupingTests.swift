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

    /// One member of a triplet that fills a quarter: a third of a quarter, which is how `CreateTuplet` writes it
    /// (`original / actualNotes`, stored as a fraction).
    private let tripletEighth = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))

    private func chord(_ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: 60, tpc: 14)]))
    }

    @Test("a beam does not cross a tuplet boundary: two quarter-length triplets stay two groups")
    func tupletsDoNotMerge() {
        let voice = Voice(
            elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(tripletEighth), chord(tripletEighth), chord(tripletEighth),
                chord(tripletEighth), chord(tripletEighth), chord(tripletEighth),
                .rest(duration: .half),
            ],
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3),
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 4, endIndex: 6),
            ],
        )
        let groups = BeamGrouping.groups(
            voice: voice, timeSignature: TimeSignature(numerator: 4, denominator: 4), division: 480,
        )
        #expect(groups == [
            BeamGroup(memberIndices: [1, 2, 3], level: 1),
            BeamGroup(memberIndices: [4, 5, 6], level: 1),
        ])
    }

    @Test("a tuplet does not beam together with the plain eighths beside it")
    func tupletDoesNotMergeWithPlainEighths() {
        let voice = Voice(
            elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(tripletEighth), chord(tripletEighth), chord(tripletEighth),
                chord(.eighth), chord(.eighth),
                .rest(duration: .half),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
        )
        let groups = BeamGrouping.groups(
            voice: voice, timeSignature: TimeSignature(numerator: 4, denominator: 4), division: 480,
        )
        #expect(groups == [
            BeamGroup(memberIndices: [1, 2, 3], level: 1),
            BeamGroup(memberIndices: [4, 5], level: 1),
        ])
    }

    /// The mirror of the test above, and the only one that holds the break at a tuplet's FIRST member: with the
    /// eighths first, the group running into the tuplet is the one that has to stop. Measured — with that break
    /// alone disabled, the two tests above stay green (each tuplet's other end closes their groups) and this one
    /// goes red.
    @Test("plain eighths do not beam into the tuplet that follows them")
    func plainEighthsDoNotMergeIntoTuplet() {
        let voice = Voice(
            elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(.eighth), chord(.eighth),
                chord(tripletEighth), chord(tripletEighth), chord(tripletEighth),
                .rest(duration: .half),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 3, endIndex: 5)],
        )
        let groups = BeamGrouping.groups(
            voice: voice, timeSignature: TimeSignature(numerator: 4, denominator: 4), division: 480,
        )
        #expect(groups == [
            BeamGroup(memberIndices: [1, 2], level: 1),
            BeamGroup(memberIndices: [3, 4, 5], level: 1),
        ])
    }
}
