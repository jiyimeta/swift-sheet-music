import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// `<grace>` notes, read as MuseScore's MusicXML importer reads them (`importmusicxmlpass2.cpp`). They used to be read
/// as ordinary notes, which overfilled their measure and lost the grace.
@Suite("Grace MusicXML import")
struct GraceImportTests {
    /// One 4/4 measure of `body` (MusicXML `<note>` elements at 480 divisions) on a single treble staff.
    static func measure(_ body: String) throws -> Measure {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>480</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              \(body)
            </measure>
          </part>
        </score-partwise>
        """
        return try MusicXMLParser.parse(Data(xml.utf8)).parts[0].staves[0].measures[0]
    }

    static func note(_ step: String, _ octave: Int, voice: Int = 1, _ inner: String = "") -> String {
        """
        <note><pitch><step>\(step)</step><octave>\(octave)</octave></pitch>
          <duration>480</duration><voice>\(voice)</voice><type>quarter</type>\(inner)</note>
        """
    }

    static func grace(
        _ step: String, _ octave: Int, type: String = "eighth", slash: Bool = false, chord: Bool = false,
        voice: Int = 1, notations: String = "",
    ) -> String {
        """
        <note><grace\(slash ? " slash=\"yes\"" : "")/>\(chord ? "<chord/>" : "")
          <pitch><step>\(step)</step><octave>\(octave)</octave></pitch>
          <voice>\(voice)</voice><type>\(type)</type>\(notations)</note>
        """
    }

    static func chords(_ measure: Measure, voice: Int = 0) -> [Chord] {
        measure.voices[voice].elements.compactMap { if case let .chord(chord) = $0 { chord } else { nil } }
    }

    static let fourQuarters = [note("C", 5), note("D", 5), note("E", 5), note("F", 5)]

    @Test("a slashed grace leads into the next chord as an acciaccatura and takes no voice time")
    func acciaccaturaBeforeTheNextChord() throws {
        let measure = try Self.measure(Self.grace("B", 4, slash: true) + Self.fourQuarters.joined())

        let chords = Self.chords(measure)
        #expect(chords.count == 4, "four quarters and no fifth chord for the grace")
        let grace = try #require(chords.first?.graceNotesBefore.first)
        #expect(grace.graceType == .acciaccatura)
        #expect(grace.duration == .eighth)
        #expect(grace.notes.map(\.pitch) == [71])
        #expect(chords.dropFirst().allSatisfy { $0.graceNotesBefore.isEmpty && $0.graceNotesAfter.isEmpty })
    }

    @Test("an unslashed grace is an appoggiatura, or grace4 / grace16 / grace32 by its type")
    func unslashedTypes() throws {
        let cases: [(String, GraceType)] = [
            ("eighth", .appoggiatura), ("quarter", .grace4), ("16th", .grace16), ("32nd", .grace32),
        ]
        for (type, expected) in cases {
            let measure = try Self.measure(Self.grace("G", 4, type: type) + Self.fourQuarters.joined())
            #expect(Self.chords(measure).first?.graceNotesBefore.first?.graceType == expected, "type \(type)")
        }
    }

    @Test("a grace note with <chord/> joins the grace chord before it; one without opens the next")
    func graceChordsAndSequences() throws {
        let measure = try Self.measure(
            Self.grace("C", 5) + Self.grace("E", 5, chord: true) + Self.grace("D", 5) + Self.fourQuarters.joined(),
        )

        let graces = try #require(Self.chords(measure).first).graceNotesBefore
        #expect(graces.count == 2)
        #expect(graces.first?.notes.map(\.pitch) == [72, 76])
        #expect(graces.last?.notes.map(\.pitch) == [74])
    }

    @Test("graces a slur ends on lean back on the chord before them as after-graces")
    func slurredBackGracesAreAfterGraces() throws {
        let slurStop = "<notations><slur type=\"stop\"/></notations>"
        let measure = try Self.measure(
            Self.note("C", 5) + Self.grace("B", 4, type: "16th", notations: slurStop)
                + Self.note("D", 5) + Self.note("E", 5) + Self.note("F", 5),
        )

        let chords = Self.chords(measure)
        #expect(chords[0].graceNotesAfter.map(\.graceType) == [.grace16after])
        #expect(chords[1].graceNotesBefore.isEmpty)
    }

    @Test("graces left at the end of a measure lean back on its last chord")
    func trailingGracesAreAfterGraces() throws {
        let measure = try Self.measure(Self.fourQuarters.joined() + Self.grace("G", 5))

        let last = try #require(Self.chords(measure).last)
        #expect(last.graceNotesAfter.map(\.graceType) == [.grace8after])
        #expect(last.graceNotesAfter.first?.notes.map(\.pitch) == [79])
    }

    @Test("a trailing acciaccatura has no after form, so it stays a grace before the last chord, as in MuseScore")
    func trailingAcciaccaturaStaysBefore() throws {
        let measure = try Self.measure(Self.fourQuarters.joined() + Self.grace("G", 5, slash: true))

        let last = try #require(Self.chords(measure).last)
        #expect(last.graceNotesAfter.isEmpty)
        #expect(last.graceNotesBefore.map(\.graceType) == [.acciaccatura])
    }

    @Test("a grace leans on the next chord of its own voice")
    func graceStaysInItsVoice() throws {
        let measure = try Self.measure(
            Self.note("C", 5) + Self.grace("A", 3, voice: 2) + Self.note("D", 5) + Self.note("E", 5)
                + Self.note("F", 5) + "<backup><duration>1920</duration></backup>"
                + Self.note("C", 4, voice: 2) + Self.note("D", 4, voice: 2) + Self.note("E", 4, voice: 2)
                + Self.note("F", 4, voice: 2),
        )

        let firstVoiceGraces = Self.chords(measure, voice: 0).flatMap(\.graceNotesBefore)
        #expect(firstVoiceGraces.isEmpty)
        #expect(Self.chords(measure, voice: 1).first?.graceNotesBefore.first?.notes.map(\.pitch) == [57])
    }
}
