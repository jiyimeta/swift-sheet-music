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

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    /// Two 4/4 bars on one staff whose LAST bar carries a second voice holding a whole-bar rest, over a voice 0
    /// of `C4 D4 r r`. A two-beat selection of voice 0 there copies voice 1's whole-bar rest along with it, and
    /// that rest outlasts the selection by two beats — the shape the append pass has to size itself against.
    private static func wholeBarRestUnderTheLastBar() -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .rest(duration: .quarter), .rest(duration: .quarter),
                .rest(duration: .quarter), .rest(duration: .quarter),
            ])]),
            Measure(voices: [
                Voice(elements: [
                    quarter(60, 14), quarter(62, 16), .rest(duration: .quarter), .rest(duration: .quarter),
                ]),
                Voice(elements: [.rest(duration: .measure)]),
            ]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
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
        // Voice 1's pre-edit value also holds if nothing was written at all, so state that the copy DID land in
        // the same bar's voice 0 — that is what makes voice 1's measure rest "left alone" rather than "unreached".
        #expect(Self.voice(score, 1).elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
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
        // A count and a ratio hold even if the copy landed on the wrong slots, so name where the two brackets
        // sit and assert the copied members are the source members, element for element. The source triplet
        // occupies 1...3 (after the time signature); the copy replaces the quarter that stood at tick 480.
        let elements = Self.voice(score, 0).elements
        #expect(spans.map(\.startIndex) == [1, 4])
        #expect(spans.map(\.endIndex) == [3, 6])
        #expect(Array(elements.values[4 ... 6]) == Array(elements.values[1 ... 3]))
    }

    @Test("repeating the last bar appends measures")
    func appendsAtScoreEnd() throws {
        var score = EditingFixtures.parityFixture()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 5)
        #expect(score.parts[1].staves[0].measures.count == 5)
    }

    @Test("an element copied whole because its onset was in range gets the bar it overhangs into")
    func appendsForMaterialOutlastingTheRange() throws {
        var score = Self.wholeBarRestUnderTheLastBar()
        // Two beats of the last bar's voice 0. Voice 1's whole-bar rest is selected with them — the selection
        // goes by ONSET — so the copy reaches two beats past the copied range's own end, into a bar that does
        // not exist yet. Sizing the append by the range's length instead refuses this outright.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 1)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 3)
        #expect(Self.voice(score, 1).elements == [
            Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(60, 14), Self.quarter(62, 16),
        ])
        // The whole-bar rest's copy starts on beat 3 of the last bar and spills a half note into the new one.
        #expect(Self.voice(score, 1, 1).elements == [.rest(duration: .half), .rest(duration: .half)])
        #expect(score.parts[0].staves[0].measures[2].voices.count == 2)
        #expect(Self.voice(score, 2, 1).elements == [.rest(duration: .half), .rest(duration: .half)])
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
