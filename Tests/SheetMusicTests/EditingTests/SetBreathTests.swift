@testable import SheetMusicCore
import Testing

@Suite("SetBreath")
struct SetBreathTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements
    }

    @Test("a breath is inserted right after its chord")
    func inserts() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4, D4, r, r]
        _ = try SetBreath(after: Self.slot(0, 1), kind: .breathMark(.comma), pause: 0).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[2] == .breath(Breath(kind: .breathMark(.comma), pause: 0)))
        #expect(elements[3] == .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])))
        #expect(SetBreath.current(after: Self.slot(0, 1), in: score)?.kind == .breathMark(.comma))
    }

    @Test("a breath lands before the bar's trailing barline")
    func beforeTheBarline() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetBarLine(at: MeasureRef(measureIndex: 2), style: .double).apply(to: &score)
        // m2: [E4, E4, barline]
        _ = try SetBreath(after: Self.slot(2, 1), kind: .caesura(.normal), pause: 0.5).apply(to: &score)
        let elements = Self.elements(score, 2)
        #expect(elements[2] == .breath(Breath(kind: .caesura(.normal), pause: 0.5)))
        #expect(elements[3] == .barLine(BarLine(subtype: "double")))
    }

    @Test("a breath already after the chord is replaced in place, keeping its visibility")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        var hidden = Breath(kind: .breathMark(.tick))
        hidden.visible = false
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(.breath(hidden), at: 2)
        _ = try SetBreath(after: Self.slot(0, 1), kind: .caesura(.thick), pause: 0.75).apply(to: &score)
        guard case let .breath(breath) = Self.elements(score, 0)[2] else {
            Issue.record("expected a breath")
            return
        }
        #expect(breath.kind == .caesura(.thick))
        #expect(breath.pause == 0.75)
        #expect(breath.visible == false)
        #expect(Self.elements(score, 0).count == 6)
    }

    @Test("nil removes; the inverses restore the score exactly")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetBreath(after: Self.slot(0, 2), kind: .breathMark(.upbow), pause: 0)
            .apply(to: &score)
        let written = score
        let clearInverse = try SetBreath(after: Self.slot(0, 2), kind: nil, pause: 0).apply(to: &score)
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
            _ = try SetBreath(after: Self.slot(0, 3), kind: .breathMark(.comma), pause: 0).apply(to: &score)
        }
        #expect(Self.reason(of: rest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        #expect(throws: SheetMusicError.self) {
            _ = try SetBreath(after: Self.slot(0, 0), kind: .breathMark(.comma), pause: 0).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetBreath(after: Self.slot(0, 9), kind: .breathMark(.comma), pause: 0).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetBreath(after: Self.slot(0, 1), kind: nil, pause: 0).apply(to: &score)
        }
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
