@testable import SheetMusicCore
import Testing

/// `SetVolta` — measure-granular, on the canonical staff, whatever staff the range names.
@Suite("SetVolta")
struct SetVoltaTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ staff: StaffAddress, _ measure: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: 0)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("a volta over bars 1…2 of the CELLO lands at index 0 of the flute's bar 1 and spans two bars")
    func writesOnTheCanonicalStaff() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.cello, 1), end: Self.slot(Self.cello, 2))
        _ = try SetVolta(over: range, endings: [1, 2], text: "1.–2.").apply(to: &score)
        #expect(score.parts[1] == EditingFixtures.parityFixture().parts[1])
        guard case let .spanner(volta) = score.parts[0].staves[0].measures[1].voices[0].elements[0] else {
            Issue.record("expected the volta at index 0 of the flute's bar 1"); return
        }
        #expect(volta.kind == .volta)
        #expect(volta.rawType == "Volta")
        #expect(volta.voltaEndings == [1, 2])
        #expect(volta.beginText == "1.–2.")
        #expect(volta.nextMeasuresOffset == 2)
        #expect(volta.nextFractionsOffset == nil)
    }

    @Test("a volta on the last bar takes the score-end spelling, not a nil fractions offset")
    func lastBar() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 3), end: Self.slot(Self.flute, 3))
        _ = try SetVolta(over: range, endings: [2], text: nil).apply(to: &score)
        guard case let .spanner(volta) = score.parts[0].staves[0].measures[3].voices[0].elements[0] else {
            Issue.record("expected the volta"); return
        }
        #expect(volta.nextMeasuresOffset == 0)
        #expect(volta.nextFractionsOffset == Fraction(numerator: 1, denominator: 1))
        #expect(volta.beginText == nil)
    }

    @Test("undo restores the score exactly and the bar's own signatures stay after the volta")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let range = VoiceElementRange(start: Self.slot(Self.flute, 0), end: Self.slot(Self.flute, 0))
        let inverse = try SetVolta(over: range, endings: [1], text: "1.").apply(to: &score)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements[1] == .timeSignature(TimeSignature(numerator: 4, denominator: 4)))
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("empty text is nil, not a refusal — a volta with no label is a legal volta")
    func emptyTextIsNil() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 1), end: Self.slot(Self.flute, 1))
        _ = try SetVolta(over: range, endings: [], text: "   ").apply(to: &score)
        guard case let .spanner(volta) = score.parts[0].staves[0].measures[1].voices[0].elements[0] else {
            Issue.record("expected the volta"); return
        }
        #expect(volta.beginText == nil)
        #expect(volta.voltaEndings == [])
    }

    @Test("a second volta on the same bar and a bar past the end are refused")
    func refusals() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 1), end: Self.slot(Self.flute, 1))
        _ = try SetVolta(over: range, endings: [1], text: "1.").apply(to: &score)
        let written = score
        let twice = #expect(throws: SheetMusicError.self) {
            _ = try SetVolta(over: range, endings: [2], text: "2.").apply(to: &score)
        }
        #expect(Self.reason(of: twice) == .duplicateSpanner(
            at: VoiceElementID(staff: Self.flute, measureIndex: 1, voiceIndex: 0, elementIndex: 0), kind: .volta,
        ))
        #expect(throws: SheetMusicError.self) {
            _ = try SetVolta(
                over: VoiceElementRange(start: Self.slot(Self.flute, 9), end: Self.slot(Self.flute, 9)),
                endings: [1], text: nil,
            ).apply(to: &score)
        }
        #expect(score == written)
    }
}
