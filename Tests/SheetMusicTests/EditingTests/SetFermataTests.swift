@testable import SheetMusicCore
import Testing

@Suite("SetFermata")
struct SetFermataTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements
    }

    @Test("a fermata is inserted before its chord and resolves to it as a hold")
    func insertsAndHolds() throws {
        var score = EditingFixtures.parityFixture() // m2: [E4 h, E4 h]
        _ = try SetFermata(at: Self.slot(2, 1), subtype: "fermataLongAbove", timeStretch: 2).apply(to: &score)
        let elements = Self.elements(score, 2)
        #expect(elements.count == 3)
        #expect(elements[1] == .fermata(Fermata(subtype: "fermataLongAbove", timeStretch: 2)))
        #expect(score.fermataHolds() == [
            FermataHold(measureIndex: 2, startTickInMeasure: 960, ticks: 960, stretch: 2),
        ])
        #expect(SetFermata.current(at: Self.slot(2, 2), in: score)?.subtype == "fermataLongAbove")
    }

    @Test("a rest takes a fermata too")
    func onARest() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetFermata(at: Self.slot(3, 0), subtype: "fermataAbove", timeStretch: 1.5).apply(to: &score)
        #expect(Self.elements(score, 3) == [
            .fermata(Fermata(subtype: "fermataAbove", timeStretch: 1.5)), .rest(duration: .measure),
        ])
    }

    @Test("a fermata already there is replaced in place, keeping its visibility")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        var hidden = Fermata(subtype: "fermataAbove")
        hidden.visible = false
        score.parts[0].staves[0].measures[2].voices[0].elements.insert(.fermata(hidden), at: 0)
        _ = try SetFermata(at: Self.slot(2, 1), subtype: "fermataShortAbove", timeStretch: 1.25).apply(to: &score)
        guard case let .fermata(fermata) = Self.elements(score, 2)[0] else {
            Issue.record("expected a fermata")
            return
        }
        #expect(fermata.subtype == "fermataShortAbove")
        #expect(fermata.timeStretch == 1.25)
        #expect(fermata.visible == false)
        #expect(Self.elements(score, 2).count == 3)
    }

    @Test("nil removes; the inverses restore the score exactly")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetFermata(at: Self.slot(2, 0), subtype: "fermataAbove", timeStretch: 1.5)
            .apply(to: &score)
        let written = score
        let clearInverse = try SetFermata(at: Self.slot(2, 1), subtype: nil, timeStretch: 1).apply(to: &score)
        #expect(score == before)
        _ = try clearInverse.apply(to: &score)
        #expect(score == written)
        _ = try writeInverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a non-timed element, a missing element and a clear with nothing to clear are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let untimed = #expect(throws: SheetMusicError.self) {
            _ = try SetFermata(at: Self.slot(0, 0), subtype: "fermataAbove", timeStretch: 1.5).apply(to: &score)
        }
        #expect(Self.reason(of: untimed) == .wrongElementKind(at: Self.slot(0, 0), expected: .chordOrRest))
        #expect(throws: SheetMusicError.self) {
            _ = try SetFermata(at: Self.slot(5, 0), subtype: "fermataAbove", timeStretch: 1.5).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetFermata(at: Self.slot(2, 0), subtype: nil, timeStretch: 1).apply(to: &score)
        }
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
