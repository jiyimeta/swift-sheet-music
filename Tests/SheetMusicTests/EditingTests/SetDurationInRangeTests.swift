@testable import SheetMusicCore
import Testing

@Suite("SetDurationInRange")
struct SetDurationInRangeTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ pitch: Int, _ tpc: Int, _ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    /// `[ts, C4 q, D4 q, E4 q, F4 q]`.
    private static func fourQuarterChords() -> Score {
        var score = EditingFixtures.fourQuarterRests()
        score[slot(1)] = chord(60, 14)
        score[slot(2)] = chord(62, 16)
        score[slot(3)] = chord(64, 18)
        score[slot(4)] = chord(65, 13)
        return score
    }

    private static func elements(_ score: Score) -> [VoiceElement] {
        score.parts[0].staves[0].measures[0].voices[0].elements
    }

    private static let range = VoiceElementRange(start: slot(1), end: slot(4))

    @Test("four quarters to half yields two halves — the consumed onsets are skipped")
    func quartersToHalves() throws {
        var score = Self.fourQuarterChords()
        _ = try SetDurationInRange(over: Self.range, duration: .half).apply(to: &score)
        #expect(Self.elements(score) == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            Self.chord(60, 14, .half), Self.chord(64, 18, .half),
        ])
    }

    @Test("four quarters to whole yields one whole")
    func quartersToWhole() throws {
        var score = Self.fourQuarterChords()
        _ = try SetDurationInRange(over: Self.range, duration: .whole).apply(to: &score)
        #expect(Self.elements(score) == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)), Self.chord(60, 14, .whole),
        ])
    }

    @Test("four quarters to eighth yields eighth-rest pairs, rests via SetRestDuration")
    func quartersToEighths() throws {
        var score = Self.fourQuarterChords()
        score[Self.slot(4)] = .rest(duration: .quarter)
        _ = try SetDurationInRange(over: Self.range, duration: .eighth).apply(to: &score)
        #expect(Self.elements(score) == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            Self.chord(60, 14, .eighth), .rest(duration: .eighth),
            Self.chord(62, 16, .eighth), .rest(duration: .eighth),
            Self.chord(64, 18, .eighth), .rest(duration: .eighth),
            .rest(duration: .eighth), .rest(duration: .eighth),
        ])
    }

    @Test("undo restores the score exactly")
    func undoIsExact() throws {
        var score = Self.fourQuarterChords()
        let before = score
        let inverse = try SetDurationInRange(over: Self.range, duration: .half).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a range already at the duration changes nothing")
    func restatingIsInert() throws {
        var score = Self.fourQuarterChords()
        let before = score
        _ = try SetDurationInRange(over: Self.range, duration: .quarter).apply(to: &score)
        #expect(score == before)
    }

    @Test("a tuplet member anywhere in the range refuses the whole range up front")
    func refusesTuplets() throws {
        var score = Self.fourQuarterChords()
        _ = try CreateTuplet(at: Self.slot(3), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let before = score
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try SetDurationInRange(over: Self.range, duration: .eighth).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .insideTuplet(at: Self.slot(3)))
        #expect(score == before)
    }

    @Test("a lengthening that runs into the barline refuses the whole range and rolls back")
    func refusesAtTheBarline() throws {
        var score = Self.fourQuarterChords()
        let before = score
        let range = VoiceElementRange(start: Self.slot(3), end: Self.slot(4))
        let refused = #expect(throws: SheetMusicError.self) {
            _ = try SetDurationInRange(over: range, duration: .whole).apply(to: &score)
        }
        #expect(Self.reason(of: refused) == .insufficientRoom(neededTicks: 1440, availableTicks: 480))
        #expect(score == before)
    }

    @Test(".measure on a chord, and a range that resolves to nothing, are refused")
    func refusals() {
        var score = Self.fourQuarterChords()
        let measure = #expect(throws: SheetMusicError.self) {
            _ = try SetDurationInRange(over: Self.range, duration: .measure).apply(to: &score)
        }
        #expect(Self.reason(of: measure) == .wrongElementKind(at: Self.slot(1), expected: .rest))
        #expect(throws: SheetMusicError.self) {
            _ = try SetDurationInRange(
                over: VoiceElementRange(start: Self.slot(1), end: Self.slot(9)), duration: .half,
            ).apply(to: &score)
        }
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
