import Foundation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// `<notehead>`'s value is the notehead's shape. It used to be read for its `parentheses` attribute only, so every
/// shaped head a MusicXML file named — the open hi-hat's circle-x, a cymbal's x, a rim's diamond — came in as a plain
/// black head.
struct MusicXMLNoteheadTests {
    /// MuseScore's `convertNotehead` (`importmusicxmlpass2.cpp`), entry by entry.
    @Test(arguments: [
        ("slash", "slash"),
        ("triangle", "triangle-up"),
        ("diamond", "diamond"),
        ("cross", "plus"),
        ("x", "cross"),
        ("circle-x", "xcircle"),
        ("inverted triangle", "triangle-down"),
        ("slashed", "slashed1"),
        ("back slashed", "slashed2"),
        ("do", "do"),
        ("re", "re"),
        ("mi", "mi"),
        ("fa", "fa"),
        ("fa up", "fa"),
        ("so", "sol"),
        ("la", "la"),
        ("ti", "ti"),
    ])
    func valueMapsToMuseScoreHeadGroup(value: String, token: String) throws {
        #expect(try firstNote(noteXML: pitched(notehead: "<notehead>\(value)</notehead>")).headType == token)
    }

    /// A normal head is the default, and so is a shape MuseScore has no group for — it logs the value and keeps a
    /// normal head.
    @Test(arguments: ["normal", "square", "circle dot", "other", ""])
    func normalAndUnmappedValuesKeepTheDefaultHead(value: String) throws {
        #expect(try firstNote(noteXML: pitched(notehead: "<notehead>\(value)</notehead>")).headType == nil)
    }

    @Test func noNoteheadKeepsTheDefaultHead() throws {
        #expect(try firstNote(noteXML: pitched(notehead: "")).headType == nil)
    }

    /// The shape and the parentheses sit on the same element and are independent.
    @Test func parenthesesDoNotHideTheShape() throws {
        let note = try firstNote(noteXML: pitched(notehead: "<notehead parentheses=\"yes\">diamond</notehead>"))
        #expect(note.headType == "diamond")
        #expect(note.parentheses == .both)
    }

    /// The case the report was about: an unpitched open hi-hat in a drum part.
    @Test func unpitchedNoteKeepsItsShape() throws {
        let note = try firstNote(noteXML: """
        <note>
          <unpitched><display-step>G</display-step><display-octave>5</display-octave></unpitched>
          <duration>4</duration><instrument id="P1-I47"/><voice>1</voice><type>whole</type>
          <notehead>circle-x</notehead>
        </note>
        """)
        #expect(note.headType == "xcircle")
        #expect(NoteheadGlyph.codepoint(duration: .whole, headType: note.headType, stemUp: true)
            == SMuFLCodepoint.noteheadCircleXWhole)
    }

    /// A note folded into the chord before it, and a grace note, are decoded by the same path.
    @Test func chordAndGraceNotesKeepTheirShapes() throws {
        let score = try parse(notesXML: """
        <note>
          <grace/><pitch><step>D</step><octave>5</octave></pitch><voice>1</voice><type>eighth</type>
          <notehead>x</notehead>
        </note>
        <note>
          <pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><voice>1</voice><type>whole</type>
        </note>
        <note>
          <chord/><pitch><step>E</step><octave>5</octave></pitch><duration>4</duration><voice>1</voice>
          <type>whole</type><notehead>circle-x</notehead>
        </note>
        """)
        let chord = try #require(chords(in: score).first)
        #expect(chord.notes.map(\.headType) == [nil, "xcircle"])
        #expect(chord.graceNotesBefore.flatMap(\.notes).map(\.headType) == ["cross"])
    }

    /// What folino keeps of an imported MusicXML file is the MSCX it saves, so the shape has to reach that too.
    @Test func shapeSurvivesTheMSCXRoundTrip() throws {
        let score = try parse(notesXML: pitched(notehead: "<notehead>circle-x</notehead>"))
        let reread = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(chords(in: reread).first?.notes.first?.headType == "xcircle")
    }

    // MARK: - Fixture

    private func pitched(notehead: String) -> String {
        """
        <note>
          <pitch><step>C</step><octave>5</octave></pitch>
          <duration>4</duration><voice>1</voice><type>whole</type>
          \(notehead)
        </note>
        """
    }

    private func parse(notesXML: String) throws -> Score {
        try MusicXMLParser.parse(Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              \(notesXML)
            </measure>
          </part>
        </score-partwise>
        """.utf8))
    }

    private func chords(in score: Score) -> [Chord] {
        score.parts[0].staves[0].measures[0].voices[0].elements.compactMap {
            if case let .chord(chord) = $0 { chord } else { nil }
        }
    }

    private func firstNote(noteXML: String) throws -> Note {
        try #require(chords(in: parse(notesXML: noteXML)).first?.notes.first)
    }
}
