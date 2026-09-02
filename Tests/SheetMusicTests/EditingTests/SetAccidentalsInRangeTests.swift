@testable import SheetMusicCore
import Testing

@Suite("SetAccidentalsInRange")
struct SetAccidentalsInRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func note(_ score: Score, _ measure: Int, _ element: Int) -> Note? {
        guard case let .chord(chord)? = score[slot(measure, element)] else { return nil }
        return chord.notes.first
    }

    @Test("a sharp respells every note in the range, letter kept, pitch raised")
    func sharpens() throws {
        var score = EditingFixtures.parityFixture() // C4, D4
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))
        _ = try SetAccidentalsInRange(over: range, accidental: .sharp).apply(to: &score)
        #expect(Self.note(score, 0, 1)?.pitch == 61)
        #expect(Self.note(score, 0, 1)?.tpc == 21)
        #expect(Self.note(score, 0, 1)?.accidental == .sharp)
        #expect(Self.note(score, 0, 2)?.pitch == 63)
        #expect(Self.note(score, 0, 2)?.tpc == 23)
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(2, 1))
        let inverse = try SetAccidentalsInRange(over: range, accidental: .flat).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("nil clears the glyph and leaves pitch and tpc alone")
    func clears() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1))
        _ = try SetAccidentalsInRange(over: range, accidental: .sharp).apply(to: &score)
        _ = try SetAccidentalsInRange(over: range, accidental: nil).apply(to: &score)
        #expect(Self.note(score, 0, 1)?.pitch == 61)
        #expect(Self.note(score, 0, 1)?.tpc == 21)
        #expect(Self.note(score, 0, 1)?.accidental == nil)
    }

    @Test("a tie chain is respelled whole, glyph on the head only")
    func tieChain() throws {
        var score = EditingFixtures.parityFixture() // m2: E4 h tied → E4 h
        let range = VoiceElementRange(start: Self.slot(2, 1), end: Self.slot(2, 1)) // the TAIL only
        _ = try SetAccidentalsInRange(over: range, accidental: .flat).apply(to: &score)
        #expect(Self.note(score, 2, 0)?.pitch == 63)
        #expect(Self.note(score, 2, 0)?.accidental == .flat)
        #expect(Self.note(score, 2, 1)?.pitch == 63)
        #expect(Self.note(score, 2, 1)?.tpc == 11)
        #expect(Self.note(score, 2, 1)?.accidental == nil)
    }

    @Test("rests are skipped and a range of rests changes nothing")
    func restsAreLeftAlone() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let range = VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3))
        _ = try SetAccidentalsInRange(over: range, accidental: .natural).apply(to: &score)
        #expect(score == before)
    }

    @Test("a range that resolves to nothing is refused")
    func refusesUnresolvable() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try SetAccidentalsInRange(
                over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(8, 0)), accidental: .sharp,
            ).apply(to: &score)
        }
    }
}
