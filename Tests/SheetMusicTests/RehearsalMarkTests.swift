import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
@testable import SheetMusicXMLTools
import Testing

struct RehearsalMarkTests {
    // MARK: - MSCX decoder

    @Test func mscxDecodesPlainRehearsalMark() throws {
        let xml = """
        <voice>
          <RehearsalMark><text>A</text></RehearsalMark>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        </voice>
        """
        let result = try Voice.decodeWithSystemElements(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        // RehearsalMark is lifted to systemElements; the voice
        // keeps just the chord.
        #expect(result.voice.elements.count == 1)
        guard result.systemElements.count == 1,
              case let .rehearsalMark(rm) = result.systemElements[0].element
        else {
            Issue.record("expected one lifted RehearsalMark")
            return
        }
        #expect(rm.text == "A")
        // No <frameType> ⇒ default rectangle.
        #expect(rm.frame == TextFrameType.rectangle)
        #expect(rm.color == nil)
    }

    @Test func mscxDecodesFrameTypeAndOffset() throws {
        // `<frameType>2</frameType>` corresponds to `FrameType::CIRCLE`
        // per MuseScore's enum (NO_FRAME=0, SQUARE=1, CIRCLE=2).
        let xml = """
        <voice>
          <RehearsalMark>
            <text>1サビ</text>
            <frameType>2</frameType>
            <offset x="0.5" y="-1.2"/>
            <color r="200" g="80" b="40" a="255"/>
          </RehearsalMark>
        </voice>
        """
        let result = try Voice.decodeWithSystemElements(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        guard result.systemElements.count == 1,
              case let .rehearsalMark(rm) = result.systemElements[0].element
        else {
            Issue.record("expected one lifted RehearsalMark")
            return
        }
        #expect(rm.text == "1サビ")
        #expect(rm.frame == TextFrameType.circle)
        #expect(rm.offsetX == 0.5)
        #expect(rm.offsetY == -1.2)
        #expect(rm.color?.red == 200)
        #expect(rm.color?.green == 80)
        #expect(rm.color?.blue == 40)
    }

    // MARK: - MIDI export

    @Test func midiRenderEmitsMarkerMetaForRehearsalMark() throws {
        // Minimal score: one measure with a rehearsal mark "A" at
        // tick 0 of the score-level SystemMeasure, plus a quarter
        // note in the staff's voice. Must surface as a
        // MetaEvent.marker on track 0 at tick 0.
        let mark = RehearsalMark(text: "A")
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "voice",
                articulations: [InstrumentArticulation()],
            ),
            staves: [staff],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .rehearsalMark(mark),
                ),
            ])],
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
                    event: .meta(.marker("AB")),
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
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "voice",
                articulations: [InstrumentArticulation()],
            ),
            staves: [staff],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .rehearsalMark(mark),
                ),
            ])],
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
        let marks = score.systemMeasures.first?.elements
            .compactMap { positioned -> RehearsalMark? in
                if case let .rehearsalMark(rm) = positioned.element {
                    return rm
                }
                return nil
            } ?? []
        #expect(marks.count == 1)
        #expect(marks.first?.text == "A")
        #expect(marks.first?.frame == TextFrameType.circle)
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
        let marks = score.systemMeasures.first?.elements
            .compactMap { positioned -> RehearsalMark? in
                if case let .rehearsalMark(rm) = positioned.element {
                    return rm
                }
                return nil
            } ?? []
        #expect(marks.first?.frame == TextFrameType.rectangle)
    }

    private typealias F = DirectionFixtures

    private static func rehearsals(_ score: Score) -> [(position: MeasurePosition, mark: RehearsalMark)] {
        F.lane(score).compactMap { entry -> (position: MeasurePosition, mark: RehearsalMark)? in
            guard case let .rehearsalMark(mark) = entry.element else { return nil }
            return (entry.position, mark)
        }
    }

    private static func staffTexts(_ score: Score) -> [(position: MeasurePosition, text: StaffText)] {
        F.lane(score).compactMap { entry -> (position: MeasurePosition, text: StaffText)? in
            guard case let .staffText(text) = entry.element else { return nil }
            return (entry.position, text)
        }
    }

    @Test("a rehearsal mark sits at its real tick")
    func rehearsalAtItsRealTick() throws {
        let body = F.quarter("C") + F.quarter("D")
            + F.direction("<rehearsal>A</rehearsal>") + F.quarter("E") + F.quarter("F")
        let marks = try Self.rehearsals(F.score(measures: [body]))
        #expect(marks.count == 1)
        #expect(marks.first?.position == MeasurePosition(numerator: 1, denominator: 2))
        #expect(marks.first?.mark.text == "A")
    }

    @Test("words in a direction beat its rehearsal mark (P2:3564-3614)")
    func wordsBeatRehearsal() throws {
        let body = F.direction(F.words("Solo") + "</direction-type><direction-type><rehearsal>A</rehearsal>")
            + F.fourQuarters
        let score = try F.score(measures: [body])
        #expect(Self.rehearsals(score).isEmpty)
        #expect(Self.staffTexts(score).map(\.text.text) == ["Solo"])
    }

    /// MuseScore turns bold off explicitly — `<b></b>` before the text — unless the text already holds `<b>`
    /// (`P2:3608-3610`), so the mark draws regular, not in the style's bold.
    @Test("a rehearsal mark's text starts with MuseScore's empty <b></b> unless it is bold already")
    func rehearsalBoldOff() throws {
        func mark(_ rehearsal: String) throws -> RehearsalMark {
            let body = F.direction(rehearsal) + F.fourQuarters
            return try #require(try Self.rehearsals(F.score(measures: [body])).first).mark
        }
        let plain = try mark("<rehearsal>A</rehearsal>")
        #expect(plain.text == "A")
        #expect(plain.preservedTextMarkup == PreservedTextMarkup(xmlText: "<b></b>A"))
        let bold = try mark("<rehearsal font-weight=\"bold\">B</rehearsal>")
        #expect(bold.text == "B")
        #expect(bold.preservedTextMarkup == PreservedTextMarkup(xmlText: "<b>B</b>"))
    }

    /// MuseScore holds system elements back and adds them once the score is read (`P2:1040-1072`, `2122`), so at one
    /// tick a staff text comes before a rehearsal mark read ahead of it (the own fixture's bar 4, inference off).
    @Test("at one tick a staff text comes before a rehearsal mark read ahead of it")
    func rehearsalAfterStaffText() throws {
        let body = F.direction("<rehearsal>A</rehearsal>")
            + F.direction(F.words("cresc."), attributes: "placement=\"below\"") + F.fourQuarters
        let lane = try F.lane(F.score(measures: [body], infer: false))
        // Both sit on the one staff, so the staff key ties and the system-element rule decides.
        let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(lane.map(\.originalStaff) == [top, top])
        #expect(Self.kinds(lane) == ["staffText@0", "rehearsal@0"])
    }

    private static func kinds(_ lane: [PositionedSystemElement]) -> [String] {
        lane.map { entry -> String in
            let staff = entry.originalStaff.map { "@\($0.partIndex)" } ?? ""
            switch entry.element {
            case .rehearsalMark: return "rehearsal" + staff
            case .staffText: return "staffText" + staff
            case .tempo: return "tempo" + staff
            default: return "other" + staff
            }
        }
    }

    /// The MSCX reader builds a lane staff by staff and then sorts it by position (`MSCXDecoder+Staff`'s assembly), so
    /// at one tick the top staff's tempo comes before a lower part's staff text (testInferredTempoText2), while an
    /// earlier tick still comes first whatever its staff.
    @Test("across parts the lane is by position, then by staff, then a staff's texts before its system elements")
    func laneOrderAcrossParts() throws {
        let tempo = F.direction(F.words("Slow"), "<sound tempo=\"60\"/>", attributes: "placement=\"above\"")
        let atOnce = try F.lane(F.score(parts: [
            [tempo + F.fourQuarters],
            [F.direction(F.words("Use a slow stroke")) + F.fourQuarters],
        ], infer: false))
        #expect(Self.kinds(atOnce) == ["tempo@0", "staffText@1"])
        let rehearsalLater = F.quarter("C") + F.direction("<rehearsal>A</rehearsal>") + F.quarter("D") + F.half("E")
        let apart = try F.lane(F.score(parts: [
            [rehearsalLater],
            [F.direction(F.words("Use a slow stroke")) + F.fourQuarters],
        ], infer: false))
        #expect(Self.kinds(apart) == ["staffText@1", "rehearsal@0"])
    }
}
