import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// A written accidental the key already implies is a `user` accidental, as MuseScore's import makes it
/// (`markUserAccidentals`): read as `auto`, it was the redundant glyph `suppressingRedundantAccidentals` hides, so a
/// courtesy flat vanished from the page and from a MuseScore save.
@Suite("MusicXML written accidentals")
struct MusicXMLUserAccidentalTests {
    @Test("a flat the key has, written anyway, is a user accidental and stays drawn")
    func impliedFlatIsUser() throws {
        let score = try Self.score(fifths: -1, [[Self.note("B", alter: -1, accidental: "flat")]])
        #expect(Self.roles(score) == [[.user]])
        let drawn = score.suppressingRedundantAccidentals()
        #expect(Self.accidentals(drawn) == [[.flat]])
    }

    @Test("a courtesy natural where the key has none is a user accidental")
    func courtesyNaturalIsUser() throws {
        let score = try Self.score(fifths: 0, [[Self.note("C", accidental: "natural")]])
        #expect(Self.roles(score) == [[.user]])
    }

    @Test("an accidental the key does not imply stays auto")
    func neededAccidentalIsAuto() throws {
        let score = try Self.score(fifths: 0, [[Self.note("B", alter: -1, accidental: "flat")]])
        #expect(Self.roles(score) == [[.auto]])
    }

    @Test("once a line leaves the key, a note back in it needs its accidental and stays auto; another octave does not")
    func aLineThatLeftTheKeyStaysAuto() throws {
        let score = try Self.score(fifths: -1, [[
            Self.note("B", accidental: "natural"),
            Self.note("B", alter: -1, accidental: "flat"),
            Self.note("B", alter: -1, octave: 3, accidental: "flat"),
        ]])
        #expect(Self.roles(score) == [[.auto, .auto, .user]])
    }

    @Test("a key that starts the measure is the one its accidentals are judged against")
    func aKeyChangeAtTheBarCounts() throws {
        let change = "<attributes><key><fifths>-1</fifths></key></attributes>"
        let score = try Self.score(fifths: 0, [
            [Self.note("B", alter: -1, accidental: "flat")],
            [change + Self.note("B", alter: -1, accidental: "flat")],
        ])
        #expect(Self.roles(score) == [[.auto], [.user]])
    }

    @Test("a MuseScore save keeps the accidental as a user one")
    func mscxSaveKeepsTheRole() throws {
        let score = try Self.score(fifths: -1, [[Self.note("B", alter: -1, accidental: "flat")]])
        let data = try MSCXEncoder.encode(score)
        let reread = try MSCXParser.parse(data)
        #expect(Self.roles(reread) == [[.user]])
    }

    // MARK: - Helpers

    /// A quarter note at 480 divisions to the quarter.
    private static func note(_ step: String, alter: Int = 0, octave: Int = 4, accidental: String) -> String {
        let alterTag = alter == 0 ? "" : "<alter>\(alter)</alter>"
        return "<note><pitch><step>\(step)</step>\(alterTag)<octave>\(octave)</octave></pitch>"
            + "<duration>480</duration><voice>1</voice><type>quarter</type>"
            + "<accidental>\(accidental)</accidental></note>"
    }

    /// One part, a measure per entry of `measures` — each as long as its quarters — under a key of `fifths`.
    private static func score(fifths: Int, _ measures: [[String]]) throws -> Score {
        let body = measures.enumerated().map { index, notes in
            let attributes = index == 0
                ? "<attributes><divisions>480</divisions><key><fifths>\(fifths)</fifths></key>"
                + "<time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef>"
                + "</attributes>"
                : ""
            return "<measure number=\"\(index + 1)\">\(attributes)\(notes.joined())</measure>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">\
        <part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>\
        <part id="P1">\(body)</part></score-partwise>
        """
        return try MusicXMLParser.parse(Data(xml.utf8))
    }

    private static func notes(_ score: Score) -> [[Note]] {
        score.parts[0].staves[0].measures.map { measure in
            measure.voices[0].elements.values.flatMap { element -> [Note] in
                if case let .chord(chord) = element { Array(chord.notes) } else { [] }
            }
        }
    }

    private static func roles(_ score: Score) -> [[AccidentalRole]] {
        notes(score).map { $0.map(\.accidentalRole) }
    }

    private static func accidentals(_ score: Score) -> [[Accidental?]] {
        notes(score).map { $0.map(\.accidental) }
    }
}
