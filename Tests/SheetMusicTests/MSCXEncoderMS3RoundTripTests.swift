import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 round-trip")
struct MSCXEncoderMS3RoundTripTests {
    @Test("midi01 v3 round-trip matches canonical MS3 root + Style fields")
    func midi01CanonicalKeyFieldsMatch() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)

        // Root: §A
        #expect(root.attributes["version"] == "3.02")
        #expect(root.first("programVersion")?.text == "3.6.2")
        #expect(root.first("programRevision")?.text == "3224f34")
        let scoreElement = try #require(root.first("Score"))
        let firstNames = scoreElement.children.prefix(3).map(\.name)
        #expect(firstNames == ["LayerTag", "currentLayer", "Division"])
        let postStyle = scoreElement.children
            .drop(while: { $0.name != "Style" })
            .dropFirst()
            .prefix(4)
            .map(\.name)
        #expect(postStyle == ["showInvisible", "showUnprintable", "showFrames", "showMargins"])

        // Style: §B
        let style = try #require(scoreElement.first("Style"))
        #expect(style.children.count == 1)
        #expect(style.children[0].name == "Spatium")
    }

    /// MuseScore 3 uses the legacy `<RepeatMeasure><linkedMain/>` form.
    /// Native MS3 silently drops `<MeasureRepeat>` (the MS4 element
    /// name) as unknown, leaving the bar empty so the file opens with
    /// "incomplete measure: expected 4/4, got 0/1" diagnostics.
    @Test("v3 measure-repeat emits <RepeatMeasure><linkedMain/>")
    func v3MeasureRepeatUsesLegacyName() throws {
        let voice = Voice(elements: [
            .measureRepeat(MeasureRepeat(
                numMeasures: 1,
                duration: .fraction(.init(numerator: 4, denominator: 4))
            )),
        ])
        let xml = try voice.encode(
            carryIn: .init(),
            options: .init(targetVersion: .v3)
        ).node
        let voiceChildren = xml.children.map(\.name)
        #expect(voiceChildren.contains("RepeatMeasure"))
        #expect(!voiceChildren.contains("MeasureRepeat"))
        let repeatNode = try #require(xml.first("RepeatMeasure"))
        let names = repeatNode.children.map(\.name)
        #expect(names.first == "linkedMain")
        #expect(names.contains("durationType"))
        #expect(repeatNode.first("durationType")?.text == "measure")
        // Fraction auto-reduces 4/4 → 1/1 (a whole note); MS3 treats
        // these as equivalent tick-wise.
        #expect(repeatNode.first("duration")?.text == "1/1")
    }

    @Test("v4 measure-repeat keeps <MeasureRepeat><subtype>")
    func v4MeasureRepeatKeepsModernName() throws {
        let voice = Voice(elements: [
            .measureRepeat(MeasureRepeat(
                numMeasures: 1,
                duration: .fraction(.init(numerator: 4, denominator: 4))
            )),
        ])
        let xml = try voice.encode(
            carryIn: .init(),
            options: .init(targetVersion: .v4)
        ).node
        let voiceChildren = xml.children.map(\.name)
        #expect(voiceChildren.contains("MeasureRepeat"))
        #expect(!voiceChildren.contains("RepeatMeasure"))
        let repeatNode = try #require(xml.first("MeasureRepeat"))
        #expect(repeatNode.first("subtype")?.text == "1")
    }

    /// Lyrics were silently dropped on encode: the model carries them
    /// (parser fills `Chord.lyrics`), but the encoder had no Lyric
    /// emission, so MS3-exported files opened with every syllable
    /// missing. Encoder must place `<Lyrics>` between `<durationType>`
    /// and the first `<Note>` (Chord::write order on both readers).
    @Test("Chord with lyrics emits <Lyrics> children for v3 and v4")
    func chordEmitsLyrics() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            lyrics: [
                Lyric(text: "Sum", syllabic: .begin, verse: 0),
                Lyric(text: "mer", syllabic: .end, verse: 0),
            ]
        )
        let v3Node = chord.encodeAsChord(options: .init(targetVersion: .v3))
        let v3Lyrics = v3Node.children.filter { $0.name == "Lyrics" }
        #expect(v3Lyrics.count == 2)
        #expect(v3Lyrics[0].first("text")?.text == "Sum")
        #expect(v3Lyrics[0].first("syllabic")?.text == "begin")
        // v3 marks every score-graph element with <linkedMain/>.
        #expect(v3Lyrics[0].children.map(\.name).contains("linkedMain"))

        let v4Node = chord.encodeAsChord(options: .init(targetVersion: .v4))
        let v4Lyrics = v4Node.children.filter { $0.name == "Lyrics" }
        #expect(v4Lyrics.count == 2)
        #expect(v4Lyrics[0].first("text")?.text == "Sum")
        // v4 doesn't emit <linkedMain/> for non-linked staves.
        #expect(!v4Lyrics[0].children.map(\.name).contains("linkedMain"))
    }

    @Test("Empty-text lyric placeholders are skipped on encode")
    func emptyLyricPlaceholdersSkipped() throws {
        // Decoder fills the verse-N gap with empty placeholders when
        // a chord only carries verse 1; the encoder should not emit
        // them as stray empty <Lyrics> blocks.
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            lyrics: [
                Lyric(text: "", verse: 0),
                Lyric(text: "verse2", verse: 1),
            ]
        )
        let node = chord.encodeAsChord(options: .init(targetVersion: .v3))
        let lyrics = node.children.filter { $0.name == "Lyrics" }
        #expect(lyrics.count == 1)
        #expect(lyrics[0].first("text")?.text == "verse2")
        #expect(lyrics[0].first("no")?.text == "1")
    }
}
