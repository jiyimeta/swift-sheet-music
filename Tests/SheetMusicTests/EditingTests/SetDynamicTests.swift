@testable import SheetMusicCore
import Testing

@Suite("SetDynamic")
struct SetDynamicTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements
    }

    @Test("a dynamic is inserted right before its chord, with MuseScore's default velocity")
    func inserts() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4, D4, r, r]
        _ = try SetDynamic(at: Self.slot(0, 2), subtype: "ff").apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[2] == .dynamic(Dynamic(subtype: "ff", velocity: 112)))
        #expect(elements[3] == .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])))
        #expect(SetDynamic.current(at: Self.slot(0, 3), in: score)?.subtype == "ff")
    }

    @Test("a dynamic already before the chord is replaced in place, keeping its font overrides")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            .dynamic(Dynamic(subtype: "p", velocity: 49, properties: TextProperties(size: 14))), at: 1,
        )
        // [ts, dyn, C4, D4, r, r]
        _ = try SetDynamic(at: Self.slot(0, 2), subtype: "mf").apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[1] == .dynamic(Dynamic(subtype: "mf", velocity: 80, properties: TextProperties(size: 14))))
    }

    @Test("the dynamic is found past a fermata in the same run")
    func findsThroughTheRun() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            contentsOf: [.dynamic(Dynamic(subtype: "p", velocity: 49)), .fermata(Fermata(subtype: "fermataAbove"))],
            at: 1,
        )
        // [ts, dyn, fermata, C4, D4, r, r]
        _ = try SetDynamic(at: Self.slot(0, 3), subtype: nil).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[1] == .fermata(Fermata(subtype: "fermataAbove")))
    }

    @Test("nil removes the dynamic; the inverses restore the score exactly")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetDynamic(at: Self.slot(0, 1), subtype: "p").apply(to: &score)
        let written = score
        let clearInverse = try SetDynamic(at: Self.slot(0, 2), subtype: nil).apply(to: &score)
        #expect(score == before)
        _ = try clearInverse.apply(to: &score)
        #expect(score == written)
        _ = try writeInverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a rest, a non-timed element, a missing element and a clear with nothing to clear are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let rest = #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 3), subtype: "p").apply(to: &score)
        }
        #expect(Self.reason(of: rest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 0), subtype: "p").apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 9), subtype: "p").apply(to: &score)
        }
        let nothing = #expect(throws: SheetMusicError.self) {
            _ = try SetDynamic(at: Self.slot(0, 1), subtype: nil).apply(to: &score)
        }
        #expect(Self.reason(of: nothing) == .targetNotFound(Self.slot(0, 1)))
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
