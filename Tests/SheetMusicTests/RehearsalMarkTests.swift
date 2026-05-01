import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
@testable import SheetMusicXMLTools
import Testing

@Suite struct RehearsalMarkTests {
    // MARK: - MSCX decoder

    @Test func mscxDecodesPlainRehearsalMark() throws {
        let xml = """
        <voice>
          <RehearsalMark><text>A</text></RehearsalMark>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 2)
        guard case let .rehearsalMark(rm) = voice.elements[0] else {
            Issue.record("element 0 is not a rehearsal mark")
            return
        }
        #expect(rm.text == "A")
        // No <frameType> ⇒ default rectangle.
        #expect(rm.frame == .rectangle)
        #expect(rm.color == nil)
    }

    @Test func mscxDecodesFrameTypeAndOffset() throws {
        let xml = """
        <voice>
          <RehearsalMark>
            <text>1サビ</text>
            <frameType>1</frameType>
            <offset x="0.5" y="-1.2"/>
            <color r="200" g="80" b="40" a="255"/>
          </RehearsalMark>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        guard case let .rehearsalMark(rm) = voice.elements[0] else {
            Issue.record("element 0 is not a rehearsal mark")
            return
        }
        #expect(rm.text == "1サビ")
        #expect(rm.frame == .circle)
        #expect(rm.offsetX == 0.5)
        #expect(rm.offsetY == -1.2)
        #expect(rm.color?.red == 200)
        #expect(rm.color?.green == 80)
        #expect(rm.color?.blue == 40)
    }

    // MARK: - MIDI export

    @Test func midiRenderEmitsMarkerMetaForRehearsalMark() throws {
        // Minimal score: one measure with a rehearsal mark "A" before a
        // quarter note. Must surface as a MetaEvent.marker in track 0
        // at tick 0 (the rehearsal mark sits at the start of voice 0).
        let mark = RehearsalMark(text: "A")
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)]
        )
        let measure = Measure(voices: [Voice(elements: [
            .rehearsalMark(mark),
            .chord(chord),
        ]), ])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(id: "P1", instrument: Instrument(
            id: "voice",
            articulations: [InstrumentArticulation()]))
        let score = Score(
            division: 480, parts: [part], staves: [staff]
        )

        let file = try MidiRenderer.render(score: score)
        let markerEvents = file.tracks[0].events.compactMap { evt -> (Int, String)? in
            if case let .meta(.marker(text)) = evt.event {
                return (evt.tick, text)
            }
            return nil
        }
        #expect(markerEvents.count == 1)
        #expect(markerEvents.first?.0 == 0)
        #expect(markerEvents.first?.1 == "A")
    }

    @Test func midiWriterEncodesMarkerMetaEvent() throws {
        // SMF marker: 0xFF 06 <vlq-len> <text-bytes>.
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(
                    tick: 0,
                    event: .meta(.marker("AB"))
                ),
                TimedMidiEvent(tick: 0, event: .endOfTrack),
            ]),
        ])
        let bytes = try MidiWriter.write(file)
        // 14-byte MThd + 8-byte MTrk header = 22 bytes preamble.
        let trackBytes = Array(bytes.dropFirst(22))
        #expect(trackBytes[0] == 0x00) // delta
        #expect(trackBytes[1] == 0xFF) // meta
        #expect(trackBytes[2] == 0x06) // marker type
        #expect(trackBytes[3] == 0x02) // length
        #expect(trackBytes[4] == 0x41) // 'A'
        #expect(trackBytes[5] == 0x42) // 'B'
    }

    @Test func midiRenderSkipsEmptyRehearsalText() throws {
        // An empty `<text>` shouldn't emit a zero-length marker
        // (DAWs otherwise show a blank entry on the timeline).
        let mark = RehearsalMark(text: "")
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)]
        )
        let measure = Measure(voices: [Voice(elements: [
            .rehearsalMark(mark),
            .chord(chord),
        ]), ])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(id: "P1", instrument: Instrument(
            id: "voice",
            articulations: [InstrumentArticulation()]))
        let score = Score(
            division: 480, parts: [part], staves: [staff]
        )
        let file = try MidiRenderer.render(score: score)
        for evt in file.tracks[0].events {
            if case .meta(.marker) = evt.event {
                Issue.record("empty rehearsal mark produced a marker")
            }
        }
    }

    // MARK: - MusicXML import

    @Test func musicXMLImportsRehearsalDirection() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>X</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <direction placement="above">
                <direction-type>
                  <rehearsal enclosure="circle">A</rehearsal>
                </direction-type>
              </direction>
              <note>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration>
                <voice>1</voice>
                <type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let elements = score.staves[0].measures[0].voices[0].elements
        let marks = elements.compactMap { el -> RehearsalMark? in
            if case let .rehearsalMark(rm) = el { return rm }
            return nil
        }
        #expect(marks.count == 1)
        #expect(marks.first?.text == "A")
        #expect(marks.first?.frame == .circle)
    }

    @Test func musicXMLDefaultsEnclosureToRectangle() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>X</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <direction>
                <direction-type>
                  <rehearsal>B</rehearsal>
                </direction-type>
              </direction>
              <note>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration>
                <voice>1</voice>
                <type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let marks = score.staves[0].measures[0].voices[0].elements
            .compactMap { el -> RehearsalMark? in
                if case let .rehearsalMark(rm) = el { return rm }
                return nil
            }
        #expect(marks.first?.frame == .rectangle)
    }
}
