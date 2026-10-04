import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// `<notations><articulations>` and the articulation-like marks under `<technical>` become `Chord.articulations`, by
/// MuseScore's own table (`convertArticulationToSymId`, `importmusicxmlpass2.cpp`). They were dropped outright: a
/// MusicXML file's staccatos, accents and bow marks neither showed nor played.
@Suite("Articulation MusicXML import")
struct ArticulationImportTests {
    /// One 4/4 bar: a C4 quarter carrying `notations`, then — when `chordToneNotations` is given — an E4 `<chord/>`
    /// tone carrying those, then a D4 quarter with nothing.
    static func score(notations: String, chordToneNotations: String? = nil) throws -> Score {
        let chordTone = chordToneNotations.map { tone in
            """
            <note>
              <chord/>
              <pitch><step>E</step><octave>4</octave></pitch>
              <duration>480</duration><voice>1</voice><type>quarter</type>
              <notations>\(tone)</notations>
            </note>
            """
        } ?? ""
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
              <note>
                <pitch><step>C</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
                <notations>\(notations)</notations>
              </note>
              \(chordTone)
              <note>
                <pitch><step>D</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        return try MusicXMLParser.parse(Data(xml.utf8))
    }

    static func articulations(of score: Score, chord index: Int = 0) -> [ChordArticulation] {
        let chords = score.parts[0].staves[0].measures[0].voices[0].elements.compactMap { element -> Chord? in
            if case let .chord(chord) = element { return chord }
            return nil
        }
        return chords.indices.contains(index) ? chords[index].articulations : []
    }

    @Test("each MusicXML articulation maps to MuseScore's mark", arguments: [
        ("<articulations><accent/></articulations>", ChordArticulation.Kind.accent),
        ("<articulations><strong-accent/></articulations>", .marcato),
        ("<articulations><staccato/></articulations>", .staccato),
        ("<articulations><tenuto/></articulations>", .tenuto),
        ("<articulations><detached-legato/></articulations>", .tenutoStaccato),
        ("<articulations><staccatissimo/></articulations>", .staccatissimo),
        ("<articulations><spiccato/></articulations>", .staccatissimoStroke),
        ("<articulations><stress/></articulations>", .stress),
        ("<articulations><unstress/></articulations>", .unstress),
        ("<articulations><soft-accent/></articulations>", .softAccent),
        ("<technical><up-bow/></technical>", .upBow),
        ("<technical><down-bow/></technical>", .downBow),
        ("<technical><stopped/></technical>", .muteClosed),
        ("<technical><open/></technical>", .muteOpen),
        ("<technical><open-string/></technical>", .muteOpen),
    ] as [(String, ChordArticulation.Kind)])
    func mapsEachMark(notations: String, kind: ChordArticulation.Kind) throws {
        let score = try Self.score(notations: notations)
        #expect(Self.articulations(of: score).map(\.kind) == [kind])
        #expect(Self.articulations(of: score, chord: 1).isEmpty)
    }

    /// `placement` names the side; a `strong-accent` with only `type="up"` / `"down"` means the same (MuseScore:
    /// "assume type up/down without explicit placement implies placement above/below"). A bow mark has one form.
    @Test("placement and type become the anchor")
    func placementBecomesTheAnchor() throws {
        let score = try Self.score(notations: """
        <articulations><staccato placement="below"/><strong-accent type="up"/><tenuto/></articulations>
        <technical><up-bow placement="below"/></technical>
        """)
        #expect(Self.articulations(of: score) == [
            ChordArticulation(kind: .staccato, anchor: .below),
            ChordArticulation(kind: .marcato, anchor: .above),
            ChordArticulation(kind: .tenuto, anchor: nil),
            ChordArticulation(kind: .upBow, anchor: nil),
        ])
    }

    /// A chord's tones often each repeat the chord's marks. They belong to the one chord, once each.
    @Test("marks on a <chord/> tone join the host chord without duplicates")
    func chordToneMarksJoinTheHost() throws {
        let score = try Self.score(
            notations: "<articulations><staccato/></articulations>",
            chordToneNotations: "<articulations><staccato/><accent/></articulations>",
        )
        #expect(Self.articulations(of: score).map(\.kind) == [.staccato, .accent])
    }

    @Test("a technical element that is not a mark leaves the chord bare")
    func otherTechnicalIsIgnored() throws {
        let score = try Self.score(notations: "<technical><fingering>2</fingering><harmonic/></technical>")
        #expect(Self.articulations(of: score).isEmpty)
    }
}
