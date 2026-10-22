import Foundation
import SheetMusicCore
import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// A MusicXML drum part names each drum's GM pitch through `<instrument id>` and spells where it sits with
/// `<display-step>` / `<display-octave>`. MuseScore keeps the second as the drumset's line for that pitch; this import
/// used to keep neither, so the layout — finding no line for a bass drum's 36 — placed the note as a pitched C2,
/// octaves below the staff.
struct MusicXMLDrumKitTests {
    /// MuseScore's own export of a drum kit, cut to five drums: four played, a crash cymbal declared but never played.
    @Test func everyDeclaredDrumJoinsTheKitWithThePlayedNotesLineHeadAndStem() throws {
        let part = try #require(parse(Self.kit).parts.first)
        let kit = part.instrument.drumset
        #expect(Set(kit.keys) == [36, 38, 42, 46, 49])
        #expect(kit[36] == DrumsetEntry(name: "Bass Drum 1", head: "normal", line: 7, voiceIndex: 0, stem: 2))
        #expect(kit[38] == DrumsetEntry(name: "Acoustic Snare", head: "normal", line: 3, voiceIndex: 0, stem: 1))
        #expect(kit[42] == DrumsetEntry(name: "Closed Hi-Hat", head: "cross", line: -1, voiceIndex: 0, stem: 1))
        #expect(kit[46] == DrumsetEntry(name: "Open Hi-Hat", head: "xcircle", line: -1, voiceIndex: 0, stem: 1))
    }

    /// No note says where the crash goes, so it takes the General MIDI kit's place and head under its own name.
    @Test func anUnplayedDrumTakesTheGeneralMIDIDefaults() throws {
        let kit = try #require(parse(Self.kit).parts.first).instrument.drumset
        #expect(kit[49] == DrumsetEntry(name: "Crash Cymbal", head: "cross", line: -2, voiceIndex: 0, stem: 1))
    }

    /// `drumLineMap` is what the layout reads: each drum now sits on the line its notes were written on.
    @Test func theLayoutFindsALineForEveryPlayedDrum() throws {
        let part = try #require(parse(Self.kit).parts.first)
        #expect(part.instrument.drumLineMap[36] == 7)
        #expect(part.instrument.drumLineMap[38] == 3)
        #expect(part.instrument.drumLineMap[42] == -1)
    }

    /// MuseScore turns a drum part's five-line staves into percussion staves (`setStaffTypePercussion`, which leaves
    /// other line counts alone); a saved file whose drum staff still reads `stdNormal` makes MuseScore ignore the
    /// kit's lines.
    @Test func theDrumStaffBecomesAPercussionStaff() throws {
        let staff = try #require(parse(Self.kit).parts.first?.staves.first)
        #expect(staff.group == GMPercussion.staffGroup)
        #expect(staff.staffType == GMPercussion.staffTypeName)
    }

    /// The last note of a drum decides its line and head, as `setDrumsetDefault` overwrites them note by note.
    @Test func theLastNoteOfADrumDecides() throws {
        let part = try #require(parse(Self.drum(notes: """
        \(Self.note(step: "C", octave: 5, instrument: "P1-I39"))
        \(Self.note(step: "D", octave: 5, instrument: "P1-I39", notehead: "x"))
        """)).parts.first)
        #expect(part.instrument.drumset[38]?.line == 2)
        #expect(part.instrument.drumset[38]?.head == "cross")
    }

    /// Without `<stem>` the stem follows the line, as MuseScore's drum palette needs a direction: down below the
    /// middle line, up from it.
    @Test func anAbsentStemFollowsTheLine() throws {
        let part = try #require(parse(Self.drum(notes: """
        \(Self.note(step: "F", octave: 4, instrument: "P1-I37", stem: nil))
        \(Self.note(step: "C", octave: 5, instrument: "P1-I39", stem: nil))
        """)).parts.first)
        #expect(part.instrument.drumset[36]?.stem == 2)
        #expect(part.instrument.drumset[38]?.stem == 1)
    }

    /// A one-line staff's line is written as the five-line staff's bottom line (`ExportMusicXml::unpitch2xml`).
    @Test func aOneLineStaffMeasuresFromItsLine() throws {
        let part = try #require(parse(Self.drum(
            notes: Self.note(step: "E", octave: 4, instrument: "P1-I39"),
            staffDetails: "<staff-details><staff-lines>1</staff-lines></staff-details>",
        )).parts.first)
        #expect(part.instrument.drumset[38]?.line == 0)
    }

    /// What folino keeps of an imported file is the MSCX it saves, which has to carry the kit for MuseScore and for
    /// the next read alike.
    @Test func theKitSurvivesTheMSCXRoundTrip() throws {
        let score = try parse(Self.kit)
        let reread = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(reread.parts.first?.instrument.drumset == score.parts.first?.instrument.drumset)
        #expect(reread.parts.first?.staves.first?.group == GMPercussion.staffGroup)
    }

    /// A pitched part is left as it was.
    @Test func aPitchedPartHasNoKit() throws {
        let part = try #require(parse(Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions><clef><sign>G</sign><line>2</line></clef></attributes>
              <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>whole</type></note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)).parts.first)
        #expect(part.instrument.drumset.isEmpty)
        #expect(part.staves.first?.group == "pitched")
    }

    // MARK: - Fixture

    private static let kit = drum(notes: """
    \(note(step: "F", octave: 4, instrument: "P1-I37", stem: "down"))
    \(note(step: "C", octave: 5, instrument: "P1-I39"))
    \(note(step: "G", octave: 5, instrument: "P1-I43", notehead: "x"))
    \(note(step: "G", octave: 5, instrument: "P1-I47", notehead: "circle-x"))
    """)

    private static func note(
        step: String, octave: Int, instrument: String, notehead: String? = nil, stem: String? = "up",
    ) -> String {
        """
        <note>
          <unpitched><display-step>\(step)</display-step><display-octave>\(octave)</display-octave></unpitched>
          <duration>1</duration><instrument id="\(instrument)"/><voice>1</voice><type>quarter</type>
          \(stem.map { "<stem>\($0)</stem>" } ?? "")\(notehead.map { "<notehead>\($0)</notehead>" } ?? "")
        </note>
        """
    }

    private static func drum(notes: String, staffDetails: String = "") -> Data {
        let drums = [
            ("P1-I37", "Bass Drum 1", 37), ("P1-I39", "Acoustic Snare", 39), ("P1-I43", "Closed Hi-Hat", 43),
            ("P1-I47", "Open Hi-Hat", 47), ("P1-I50", "Crash Cymbal", 50),
        ]
        let instruments = drums.map { id, name, _ in
            "<score-instrument id=\"\(id)\"><instrument-name>\(name)</instrument-name></score-instrument>"
        }.joined()
        let midi = drums.map { id, _, unpitched in
            "<midi-instrument id=\"\(id)\"><midi-channel>10</midi-channel><midi-unpitched>\(unpitched)</midi-unpitched>"
                + "</midi-instrument>"
        }.joined()
        return Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>Drumset</part-name>\(instruments)\(midi)</score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>percussion</sign><line>2</line></clef>
                \(staffDetails)
              </attributes>
              \(notes)
            </measure>
          </part>
        </score-partwise>
        """.utf8)
    }

    private func parse(_ data: Data) throws -> Score {
        try MusicXMLParser.parse(data)
    }
}
