@testable import SheetMusicCore
import Testing

@Suite("SplitRest")
struct SplitRestTests {
    private static func halfRestScore() -> Score {
        var score = EditingFixtures.fourQuarterRests()
        // Elements [1...4] are quarter rests; make [1] a half and drop one so the bar still totals 4/4.
        score.parts[0].staves[0].measures[0].voices[0].elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ]
        return score
    }

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("a half rest split at its midpoint becomes two quarter rests")
    func splitsAtMidpoint() throws {
        var score = Self.halfRestScore()

        _ = try SplitRest(at: Self.slot(1), tickOffset: 480).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
    }

    @Test("an off-beat split is spelled beat-aligned, not greedily")
    func splitsBeatAligned() throws {
        var score = Self.halfRestScore()

        // An eighth into the half rest: the head is one eighth, and the tail — three eighths starting off the
        // beat — aligns as eighth + quarter rather than as a greedy dotted quarter.
        _ = try SplitRest(at: Self.slot(1), tickOffset: 240).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements[1] == .rest(duration: .eighth))
        #expect(elements[2] == .rest(duration: .eighth))
        #expect(elements[3] == .rest(duration: .quarter))
    }

    @Test("undo restores the single rest")
    func inverseRestores() throws {
        var score = Self.halfRestScore()
        let before = score
        let inverse = try SplitRest(at: Self.slot(1), tickOffset: 480).apply(to: &score)

        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("a full-measure rest splits against the bar's own length")
    func splitsMeasureRest() throws {
        var score = EditingFixtures.fullMeasureRest()

        _ = try SplitRest(at: Self.slot(1), tickOffset: 480).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements.count == 4)
        #expect(elements[1] == .rest(duration: .quarter))
    }

    @Test("an offset of zero, or past the rest, is refused")
    func refusesOutOfRangeOffset() {
        var score = Self.halfRestScore()
        for offset in [0, 960, 1200, -1] {
            #expect(throws: SheetMusicError.self) {
                _ = try SplitRest(at: Self.slot(1), tickOffset: offset).apply(to: &score)
            }
        }
    }

    @Test("a chord is refused — this splits rests only")
    func refusesChord() {
        var score = EditingFixtures.chordAtIndex1()
        #expect(throws: SheetMusicError.self) {
            _ = try SplitRest(at: Self.slot(1), tickOffset: 240).apply(to: &score)
        }
    }
}
