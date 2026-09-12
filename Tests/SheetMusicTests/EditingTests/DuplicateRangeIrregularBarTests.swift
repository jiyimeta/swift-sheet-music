@testable import SheetMusicCore
import Testing

/// What `R` does when the bars it crosses are not all the same length — a pickup bar, or two staves that
/// disagree about how long a measure is. Every other `DuplicateRange` fixture is 4/4 throughout, so the paths
/// that resolve a `.measure` duration against the wrong bar only ever run here.
@Suite("DuplicateRange (irregular bars)")
struct DuplicateRangeIrregularBarTests {
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

    /// Measure 0 is a one-beat pickup — `actualLength` 1/4, so its voice 1 whole-bar rest is 480 ticks and not
    /// 1920. Measures 1 and 2 are full 4/4 bars, measure 1 carrying four quarters in each of its two voices so
    /// that a copy landing on it is visible element by element.
    private static func pickupThenFourFour() -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(
                voices: [
                    Voice(elements: [
                        .timeSignature(TimeSignature(numerator: 4, denominator: 4)), quarter(60, 14),
                    ]),
                    Voice(elements: [.rest(duration: .measure)]),
                ],
                actualLength: Fraction(numerator: 1, denominator: 4),
            ),
            Measure(voices: [
                Voice(elements: [quarter(62, 16), quarter(64, 18), quarter(65, 13), quarter(67, 15)]),
                Voice(elements: [quarter(50, 15), quarter(52, 17), quarter(53, 12), quarter(55, 14)]),
            ]),
            Measure(voices: [
                Voice(elements: [.rest(duration: .measure)]), Voice(elements: [.rest(duration: .measure)]),
            ]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    /// Two staves whose measure 0 disagrees: the flute's is a one-beat pickup, the cello's a full 4/4 bar. Every
    /// later bar agrees, so only a copy that starts here can notice.
    private static func stavesDisagreeingOverMeasureZero() -> Score {
        let flute = Staff(defaultClefType: "G", measures: [
            Measure(
                voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)), quarter(60, 14),
                ])],
                actualLength: Fraction(numerator: 1, denominator: 4),
            ),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        let cello = Staff(defaultClefType: "F", measures: [
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [flute]),
            Part(id: "2", trackName: "Cello", instrument: Instrument(id: "cello"), staves: [cello]),
        ])
    }

    @Test("a whole-bar rest copied out of a pickup keeps the pickup's length in the destination bar")
    func measureRestKeepsItsSourceLength() throws {
        var score = Self.pickupThenFourFour()
        // The pickup's one beat, which selects voice 1's whole-bar rest along with it. That rest is 480 ticks in
        // its own bar; written verbatim as `.measure` into the 4/4 bar it lands in, it would claim 1920.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1)))
            .apply(to: &score)
        #expect(Self.voice(score, 1).elements == [
            Self.quarter(60, 14), Self.quarter(64, 18), Self.quarter(65, 13), Self.quarter(67, 15),
        ])
        // One beat of rest, then the three quarters the copy never reached.
        #expect(Self.voice(score, 1, 1).elements == [
            .rest(duration: .quarter), Self.quarter(52, 17), Self.quarter(53, 12), Self.quarter(55, 14),
        ])
    }

    @Test("a whole-bar rest copied to a mid-bar tick does not claim the whole destination bar")
    func measureRestPlacedMidBar() throws {
        var score = Self.pickupThenFourFour()
        // The range runs from the pickup through beat 2 of bar 1 — 1440 ticks — so the copy starts at beat 3 of
        // bar 1. The pickup's whole-bar rest lands there, mid-bar.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(1, 1)))
            .apply(to: &score)
        let rebuilt = Self.voice(score, 1, 1)
        let total = rebuilt.elements.values.reduce(0) {
            $0 + $1.cursorAdvance(division: 480, in: Fraction(numerator: 4, denominator: 4))
        }
        #expect(total == 1920)
    }

    @Test("a piece that would overrun its destination bar is refused rather than written")
    func refusesOverlongPiece() {
        var score = EditingFixtures.parityFixture()
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        // Three quarters starting at beat 3 of a 4/4 bar reach tick 2400 — 480 ticks past the bar's end.
        let piece = RangeCopyPlacement.Piece(
            measureIndex: 0, startTickInMeasure: 960,
            elements: [Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18)], tuplets: [],
        )
        #expect(throws: SheetMusicError.self) {
            _ = try RangeCopyVoiceRebuild.command(for: piece, staff: Self.flute, voiceIndex: 0, in: score)
        }
    }

    @Test("a range whose staves disagree about a measure's length is refused")
    func refusesDisagreeingStaves() {
        var score = Self.stavesDisagreeingOverMeasureZero()
        let before = score
        // Both staves' measure 0. The range's ticks are measured on the flute's one-beat bar, while the cello's
        // material is placed on its own four-beat axis — the subtraction that puts the copy after the original
        // is the same on both, so one of the two staves must land wrong.
        #expect(throws: SheetMusicError.self) {
            _ = try DuplicateRange(over: VoiceElementRange(
                start: Self.slot(0, 1), end: Self.slot(0, 0, staff: Self.cello),
            )).apply(to: &score)
        }
        #expect(score == before)
    }
}
