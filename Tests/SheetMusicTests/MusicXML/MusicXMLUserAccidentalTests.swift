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

    @Test("a microtonal accidental is user, and a note back in the key after it is still taken as implied")
    func microtonalIsUserAndNeedsNothing() throws {
        let score = try Self.score(fifths: -1, [[
            Self.note("B", accidental: "quarter-flat"),
            Self.note("B", alter: -1, accidental: "flat"),
        ]])
        #expect(Self.accidentals(score) == [[.mirroredFlat, .flat]])
        #expect(Self.roles(score) == [[.user, .user]])
    }

    @Test("the accidental names read as MuseScore's table reads them, natural-sharp as a plain sharp")
    func namesFollowMuseScore() {
        let expected: [String: Accidental] = [
            "natural-sharp": .sharp, "natural-flat": .flat, "sharp-sharp": .doubleSharp, "flat-flat": .doubleFlat,
            "quarter-flat": .mirroredFlat, "three-quarters-sharp": .sharpSlash4, "flat-flat-up": .flat2ArrowUp,
            "triple-sharp": .tripleSharp, "slash-quarter-sharp": .sharpSlash3, "sharp-5": .fiveCommaSharp,
            "flat-4": .fourCommaFlat, "sori": .sori, "koron": .koron,
        ]
        for (name, accidental) in expected {
            #expect(MusicXMLAccidental.symbol(name, smufl: nil) == accidental, "\(name)")
        }
        #expect(MusicXMLAccidental.symbol("double-flat", smufl: nil) == nil)
        #expect(MusicXMLAccidental.symbol("other", smufl: nil) == nil)
    }

    @Test("other names a glyph by its smufl attribute, from the sets MuseScore reads")
    func otherReadsTheSmuflGlyph() {
        #expect(MusicXMLAccidental.symbol("other", smufl: "accidentalFlatOneArrowUp") == .flatOneArrowUp)
        #expect(MusicXMLAccidental.symbol("other", smufl: "accidentalQuarterSharpEqualTempered")
            == .quarterSharpEqualTempered)
        #expect(MusicXMLAccidental.symbol("other", smufl: "accSagittalFlat") == nil)
        // 30 arrow accidentals, 8 Helmholtz-Ellis commas and 7 equal-tempered ones, as in `smuflAccidentalTypes`.
        #expect(MusicXMLAccidental.byGlyph.count == 45)
    }

    @Test("cautionary and editorial accidentals are user, in parentheses and brackets unless told otherwise")
    func cautionaryAndEditorial() throws {
        let cases: [(attributes: String, role: AccidentalRole, bracket: AccidentalBracket)] = [
            ("cautionary=\"yes\"", .user, .parenthesis),
            ("editorial=\"yes\"", .user, .bracket),
            ("cautionary=\"yes\" bracket=\"yes\"", .user, .parenthesis),
            ("editorial=\"yes\" parentheses=\"yes\"", .user, .parenthesis),
            ("cautionary=\"yes\" parentheses=\"no\"", .user, .none),
            ("parentheses=\"yes\"", .auto, .parenthesis),
            ("bracket=\"yes\"", .auto, .bracket),
        ]
        for entry in cases {
            let note = Self.note("B", alter: -1, accidental: "flat", attributes: entry.attributes)
            let score = try Self.score(fifths: 0, [[note]])
            let read = try #require(Self.notes(score).first?.first)
            #expect(read.accidentalRole == entry.role, "\(entry.attributes)")
            #expect(read.accidentalBracket == entry.bracket, "\(entry.attributes)")
        }
    }

    // MARK: - Helpers

    /// A quarter note at 480 divisions to the quarter.
    private static func note(
        _ step: String, alter: Int = 0, octave: Int = 4, accidental: String, attributes: String = "",
    ) -> String {
        let alterTag = alter == 0 ? "" : "<alter>\(alter)</alter>"
        let open = attributes.isEmpty ? "<accidental>" : "<accidental \(attributes)>"
        return "<note><pitch><step>\(step)</step>\(alterTag)<octave>\(octave)</octave></pitch>"
            + "<duration>480</duration><voice>1</voice><type>quarter</type>"
            + "\(open)\(accidental)</accidental></note>"
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
