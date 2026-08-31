@testable import SheetMusicCore
import Testing

@Suite("SetPartNames")
struct SetPartNamesTests {
    /// Two parts, both named, so a rename of one is observably not a rename of the other.
    private func fixture() -> Score {
        Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [
                .init(
                    instrumentID: "flute", longName: "Flute", shortName: "Fl.",
                    staves: [.init(clefType: "G")], gmProgram: 73,
                ),
                .init(
                    instrumentID: "piano", longName: "Piano", shortName: "Pno.",
                    staves: [.init(clefType: "G"), .init(clefType: "F")],
                ),
            ],
            concertKey: 0, timeNumerator: 4, timeDenominator: 4,
            tempoBPM: 120, measureCount: 2,
        ))
    }

    @Test("writes both names onto the addressed part, and only that part")
    func writesBothNames() throws {
        var score = fixture()
        _ = try SetPartNames(partIndex: 0, longName: "なおき", shortName: "な").apply(to: &score)

        #expect(score.parts[0].instrument.longName == "なおき")
        #expect(score.parts[0].instrument.shortName == "な")
        #expect(score.parts[1].instrument.longName == "Piano")
        #expect(score.parts[1].instrument.shortName == "Pno.")
    }

    /// The rename says what the part is called, not what it plays: the sound, the transposition and the catalog
    /// identity all key off the instrument id, and `trackName` is where the file recorded the instrument's own
    /// name. A host reads that back to say "なおき is a piano".
    @Test("leaves the instrument id and the track name alone")
    func leavesIdentityAlone() throws {
        var score = fixture()
        score.parts[0].trackName = "Flute"
        _ = try SetPartNames(partIndex: 0, longName: "Solo", shortName: "S.").apply(to: &score)

        #expect(score.parts[0].instrument.id == "flute")
        #expect(score.parts[0].trackName == "Flute")
    }

    /// `nil` clears rather than leaving the name alone — a part with no abbreviation engraves no label from the
    /// second system on, which is a thing a score can want to say.
    @Test("nil clears a name")
    func nilClears() throws {
        var score = fixture()
        _ = try SetPartNames(partIndex: 0, longName: "Flute", shortName: nil).apply(to: &score)

        #expect(score.parts[0].instrument.longName == "Flute")
        #expect(score.parts[0].instrument.shortName == nil)
    }

    @Test("the inverse restores both names, including a cleared one")
    func inverseRestores() throws {
        var score = fixture()
        let before = score
        let inverse = try SetPartNames(partIndex: 0, longName: nil, shortName: nil).apply(to: &score)
        #expect(score.parts[0].instrument.longName == nil)

        _ = try inverse.apply(to: &score)
        #expect(score.parts[0].instrument.longName == before.parts[0].instrument.longName)
        #expect(score.parts[0].instrument.shortName == before.parts[0].instrument.shortName)
        #expect(score == before)
    }

    @Test("an index naming no part is refused")
    func outOfRangeRefused() {
        var score = fixture()
        #expect(throws: SheetMusicError.self) {
            try SetPartNames(partIndex: 7, longName: "x", shortName: "x").apply(to: &score)
        }
    }

    /// Renaming a part to what it is already called restores the score to itself, so the planner reports nothing
    /// to apply rather than pushing an undo entry a user has to press twice past.
    @Test("planning a rename to the current names is nothing to apply")
    func noOpPlansToNothing() throws {
        let score = fixture()
        let unchanged = try ScoreEditSession.command(
            for: .setPartNames(at: 0, longName: "Flute", shortName: "Fl."), in: score, depth: 0,
        )
        #expect(unchanged == nil)

        let changed = try ScoreEditSession.command(
            for: .setPartNames(at: 0, longName: "Flute", shortName: nil), in: score, depth: 0,
        )
        #expect(changed != nil)
    }
}
