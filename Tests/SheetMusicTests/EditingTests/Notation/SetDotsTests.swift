@testable import SheetMusicCore
import Testing

/// `SetDots` — spec row 55. The point of these is that the command DELEGATES: every rhythm expectation below is
/// `SetChordDuration` / `SetRestDuration`'s behavior, not arithmetic `SetDots` owns.
@Suite("SetDots")
struct SetDotsTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    private static func duration(_ element: VoiceElement?) -> NoteDuration? {
        guard case let .chord(chord)? = element else { return nil }
        return chord.duration
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements
    }

    @Test("one dot on the second quarter lengthens it and shortens what follows")
    func writes() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4 q, D4 q, r q, r q]
        _ = try SetDots(at: Self.slot(0, 2), dots: 1).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(Self.duration(elements[2]) == NoteDuration.quarter.dotted(1))
        // The dotted quarter ate half of the following quarter rest, which is an eighth now.
        #expect(Self.duration(elements[3]) == .eighth)
    }

    @Test("dots: 0 takes the dot back off")
    func clears() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 2)
        _ = try SetDots(at: target, dots: 1).apply(to: &score)
        _ = try SetDots(at: target, dots: 0).apply(to: &score)
        #expect(Self.duration(Self.elements(score, 0)[2]) == .quarter)
    }

    @Test("a rest routes through SetRestDuration")
    func dotsARest() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetDots(at: Self.slot(0, 3), dots: 1).apply(to: &score)
        #expect(Self.duration(Self.elements(score, 0)[3]) == NoteDuration.quarter.dotted(1))
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetDots(at: Self.slot(0, 2), dots: 1).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the siblings are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetDots(at: Self.slot(0, 2), dots: 1).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
        #expect(Self.elements(score, 0)[1] == Self.elements(before, 0)[1])
    }

    @Test("a measure rest, an irregular length and an out-of-range count are notDottable")
    func notDottable() {
        var score = EditingFixtures.parityFixture()
        let before = score
        // m3 is a single `.measure` rest.
        let measureRest = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(3, 0), dots: 1).apply(to: &score)
        }
        #expect(Self.reason(of: measureRest) == .notDottable(at: Self.slot(3, 0)))
        let tooMany = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(0, 2), dots: 4).apply(to: &score)
        }
        #expect(Self.reason(of: tooMany) == .notDottable(at: Self.slot(0, 2)))
        let negative = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(0, 2), dots: -1).apply(to: &score)
        }
        #expect(Self.reason(of: negative) == .notDottable(at: Self.slot(0, 2)))
        #expect(score == before)
    }

    /// A real tuplet member never reaches the delegation at all: `CreateTuplet` stores every member as
    /// `.fraction(original / actualNotes)`, and a triplet member's 1/12 decomposes into no (base, dots) pair. So
    /// `.notDottable` is the answer for the whole tuplet case in practice — which is what this command's doc
    /// comment claims and `insideTupletIsInherited` (below) cannot show.
    @Test("a tuplet-scaled member is notDottable, before any delegation happens")
    func tupletMemberIsNotDottable() throws {
        var score = EditingFixtures.parityFixture()
        _ = try CreateTuplet(at: Self.slot(1, 0), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let refusal = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(1, 1), dots: 1).apply(to: &score)
        }
        #expect(Self.reason(of: refusal) == .notDottable(at: Self.slot(1, 1)))
    }

    /// `SetDots` adds NO tuplet check of its own — the refusal is `SetRestDuration`'s, raised under that
    /// operation name. Reaching it needs a member inside a tuplet span whose duration still has a dotted
    /// spelling, which `CreateTuplet` alone cannot produce (see above), so the member is re-spelled as the
    /// value-equal enum case first.
    @Test("a member inside a tuplet span inherits SetRestDuration's refusal, not a new one")
    func insideTupletIsInherited() throws {
        var score = EditingFixtures.parityFixture()
        // A 2:3 duplet over the bar's first quarter rest: members span element indices 0...1.
        _ = try CreateTuplet(at: Self.slot(1, 0), actualNotes: 2, normalNotes: 3).apply(to: &score)
        score[Self.slot(1, 1)] = .rest(duration: .eighth)
        let refusal = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(1, 1), dots: 1).apply(to: &score)
        }
        #expect(Self.reason(of: refusal) == .insideTuplet(at: Self.slot(1, 1)))
    }

    @Test("a missing element and a non-timed element are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(0, 9), dots: 1).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        // Element 0 of m0 is the time signature.
        let untimed = #expect(throws: SheetMusicError.self) {
            _ = try SetDots(at: Self.slot(0, 0), dots: 1).apply(to: &score)
        }
        #expect(Self.reason(of: untimed) == .wrongElementKind(at: Self.slot(0, 0), expected: .chordOrRest))
        #expect(score == before)
    }
}
