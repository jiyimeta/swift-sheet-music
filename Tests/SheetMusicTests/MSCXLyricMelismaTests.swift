import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A melisma's length on the wire. MuseScore 4 writes it only as `<ticks_f>`, a fraction of a whole note
/// (`Pid::LYRIC_TICKS`, `TWrite::write(const Lyrics*)`); MuseScore 3.6 wrote `<ticks>` (integer ticks) beside it; and
/// MuseScore 4.6's reader no longer accepts `<ticks>` at all (`read460::TRead::readProperties(Lyrics*)`).
@Suite("MSCX lyric melisma")
struct MSCXLyricMelismaTests {
    /// The shape of the report: a 16th's syllable held over the quarter after it, as MuseScore 4.7 saves it.
    @Test("A MuseScore 4 <ticks_f> melisma decodes into the syllable's ticks")
    func decodesFractionalMelisma() throws {
        let score = try MSCXParser.parse(Data(Self.document(
            division: 480,
            lyrics: "<Lyrics><ticks_f>1/16</ticks_f><text>よ</text></Lyrics>",
        ).utf8))
        let lyric = try #require(Self.firstChord(in: score)?.lyrics.first)
        #expect(lyric.text == "よ")
        #expect(lyric.ticks == 120)
        // Consumed, not kept as preserved markup — or the encoder would write it a second time.
        #expect(!lyric.preservedMarkup.contains { $0.name == "ticks_f" })
    }

    @Test("A <ticks_f> melisma is measured at the file's division")
    func fractionalMelismaUsesTheFileDivision() throws {
        let score = try MSCXParser.parse(Data(Self.document(
            division: 960,
            lyrics: "<Lyrics><ticks_f>3/8</ticks_f><text>Ah</text></Lyrics>",
        ).utf8))
        #expect(Self.firstChord(in: score)?.lyrics.first?.ticks == 1440)
    }

    @Test("A MuseScore 3 <ticks> melisma still decodes")
    func decodesIntegerTicks() throws {
        let score = try MSCXParser.parse(Data(Self.document(
            division: 480,
            lyrics: "<Lyrics><ticks>480</ticks><text>la</text></Lyrics>",
        ).utf8))
        #expect(Self.firstChord(in: score)?.lyrics.first?.ticks == 480)
    }

    /// folino up to ssm 4.14.1 kept an unread `<ticks_f>` as preserved markup and wrote it back beside the model's own
    /// `<ticks>`, so a melisma edited after import was saved as a fresh `<ticks>` next to the stale fraction. MuseScore
    /// 3.6 writes the two with the same value, so preferring `<ticks>` costs nothing there.
    @Test("<ticks> wins over a <ticks_f> written beside it")
    func integerTicksWinOverFraction() throws {
        let score = try MSCXParser.parse(Data(Self.document(
            division: 480,
            lyrics: "<Lyrics><ticks>240</ticks><ticks_f>1/16</ticks_f><text>la</text></Lyrics>",
        ).utf8))
        #expect(Self.firstChord(in: score)?.lyrics.first?.ticks == 240)
    }

    @Test("v4 writes the melisma as <ticks_f>; v3 keeps <ticks>")
    func encodesMelismaPerTargetVersion() throws {
        let chord = Chord(
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 66, tpc: 20)]),
            lyrics: [Lyric(text: "よ", ticks: 120, verse: 0)],
        )
        let v4 = try #require(
            chord.encodeAsChord(eid: .invalid, options: .init(targetVersion: .v4)).first("Lyrics"),
        )
        #expect(v4.first("ticks_f")?.text == "1/16")
        #expect(!v4.children.contains { $0.name == "ticks" })

        let v3 = try #require(
            chord.encodeAsChord(eid: .invalid, options: .init(targetVersion: .v3)).first("Lyrics"),
        )
        #expect(v3.first("ticks")?.text == "120")
    }

    @Test("A v4 round trip keeps the melisma at a non-480 division")
    func v4RoundTripKeepsMelisma() throws {
        let source = try MSCXParser.parse(Data(Self.document(
            division: 960,
            lyrics: "<Lyrics><ticks_f>3/8</ticks_f><text>Ah</text></Lyrics>",
        ).utf8))
        let bytes = try MSCXEncoder.encode(source, options: .init(targetVersion: .v4))
        let lyricsNode = try #require(Self.firstLyricsNode(in: XMLTreeParser.parse(bytes)))
        #expect(lyricsNode.first("ticks_f")?.text == "3/8")

        let reread = try MSCXParser.parse(bytes)
        #expect(Self.firstChord(in: reread)?.lyrics.first?.ticks == 1440)
    }

    // MARK: - Helpers

    /// One 3/8 bar: a dotted quarter carrying `lyrics`, then nothing — the melisma's end chord is irrelevant to how
    /// its length is read.
    private static func document(division: Int, lyrics: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.70">
          <Score>
            <Division>\(division)</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="voice"><longName>Voice</longName></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <TimeSig><sigN>3</sigN><sigD>8</sigD></TimeSig>
                  <Chord>
                    <durationType>quarter</durationType>
                    <dots>1</dots>
                    \(lyrics)
                    <Note><pitch>66</pitch><tpc>20</tpc></Note>
                  </Chord>
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

    private static func firstLyricsNode(in node: XMLTreeNode) -> XMLTreeNode? {
        if node.name == "Lyrics" { return node }
        for child in node.children {
            if let found = firstLyricsNode(in: child) { return found }
        }
        return nil
    }
}
