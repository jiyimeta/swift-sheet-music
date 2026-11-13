import Foundation
import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// `<notations><technical><fingering>` decoding (issue #25).
struct MusicXMLFingeringTests {
    private func firstNoteFingerings(technicalXML: String) throws -> [Fingering] {
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
                <notations>\(technicalXML)</notations>
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        for element in elements {
            if case let .chord(chord) = element { return chord.notes[0].fingerings }
        }
        return []
    }

    @Test func plainFingeringDecodes() throws {
        let fingerings = try firstNoteFingerings(
            technicalXML: "<technical><fingering>3</fingering></technical>")
        #expect(fingerings.map(\.text) == ["3"])
        #expect(fingerings.map(\.role) == [.fingering])
    }

    @Test func multipleFingeringsKeepDocumentOrder() throws {
        // Double-stop fingering: several <fingering> siblings on one note.
        let fingerings = try firstNoteFingerings(
            technicalXML: """
            <technical>
              <fingering>1</fingering>
              <fingering>3</fingering>
            </technical>
            """)
        #expect(fingerings.map(\.text) == ["1", "3"])
        #expect(fingerings.allSatisfy { $0.role == .fingering })
    }

    @Test func substitutionFingeringKeptAsOther() throws {
        let fingerings = try firstNoteFingerings(
            technicalXML: "<technical><fingering substitute=\"yes\">2</fingering></technical>")
        #expect(fingerings.map(\.text) == ["2"])
        #expect(fingerings[0].role == .other(style: "substitute"))
    }

    @Test func multiDigitAndRangeTextKeptVerbatim() throws {
        // Spec allows text like "2-4" (substitution) — kept verbatim.
        let fingerings = try firstNoteFingerings(
            technicalXML: "<technical><fingering>2-4</fingering></technical>")
        #expect(fingerings.map(\.text) == ["2-4"])
    }

    @Test func noTechnicalOrNotationsDecodesToEmpty() throws {
        #expect(try firstNoteFingerings(technicalXML: "") == [])
        #expect(try firstNoteFingerings(
            technicalXML: "<technical><up-bow>heavy</up-bow></technical>") == [])
    }
}
