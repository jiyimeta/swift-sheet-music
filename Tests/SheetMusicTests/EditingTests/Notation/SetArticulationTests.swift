@testable import SheetMusicCore
import Testing

/// `SetArticulation` — the toggle spec row 50 names, on the chord's own `articulations` array.
@Suite("SetArticulation")
struct SetArticulationTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func articulations(_ score: Score, _ id: VoiceElementID) -> [ChordArticulation] {
        guard case let .chord(chord)? = score[id] else { return [] }
        return chord.articulations
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("a write appends the mark to the chord")
    func writes() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetArticulation(at: Self.slot(0, 1), kind: .staccato, anchor: .above, present: true)
            .apply(to: &score)
        #expect(Self.articulations(score, Self.slot(0, 1))
            == [ChordArticulation(kind: .staccato, anchor: .above)])
    }

    @Test("undo restores the chord exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try SetArticulation(at: Self.slot(0, 1), kind: .tenuto, anchor: nil, present: true)
            .apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("present == false removes every entry of that kind and leaves the others standing")
    func clears() throws {
        var score = EditingFixtures.parityFixture()
        var chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        chord.articulations = [
            ChordArticulation(kind: .staccato, anchor: .above),
            ChordArticulation(kind: .tenuto),
            ChordArticulation(kind: .staccato, anchor: .below),
        ]
        score[Self.slot(0, 1)] = .chord(chord)
        _ = try SetArticulation(at: Self.slot(0, 1), kind: .staccato, anchor: nil, present: false)
            .apply(to: &score)
        #expect(Self.articulations(score, Self.slot(0, 1)) == [ChordArticulation(kind: .tenuto)])
    }

    @Test("re-writing a kind moves it rather than doubling it, and keeps the other kinds")
    func rewriteMoves() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        _ = try SetArticulation(at: target, kind: .tenuto, anchor: .above, present: true).apply(to: &score)
        _ = try SetArticulation(at: target, kind: .staccato, anchor: .above, present: true).apply(to: &score)
        _ = try SetArticulation(at: target, kind: .staccato, anchor: .below, present: true).apply(to: &score)
        #expect(Self.articulations(score, target) == [
            ChordArticulation(kind: .tenuto, anchor: .above),
            ChordArticulation(kind: .staccato, anchor: .below),
        ])
    }

    @Test("an unknown kind toggles exactly its own string")
    func unknownKind() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        let soft = ChordArticulation.Kind.unknown(subtype: "articSoftAccentAbove")
        _ = try SetArticulation(at: target, kind: soft, anchor: nil, present: true).apply(to: &score)
        _ = try SetArticulation(at: target, kind: .staccato, anchor: nil, present: false).apply(to: &score)
        #expect(Self.articulations(score, target) == [ChordArticulation(kind: soft)])
    }

    @Test("the other notes, the other bars and the other staff are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        _ = try SetArticulation(at: Self.slot(0, 1), kind: .accent, anchor: nil, present: true).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
        #expect(Self.articulations(score, Self.slot(0, 2)).isEmpty)
    }

    @Test("a rest, a non-chord element and a missing element are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetArticulation(at: Self.slot(0, 3), kind: .staccato, anchor: nil, present: true)
                .apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        let onMeter = #expect(throws: SheetMusicError.self) {
            _ = try SetArticulation(at: Self.slot(0, 0), kind: .staccato, anchor: nil, present: true)
                .apply(to: &score)
        }
        #expect(Self.reason(of: onMeter) == .wrongElementKind(at: Self.slot(0, 0), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetArticulation(at: Self.slot(0, 9), kind: .staccato, anchor: nil, present: true)
                .apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(score == before)
    }
}
