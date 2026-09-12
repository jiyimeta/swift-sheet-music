@testable import SheetMusicCore
import Testing

@Suite("DuplicateRange")
struct DuplicateRangeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0, staff: StaffAddress = flute)
        -> VoiceElementID
    {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int, _ index: Int = 0, part: Int = 0) -> Voice {
        score.parts[part].staves[0].measures[measure].voices[index]
    }

    @Test("two beats are repeated on the following two beats")
    func repeatsTwoBeats() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ])
    }

    @Test("a whole bar is repeated into the next bar")
    func repeatsWholeBar() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        #expect(Self.voice(score, 1).elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    @Test("a voice the source does not have is left alone")
    func leavesOtherVoices() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        #expect(Self.voice(score, 1, 1).elements == [.rest(duration: .measure)])
    }

    @Test("every staff's copy lands in its own staff")
    func multiStaff() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(
            start: Self.slot(0, 1), end: Self.slot(0, 1, staff: Self.cello),
        )).apply(to: &score)
        #expect(Self.voice(score, 0).elements.count == 5)
        #expect(Self.voice(score, 0, part: 1).elements.count >= 2)
        // The two counts above hold even if nothing had been written, so state where each staff's copy landed:
        // the flute's bar into the flute, the cello's measure rest into the cello, neither into the other.
        #expect(Self.voice(score, 1).elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(Self.voice(score, 1, part: 1).elements == [.rest(duration: .measure)])
    }

    @Test("a triplet is repeated as a triplet")
    func repeatsTuplet() throws {
        var score = EditingFixtures.parityFixture()
        _ = try CreateTuplet(at: Self.slot(0, 1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 3)))
            .apply(to: &score)
        let spans = Self.voice(score, 0).tupletSpans
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.actualNotes == 3 })
    }

    @Test("repeating the last bar appends measures")
    func appendsAtScoreEnd() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 5)
        #expect(score.parts[1].staves[0].measures.count == 5)
    }

    @Test("undo restores the score exactly, appended measures included")
    func undoIsExact() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score != before)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a dotted note is copied as a dotted note, not as a tied pair")
    func keepsDots() throws {
        var score = EditingFixtures.parityFixture()
        let dotted = VoiceElement.chord(Chord(
            duration: .fraction(Fraction(numerator: 3, denominator: 8)),
            notes: [Note(pitch: 60, tpc: 14)],
        ))
        score[Self.slot(0, 1)] = dotted
        score[Self.slot(0, 2)] = .rest(duration: .eighth)
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)))
            .apply(to: &score)
        #expect(Self.voice(score, 0).elements[3] == dotted)
    }

    @Test("a whole-bar rest is copied as a measure rest")
    func keepsMeasureRest() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures[4].voices[0].elements == [.rest(duration: .measure)])
    }

    @Test("a range that resolves to nothing is refused")
    func refusesUnresolvable() {
        var score = EditingFixtures.parityFixture()
        #expect(throws: SheetMusicError.self) {
            _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)))
                .apply(to: &score)
        }
    }
}
