@testable import SheetMusicCore
import Testing

@Suite("SetDrumsetEntry")
struct SetDrumsetEntryTests {
    private static func drumScore() -> Score {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [.rest(duration: .measure)])])])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "drumset", useDrumset: true, drumLineMap: [38: 2]),
            staves: [staff],
        )
        return Score(division: 480, parts: [part])
    }

    private static let hiHat = DrumsetEntry(
        name: "Closed Hi-Hat", head: "cross", line: -1, voiceIndex: 0, stem: 1,
    )

    @Test func `an entry the kit lacked is added`() throws {
        var score = Self.drumScore()

        _ = try SetDrumsetEntry(partIndex: 0, pitch: 42, entry: Self.hiHat).apply(to: &score)

        #expect(score.parts[0].instrument.drumset[42] == Self.hiHat)
        #expect(score.parts[0].instrument.drumLineMap[42] == -1)
    }

    @Test func `undo takes the row back out`() throws {
        var score = Self.drumScore()
        let before = score

        let inverse = try SetDrumsetEntry(partIndex: 0, pitch: 42, entry: Self.hiHat).apply(to: &score)
        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test func `undo restores the row that was there`() throws {
        var score = Self.drumScore()
        let before = score.parts[0].instrument.drumset[38]

        let inverse = try SetDrumsetEntry(partIndex: 0, pitch: 38, entry: Self.hiHat).apply(to: &score)
        _ = try inverse.apply(to: &score)

        #expect(score.parts[0].instrument.drumset[38] == before)
    }

    @Test func `a nil entry removes the pitch`() throws {
        var score = Self.drumScore()

        _ = try SetDrumsetEntry(partIndex: 0, pitch: 38, entry: nil).apply(to: &score)

        #expect(score.parts[0].instrument.drumset[38] == nil)
    }

    @Test func `a part that is not there is refused`() {
        var score = Self.drumScore()
        #expect(throws: SheetMusicError.self) {
            _ = try SetDrumsetEntry(partIndex: 4, pitch: 42, entry: Self.hiHat).apply(to: &score)
        }
    }

    @Test func `restating the row the kit already has plans to nothing`() {
        let session = ScoreEditSession(score: Self.drumScore())
        let existing = session.score.parts[0].instrument.drumset[38]

        #expect(!session.apply(.setDrumsetEntry(partIndex: 0, pitch: 38, entry: existing)))
    }

    @Test func `the intent lands through the session`() {
        let session = ScoreEditSession(score: Self.drumScore())

        #expect(session.apply(.setDrumsetEntry(partIndex: 0, pitch: 42, entry: Self.hiHat)))

        #expect(session.score.parts[0].instrument.drumset[42] == Self.hiHat)
    }
}
