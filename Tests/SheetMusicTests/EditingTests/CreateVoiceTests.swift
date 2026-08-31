@testable import SheetMusicCore
import Testing

@Suite("CreateVoice")
struct CreateVoiceTests {
    private static let staff = EditingFixtures.staff0

    @Test("a new voice is one full-measure rest")
    func createsRestFilledVoice() throws {
        var score = EditingFixtures.fourQuarterRests()
        let command = CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1)

        _ = try command.apply(to: &score)

        let voices = score.parts[0].staves[0].measures[0].voices
        #expect(voices.count == 2)
        #expect(voices[1].elements == [.rest(duration: .measure)])
        #expect(voices[1].tuplets.isEmpty)
    }

    @Test("undo removes the voice again")
    func inverseRemovesIt() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score
        let inverse = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1).apply(to: &score)

        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("a voice that already exists is refused rather than overwritten")
    func refusesExistingVoice() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 0).apply(to: &score)
        }
        #expect(score.parts[0].staves[0].measures[0].voices.count == 1)
    }

    @Test("a voice index that would leave a gap is refused")
    func refusesGap() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 2).apply(to: &score)
        }
    }

    @Test("a measure that does not exist is refused")
    func refusesMissingMeasure() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try CreateVoice(staff: Self.staff, measureIndex: 9, voiceIndex: 1).apply(to: &score)
        }
    }

    @Test("the new voice fills a pickup bar to the bar's own length")
    func fillsIrregularMeasure() throws {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].actualLength = Fraction(numerator: 1, denominator: 4)
        score.parts[0].staves[0].measures[0].irregular = true

        _ = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1).apply(to: &score)

        // `.measure` is "however long this bar is", so the pickup needs no special case — the same spelling
        // `Score.blank` writes into an anacrusis.
        #expect(score.parts[0].staves[0].measures[0].voices[1].elements == [.rest(duration: .measure)])
    }
}
