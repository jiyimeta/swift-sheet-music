import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// `<ChordLine>` is MuseScore's jazz/brass inflection element — fall,
/// doit, plop, scoop, plus their straight ("slide out/in") and wavy
/// ("rough") palette variants.
@Suite("ChordLine MSCX round-trip")
struct ChordLineRoundTripTests {
    static func parse(_ xml: String) throws -> Score {
        try MSCXParser.parse(Data(xml.utf8))
    }

    /// Minimal score whose single chord carries `chordLineXML` verbatim.
    /// `noteExtra` lets a test nest the element inside the `<Note>`
    /// instead, which is what MuseScore writes for a note-attached line.
    static func mscx(chordLineXML: String = "", noteExtra: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Chord><durationType>quarter</durationType>
                    \(chordLineXML)
                    <Note><pitch>60</pitch><tpc>14</tpc>\(noteExtra)</Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    static func firstChord(_ score: Score) throws -> Chord {
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .chord(chord) = voice.elements[0] else {
            throw TestFailure.notAChord
        }
        return chord
    }

    enum TestFailure: Error { case notAChord }

    // MARK: - Decode

    @Test("decodes all four subtypes")
    func decodesAllFourSubtypes() throws {
        let cases: [(subtype: Int, expected: ChordLine.Kind)] = [
            (1, .fall), (2, .doit), (3, .plop), (4, .scoop),
        ]
        for (subtype, expected) in cases {
            let score = try Self.parse(Self.mscx(
                chordLineXML: "<ChordLine><subtype>\(subtype)</subtype></ChordLine>",
            ))
            let chord = try Self.firstChord(score)
            #expect(chord.chordLines.count == 1)
            #expect(chord.chordLines.first?.kind == expected)
        }
    }

    /// Defaults per `ChordLine::propertyDefault`: not straight, not
    /// wavy, plays, zero drag lengths, no user path.
    @Test("bare <ChordLine> decodes to MuseScore's property defaults")
    func decodesDefaults() throws {
        let score = try Self.parse(Self.mscx(
            chordLineXML: "<ChordLine><subtype>1</subtype></ChordLine>",
        ))
        let line = try #require(try Self.firstChord(score).chordLines.first)
        #expect(line.isStraight == false)
        #expect(line.isWavy == false)
        #expect(line.plays == true)
        #expect(line.lengthX == 0)
        #expect(line.lengthY == 0)
        #expect(line.hasUserPath == false)
        #expect(line.noteIndex == nil)
    }

    @Test("decodes straight / wavy / play / length fields")
    func decodesAllFields() throws {
        let score = try Self.parse(Self.mscx(chordLineXML: """
        <ChordLine>
          <subtype>2</subtype>
          <straight>1</straight>
          <wavy>1</wavy>
          <play>0</play>
          <lengthX>1.5</lengthX>
          <lengthY>-2.25</lengthY>
        </ChordLine>
        """))
        let line = try #require(try Self.firstChord(score).chordLines.first)
        #expect(line.kind == .doit)
        #expect(line.isStraight)
        #expect(line.isWavy)
        #expect(line.plays == false)
        #expect(line.lengthX == 1.5)
        #expect(line.lengthY == -2.25)
    }

    /// The one-sided geometry predicates MuseScore's layout keys off.
    @Test("side predicates match ChordLine::isToTheLeft / isBelow")
    func sidePredicates() {
        #expect(ChordLine(kind: .fall).isToTheLeft == false)
        #expect(ChordLine(kind: .doit).isToTheLeft == false)
        #expect(ChordLine(kind: .plop).isToTheLeft == true)
        #expect(ChordLine(kind: .scoop).isToTheLeft == true)

        #expect(ChordLine(kind: .fall).isBelow == true)
        #expect(ChordLine(kind: .scoop).isBelow == true)
        #expect(ChordLine(kind: .doit).isBelow == false)
        #expect(ChordLine(kind: .plop).isBelow == false)
    }

    @Test("decodes a user-edited <Path> in spatium units")
    func decodesUserPath() throws {
        let score = try Self.parse(Self.mscx(chordLineXML: """
        <ChordLine>
          <subtype>1</subtype>
          <Path>
            <Element type="0" x="0" y="0"/>
            <Element type="2" x="0.6" y="0"/>
            <Element type="3" x="1.2" y="0.5"/>
            <Element type="3" x="1.2" y="1"/>
          </Path>
        </ChordLine>
        """))
        let line = try #require(try Self.firstChord(score).chordLines.first)
        #expect(line.hasUserPath)
        #expect(line.path.count == 4)
        #expect(line.path[0].kind == .moveTo)
        #expect(line.path[1].kind == .curveTo)
        #expect(line.path[1].x == 0.6)
        #expect(line.path[3].kind == .curveToData)
        #expect(line.path[3].y == 1)
    }

    /// MuseScore nests the element inside `<Note>` when the user bound
    /// it to one note of the chord (`ChordLine::setNote`).
    @Test("decodes a note-attached <ChordLine> with its note index")
    func decodesNoteAttached() throws {
        let score = try Self.parse(Self.mscx(
            noteExtra: "<ChordLine><subtype>4</subtype></ChordLine>",
        ))
        let chord = try Self.firstChord(score)
        #expect(chord.chordLines.count == 1)
        #expect(chord.chordLines.first?.kind == .scoop)
        #expect(chord.chordLines.first?.noteIndex == 0)
    }

    @Test("a chord may carry several chord lines")
    func decodesMultiple() throws {
        let score = try Self.parse(Self.mscx(
            chordLineXML: """
            <ChordLine><subtype>4</subtype></ChordLine>
            <ChordLine><subtype>1</subtype></ChordLine>
            """,
        ))
        let chord = try Self.firstChord(score)
        #expect(chord.chordLines.map(\.kind) == [.scoop, .fall])
    }

    // MARK: - Diagnostics

    @Test("unknown <subtype> warns and drops the element")
    func unknownSubtypeWarnsAndDrops() throws {
        for subtype in ["0", "9", "", "bogus"] {
            let collector = MSCXDiagnosticCollector()
            let score = try MSCXParserContext.$collector.withValue(collector) {
                try Self.parse(Self.mscx(
                    chordLineXML: "<ChordLine><subtype>\(subtype)</subtype></ChordLine>",
                ))
            }
            #expect(try Self.firstChord(score).chordLines.isEmpty)
            #expect(collector.entries.contains {
                $0.code == "mscx.chordLine.unknownSubtype"
            })
        }
    }

    @Test("a valid <ChordLine> produces no diagnostics")
    func validSubtypeIsSilent() throws {
        let collector = MSCXDiagnosticCollector()
        _ = try MSCXParserContext.$collector.withValue(collector) {
            try Self.parse(Self.mscx(
                chordLineXML: "<ChordLine><subtype>3</subtype></ChordLine>",
            ))
        }
        #expect(collector.entries.isEmpty)
    }

    // MARK: - Encode

    @Test("encode -> decode preserves every field")
    func encodeDecodeRoundTrip() throws {
        let score = try Self.parse(Self.mscx(chordLineXML: """
        <ChordLine>
          <subtype>3</subtype>
          <straight>1</straight>
          <wavy>1</wavy>
          <play>0</play>
          <lengthX>1.5</lengthX>
          <lengthY>-2</lengthY>
          <Path>
            <Element type="0" x="0" y="0"/>
            <Element type="1" x="-1.2" y="-1"/>
          </Path>
        </ChordLine>
        """))
        let original = try #require(try Self.firstChord(score).chordLines.first)

        let written = try MSCXEncoder.encode(score)
        let reparsed = try Self.parse(#require(String(data: written, encoding: .utf8)))
        let roundTripped = try #require(try Self.firstChord(reparsed).chordLines.first)

        #expect(roundTripped == original)
    }

    /// Defaults must not be written out — MuseScore's `writeProperty`
    /// omits a tag whose value equals the property default, and the
    /// lengths use `xml.tag(name, value, 0.0)`.
    @Test("encode omits tags whose value is the property default")
    func encodeOmitsDefaults() throws {
        let score = try Self.parse(Self.mscx(
            chordLineXML: "<ChordLine><subtype>2</subtype></ChordLine>",
        ))
        let written = try #require(
            try String(data: MSCXEncoder.encode(score), encoding: .utf8),
        )
        #expect(written.contains("<ChordLine>"))
        #expect(written.contains("<subtype>2</subtype>"))
        #expect(!written.contains("<straight>"))
        #expect(!written.contains("<wavy>"))
        #expect(!written.contains("<play>"))
        #expect(!written.contains("<lengthX>"))
        #expect(!written.contains("<lengthY>"))
        #expect(!written.contains("<Path>"))
    }

    /// A note-attached line must be written back inside its `<Note>`,
    /// not promoted to the chord level.
    @Test("encode writes a note-attached line back inside <Note>")
    func encodeKeepsNoteAttachment() throws {
        let score = try Self.parse(Self.mscx(
            noteExtra: "<ChordLine><subtype>1</subtype></ChordLine>",
        ))
        let written = try #require(
            try String(data: MSCXEncoder.encode(score), encoding: .utf8),
        )
        let noteStart = try #require(written.range(of: "<Note>"))
        let noteEnd = try #require(written.range(of: "</Note>"))
        let noteBody = written[noteStart.upperBound ..< noteEnd.lowerBound]
        #expect(noteBody.contains("<ChordLine>"))

        let reparsed = try Self.parse(written)
        #expect(try Self.firstChord(reparsed).chordLines.first?.noteIndex == 0)
    }
}
