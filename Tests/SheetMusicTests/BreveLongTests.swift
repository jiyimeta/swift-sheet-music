import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// MuseScore's breve and long (`V_BREVE` / `V_LONG`, `<durationType>breve</durationType>`). This package had no value
/// for either, so a file holding one did not import at all (`mscx.chord.invalidDurationType`), and MusicXML read
/// `<type>breve</type>` as a whole note — half its length.
struct BreveLongTests {
    /// One staff of `sigN`/2 bars, one bar per voice body.
    private static func mscx(sigN: Int, bars: [String]) -> Data {
        let measures = bars.enumerated().map { index, body in
            let timeSig = index == 0 ? "<TimeSig><sigN>\(sigN)</sigN><sigD>2</sigD></TimeSig>" : ""
            return "<Measure><voice>\(timeSig)\(body)</voice></Measure>"
        }.joined()
        return Data("""
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument><Channel/></Instrument>
            </Part>
            <Staff id="1">\(measures)</Staff>
          </Score>
        </museScore>
        """.utf8)
    }

    private static let c4 = "<Note><pitch>60</pitch><tpc>14</tpc></Note>"

    private static func elements(_ score: Score, measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements.filter {
            if case .chord = $0 { true } else { false }
        }
    }

    private static func duration(_ element: VoiceElement?) -> NoteDuration? {
        guard case let .chord(chord) = element else { return nil }
        return chord.duration
    }

    private static let breveBars = mscx(sigN: 4, bars: [
        "<Chord><durationType>breve</durationType>\(c4)</Chord>",
        "<Rest><durationType>breve</durationType></Rest>",
    ])

    @Test func aBreveChordAndRestImport() throws {
        let result = try MSCXParser.parseWithDiagnostics(Self.breveBars)
        #expect(Self.duration(Self.elements(result.score, measure: 0).first) == .breve)
        #expect(Self.duration(Self.elements(result.score, measure: 1).first) == .breve)
    }

    @Test func aBreveSoundsForTwoWholeNotes() throws {
        let score = try MSCXParser.parse(Self.breveBars)
        let midi = try MidiRenderer.render(score: score)
        let offs = midi.tracks.flatMap(\.events).compactMap { event -> Int? in
            switch event.event {
            case .noteOff(_, 60, _), .noteOn(_, 60, 0): event.tick
            default: nil
            }
        }
        // Released at the end of its bar — the renderer lets go a tick early — where a whole note would have stopped
        // half way through it.
        #expect(offs.count == 1)
        #expect(offs.allSatisfy { $0 > 7 * score.division && $0 <= 8 * score.division })
    }

    @Test func aLongAndADottedBreveImport() throws {
        let score = try MSCXParser.parse(Self.mscx(sigN: 8, bars: [
            "<Chord><durationType>long</durationType>\(Self.c4)</Chord>",
            "<Chord><dots>1</dots><durationType>breve</durationType>\(Self.c4)</Chord>"
                + "<Rest><durationType>whole</durationType></Rest>",
        ]))
        #expect(Self.duration(Self.elements(score, measure: 0).first) == .long)
        let dotted = try #require(Self.duration(Self.elements(score, measure: 1).first))
        #expect(dotted.asFraction == Fraction(numerator: 3, denominator: 1))
        // Engraved as a breve with a dot, not the whole note a power-of-two denominator would read it as. A rest of
        // that length stays a whole rest: it is also a three-bar multi-measure rest's body.
        #expect(DurationInterpretation.splitNote(dotted) == (base: .breve, dots: 1))
        #expect(DurationInterpretation.split(dotted) == (base: .whole, dots: 0))
    }

    @Test func theWriterSpellsThemAsMuseScoreDoes() throws {
        let score = try MSCXParser.parse(Self.mscx(sigN: 8, bars: [
            "<Chord><durationType>long</durationType>\(Self.c4)</Chord>",
            "<Chord><dots>1</dots><durationType>breve</durationType>\(Self.c4)</Chord>"
                + "<Rest><durationType>whole</durationType></Rest>",
            "<Rest><durationType>breve</durationType></Rest><Rest><durationType>breve</durationType></Rest>",
        ]))
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        let squeezed = xml.filter { !$0.isWhitespace }
        #expect(squeezed.contains("<durationType>long</durationType>"))
        #expect(squeezed.contains("<dots>1</dots><durationType>breve</durationType>"))
        #expect(squeezed.components(separatedBy: "<durationType>breve</durationType>").count - 1 == 3)

        let reread = try MSCXParser.parse(Data(xml.utf8))
        for measure in 0 ..< 3 {
            #expect(
                Self.elements(reread, measure: measure).map(Self.duration)
                    == Self.elements(score, measure: measure).map(Self.duration),
            )
        }
    }

    @Test func musicXMLReadsABreveAsTwoWholeNotes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="3.1">
          <part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
          <part id="P1"><measure number="1">
            <attributes>
              <divisions>1</divisions>
              <time><beats>4</beats><beat-type>2</beat-type></time>
            </attributes>
            <note><pitch><step>C</step><octave>4</octave></pitch><duration>8</duration><type>breve</type></note>
          </measure></part>
        </score-partwise>
        """
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        #expect(Self.duration(Self.elements(score, measure: 0).first) == .breve)
    }

    @Test func theyDrawWithTheirOwnGlyphs() {
        #expect(NoteheadGlyph.codepoint(duration: .breve, headType: nil, stemUp: true)
            == SMuFLCodepoint.noteheadDoubleWhole)
        // A long shares the breve's head (and adds a stem, `TDuration::hasStem`).
        #expect(NoteheadGlyph.codepoint(duration: .long, headType: nil, stemUp: true)
            == SMuFLCodepoint.noteheadDoubleWhole)
        #expect(RestGlyph.codepoint(duration: .breve) == SMuFLCodepoint.restDoubleWhole)
        #expect(RestGlyph.codepoint(duration: .breve, hasLegerLine: true) == SMuFLCodepoint.restDoubleWholeLegerLine)
        #expect(RestGlyph.codepoint(duration: .long) == SMuFLCodepoint.restLonga)
    }
}
