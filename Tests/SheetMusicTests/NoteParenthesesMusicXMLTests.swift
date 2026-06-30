import Foundation
import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

struct NoteParenthesesMusicXMLTests {
    private func firstNoteParens(noteheadXML: String) throws -> NoteParentheses {
        let xml = Data("""
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
              <note>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration><voice>1</voice><type>whole</type>
                \(noteheadXML)
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        for element in elements {
            if case let .chord(chord) = element { return chord.notes[0].parentheses }
        }
        return .none
    }

    @Test func parenthesesYesDecodesToBoth() throws {
        #expect(try firstNoteParens(noteheadXML: "<notehead parentheses=\"yes\">normal</notehead>") == .both)
    }

    @Test func noNoteheadDefaultsToNone() throws {
        #expect(try firstNoteParens(noteheadXML: "") == .none)
    }

    @Test func noteheadWithoutParenthesesDefaultsToNone() throws {
        #expect(try firstNoteParens(noteheadXML: "<notehead>normal</notehead>") == .none)
    }
}
