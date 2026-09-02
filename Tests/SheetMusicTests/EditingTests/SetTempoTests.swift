@testable import SheetMusicCore
import Testing

@Suite("SetTempo")
struct SetTempoTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static let allegro = SetTempo.Marking(beatsPerSecond: 2.5)
    private static let compound = SetTempo.Marking(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1)

    private static func tempos(_ score: Score, _ measure: Int) -> [(MeasurePosition, Tempo)] {
        score.systemMeasures[measure].elements.compactMap { positioned in
            if case let .tempo(tempo) = positioned.element { (positioned.position, tempo) } else { nil }
        }
    }

    @Test("the lane position of a chord is its onset as a fraction of a whole note")
    func lanePosition() {
        let score = EditingFixtures.parityFixture()
        let halfway = MeasurePosition(numerator: 1, denominator: 2)
        #expect(SystemLaneSlot.position(of: Self.slot(0, 1), in: score) == .start)
        #expect(SystemLaneSlot.position(of: Self.slot(0, 3), in: score) == halfway)
        #expect(SystemLaneSlot.position(of: Self.slot(0, 0), in: score) == nil) // the time signature
        #expect(SystemLaneSlot.position(of: Self.slot(9, 0), in: score) == nil)
    }

    @Test("writing into an empty lane pads it and places the tempo at the anchor's beat")
    func writesAndPads() throws {
        var score = EditingFixtures.parityFixture()
        #expect(score.systemMeasures.isEmpty)
        _ = try SetTempo(anchor: Self.slot(0, 3), marking: Self.allegro).apply(to: &score)
        #expect(score.systemMeasures.count == 4)
        let written = Self.tempos(score, 0)
        #expect(written.count == 1)
        #expect(written.first?.0 == MeasurePosition(numerator: 1, denominator: 2))
        #expect(written.first?.1.beatsPerSecond == 2.5)
        #expect(score.systemMeasures[0].elements.first?.originalStaff == nil)
        #expect(SetTempo.current(at: Self.slot(0, 3), in: score) == Self.allegro)
    }

    @Test("a second write at the same beat replaces in place, keeping the mark's offsets")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetTempo(anchor: Self.slot(0, 1), marking: Self.allegro).apply(to: &score)
        score.systemMeasures[0].elements[0].element = .tempo(Tempo(beatsPerSecond: 2.5, offsetX: 3))
        _ = try SetTempo(anchor: Self.slot(0, 1), marking: Self.compound).apply(to: &score)
        let written = Self.tempos(score, 0)
        #expect(written.count == 1)
        #expect(written.first?.1.beatDots == 1)
        #expect(written.first?.1.offsetX == 3)
    }

    @Test("nil removes the tempo, and both inverses restore the lane exactly")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetTempo(anchor: Self.slot(1, 0), marking: Self.allegro).apply(to: &score)
        let written = score
        let clearInverse = try SetTempo(anchor: Self.slot(1, 0), marking: nil).apply(to: &score)
        #expect(Self.tempos(score, 1).isEmpty)
        #expect(score.systemMeasures.count == 4)
        _ = try clearInverse.apply(to: &score)
        #expect(score == written)
        _ = try writeInverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("the inverse restores the lane verbatim even when the anchor no longer resolves")
    func inverseNeverRefuses() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let anchor = Self.slot(1, 3)
        let inverse = try SetTempo(anchor: anchor, marking: Self.allegro).apply(to: &score)
        // A later edit shortened the bar, so the anchor's slot is gone: an undo must still put the lane back.
        score.parts[0].staves[0].measures[1].voices[0].elements.removeLast(2)
        #expect(SystemLaneSlot.position(of: anchor, in: score) == nil)
        _ = try inverse.apply(to: &score)
        #expect(score.systemMeasures == before.systemMeasures)
    }

    @Test("a tempo at another beat, and the bar's rehearsal mark, are left alone")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
        _ = try SetTempo(anchor: Self.slot(0, 1), marking: Self.allegro).apply(to: &score)
        _ = try SetTempo(anchor: Self.slot(0, 3), marking: Self.compound).apply(to: &score)
        _ = try SetTempo(anchor: Self.slot(0, 1), marking: nil).apply(to: &score)
        #expect(Self.tempos(score, 0).map(\.0) == [MeasurePosition(numerator: 1, denominator: 2)])
        #expect(RehearsalMarkLane.mark(in: score, measureIndex: 0)?.text == "A")
    }

    @Test("a non-timed anchor, a missing anchor and a clear with nothing to clear are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        #expect(throws: SheetMusicError.self) {
            _ = try SetTempo(anchor: Self.slot(0, 0), marking: Self.allegro).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetTempo(anchor: Self.slot(4, 0), marking: Self.allegro).apply(to: &score)
        }
        let nothing = #expect(throws: SheetMusicError.self) {
            _ = try SetTempo(anchor: Self.slot(0, 1), marking: nil).apply(to: &score)
        }
        #expect(Self.reason(of: nothing) == .targetNotFound(Self.slot(0, 1)))
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
