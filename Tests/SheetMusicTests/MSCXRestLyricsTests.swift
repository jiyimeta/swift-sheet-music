import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A syllable under a rest. MuseScore anchors lyrics to any `ChordRest`, so a `<Rest>` carries `<Lyrics>` exactly as a
/// `<Chord>` does — read by `TRead::readProperties(ChordRest*)` and written by `TWrite::writeProperties(const
/// ChordRest*)` right after `<durationType>` / `<duration>`.
///
/// Reported 2026-11-05: a spoken 「でもね、」 under a full-measure rest in a medley never showed. The rest decoder left
/// the `<Lyrics>` as preserved markup, so the score kept it on save but nothing drew it.
@Suite("MSCX lyrics on rests")
struct MSCXRestLyricsTests {
    @Test("A full-measure rest's <Lyrics> decodes into the rest's lyrics")
    func decodesMeasureRestLyric() throws {
        let score = try MSCXParser.parse(Data(Self.document(rest: """
        <Rest>
          <durationType>measure</durationType>
          <duration>4/4</duration>
          <Lyrics>
            <offset x="-5.0251" y="2.12607"/>
            <text>でもね、</text>
          </Lyrics>
        </Rest>
        """).utf8))
        let rest = try #require(Self.firstChord(in: score))
        #expect(rest.notes.isEmpty)
        let lyric = try #require(rest.lyrics.first)
        #expect(rest.lyrics.count == 1)
        #expect(lyric.text == "でもね、")
        #expect(lyric.elementProperties.offset?.x == -5.0251)
        // Consumed, not kept as preserved markup — or the encoder would write it a second time.
        #expect(!rest.preservedMarkup.contains { $0.name == "Lyrics" })
    }

    @Test("A typed rest's verses decode by <no>, padded like a chord's")
    func decodesTypedRestVerses() throws {
        let score = try MSCXParser.parse(Data(Self.document(rest: """
        <Rest>
          <durationType>whole</durationType>
          <Lyrics><no>1</no><syllabic>begin</syllabic><text>la</text></Lyrics>
        </Rest>
        """).utf8))
        let rest = try #require(Self.firstChord(in: score))
        #expect(rest.lyrics.map(\.text) == ["", "la"])
        #expect(rest.lyrics.last?.syllabic == .begin)
    }

    @Test("A rest's lyric is written once, in MuseScore's slot after the duration", arguments: [
        MSCXVersion.v3, .v4,
    ])
    func encodesRestLyric(version: MSCXVersion) throws {
        let rest = Chord(
            duration: .measure,
            notes: [],
            lyrics: [Lyric(text: "でもね、", verse: 0)],
        )
        let node = rest.encodeAsRest(
            eid: .invalid, options: .init(targetVersion: version), in: Fraction(numerator: 4, denominator: 4),
        )
        let names = node.children.map(\.name)
        #expect(names.filter { $0 == "Lyrics" }.count == 1)
        let lyricsIndex = try #require(names.firstIndex(of: "Lyrics"))
        let durationIndex = try #require(names.firstIndex(of: "durationType"))
        #expect(durationIndex < lyricsIndex)
        #expect(node.first("Lyrics")?.first("text")?.text == "でもね、")
    }

    @Test("A verse-padding placeholder on a rest is not written")
    func skipsPlaceholder() {
        let rest = Chord(
            duration: .whole,
            notes: [],
            lyrics: [Lyric(text: "", verse: 0), Lyric(text: "la", verse: 1)],
        )
        let lyrics = rest.encodeAsRest(eid: .invalid).children.filter { $0.name == "Lyrics" }
        #expect(lyrics.count == 1)
        #expect(lyrics.first?.first("no")?.text == "1")
    }

    @Test("A rest's lyric survives a v4 round trip, once")
    func v4RoundTripKeepsRestLyric() throws {
        let source = try MSCXParser.parse(Data(Self.document(rest: """
        <Rest>
          <durationType>measure</durationType>
          <duration>4/4</duration>
          <Lyrics><text>でもね、</text></Lyrics>
        </Rest>
        """).utf8))
        let bytes = try MSCXEncoder.encode(source, options: .init(targetVersion: .v4))
        let tree = try XMLTreeParser.parse(bytes)
        #expect(Self.count("Lyrics", in: tree) == 1)

        let reread = try MSCXParser.parse(bytes)
        #expect(Self.firstChord(in: reread)?.lyrics.map(\.text) == ["でもね、"])
    }

    // MARK: - Helpers

    /// One 4/4 bar holding `rest` alone.
    private static func document(rest: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.70">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="voice"><longName>Voice</longName></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
                  \(rest)
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    private static func firstChord(in score: Score) -> Chord? {
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            if case let .chord(chord) = element { return chord }
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func count(_ name: String, in node: XMLTreeNode) -> Int {
        (node.name == name ? 1 : 0) + node.children.reduce(0) { $0 + count(name, in: $1) }
    }
}
