import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// What an absent `<timeStretch>` / `<pause>` means is MuseScore's property default, not ssm's insertion default.
@Suite("Fermata and breath file defaults")
struct FileDefaultsTests {
    /// A `<Fermata>` is a voice-level sibling written just before its chord (the `Chord` decoder has no `Fermata` arm).
    private static func fermataScore(_ fermataXML: String) throws -> Score {
        try MSCXParser.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument></Part>
        <Staff id="1"><Measure><voice>
        \(fermataXML)
        <Chord><durationType>whole</durationType><Note><pitch>72</pitch><tpc>14</tpc></Note></Chord>
        </voice></Measure></Staff></Score></museScore>
        """.utf8))
    }

    private static func fermata(of score: Score) -> Fermata? {
        for element in score.parts[0].staves[0].measures[0].voices[0].elements {
            if case let .fermata(fermata) = element { return fermata }
        }
        return nil
    }

    @Test("the file-default table is MuseScore's (dom/fermata.cpp:194-210)")
    func table() {
        let expected: [(String, Double)] = [
            ("fermataVeryShortAbove", 1.25), ("fermataVeryShortBelow", 1.25),
            ("fermataShortAbove", 1.5), ("fermataShortBelow", 1.5),
            ("fermataShortHenzeAbove", 1.5), ("fermataShortHenzeBelow", 1.5),
            ("fermataAbove", 2.0), ("fermataBelow", 2.0),
            ("fermataLongAbove", 3.0), ("fermataLongBelow", 3.0),
            ("fermataLongHenzeAbove", 3.0), ("fermataLongHenzeBelow", 3.0),
            ("fermataVeryLongAbove", 4.0), ("fermataVeryLongBelow", 4.0),
            // An unknown subtype is MuseScore's `Undefined`, which holds like the plain fermata.
            ("curlewSign", 2.0),
        ]
        let wrong = expected.filter { Fermata.fileDefaultTimeStretch(for: $0.0) != $0.1 }
        #expect(wrong.map(\.0) == [])
        #expect(Breath.fileDefaultPause(for: .caesura(.normal)) == 0)
    }

    @Test("an absent <timeStretch> and an absent <pause> mean MuseScore's defaults")
    func absentTagMeansMuseScoreDefault() throws {
        let score = try Self.fermataScore("<Fermata><subtype>fermataAbove</subtype></Fermata>")
        #expect(Self.fermata(of: score)?.timeStretch == 2.0)
        let breath = try BreathRoundTripTests.parse(BreathRoundTripTests.mscxWith(symbol: "caesura"))
        guard case let .breath(parsed) = breath.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("no breath"); return
        }
        #expect(parsed.pause == 0)
    }

    @Test("a value MuseScore does not default to is written, so MuseScore reads it back")
    func foreignDefaultIsWrittenExplicitly() throws {
        // folino's menu inserts a plain fermata at 1.5 and a normal caesura at 0.5.
        let voice = Voice(elements: [
            .fermata(Fermata(subtype: "fermataAbove")),
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))),
            .breath(Breath(kind: .caesura(.normal))),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
        )
        let text = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(text.contains("<pause>0.5</pause>"))
        #expect(text.contains("<timeStretch>1.5</timeStretch>"))
    }

    @Test("a fermata made at ssm's insertion default is written with its stretch")
    func insertedFermataKeepsItsStretch() {
        let inserted = Fermata(subtype: "fermataAbove")
        #expect(inserted.timeStretch == 1.5)
        let tree = inserted.encode(eid: .invalid)
        #expect(tree.first("timeStretch")?.text == "1.5")
    }

    @Test("MuseScore's own explicit values round-trip")
    func explicitValuesRoundTrip() throws {
        let score = try Self.fermataScore(
            "<Fermata><subtype>fermataLongAbove</subtype><timeStretch>2</timeStretch></Fermata>",
        )
        #expect(Self.fermata(of: score)?.timeStretch == 2)
        let again = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(Self.fermata(of: again)?.timeStretch == 2)
    }

    @Test("a plain fermata at MuseScore's default is written without the tag")
    func defaultIsOmitted() throws {
        let score = try Self.fermataScore("<Fermata><subtype>fermataAbove</subtype></Fermata>")
        let text = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(!text.contains("<timeStretch>"))
    }
}
