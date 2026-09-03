import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import SheetMusicZip
import Testing

/// MuseScore 4.4+ writes a score's `<Style>` block into a separate
/// `score_style.mss` entry of the `.mscz` container and omits it from
/// the `.mscx` altogether. A reader that only looks at the `.mscx`
/// therefore sees no style at all and silently substitutes MuseScore's
/// built-in defaults — which is how a score saved with **swing on**
/// came back straight, while scores carrying their swing as an
/// in-piece `<swing>` directive (the only path this reader used to
/// have) kept playing swung.
///
/// C++: `MscReader::readStyleFile` (`mscreader.cpp:127`) feeding
/// `MscLoader::loadMscz` (`mscloader.cpp:88-97`), which reads the style
/// file into `MStyle` *before* the score body so an inline `<Style>`
/// overrides it tag by tag.
@Suite("MSCZ score_style.mss")
struct MSCZStyleFileTests {
    // MARK: - Container assembly

    /// Four consecutive 8th-note Cs at 480 PPQ and **no** `<Style>`
    /// element — the shape MuseScore 4.4+ writes when the style lives
    /// in the container's style file. `extraScoreChildren` is spliced
    /// in right after `<Division>` so a test can add an inline
    /// `<Style>` back.
    private func mscxXML(extraScoreChildren: String = "") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.70">
          <Score>
            <Division>480</Division>
            \(extraScoreChildren)
            <Part>
              <Staff id="1"/>
              <Instrument>
                <trackName>Test</trackName>
                <Channel>
                  <program value="0"/>
                </Channel>
              </Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <TimeSig>
                    <sigN>4</sigN>
                    <sigD>4</sigD>
                  </TimeSig>
                  <Chord>
                    <durationType>eighth</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                  <Chord>
                    <durationType>eighth</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                  <Chord>
                    <durationType>eighth</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                  <Chord>
                    <durationType>eighth</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """.utf8)
    }

    /// A `score_style.mss` document: `<museScore><Style>` wrapping the
    /// given style children. Carries swing plus one field from each
    /// other family `ScoreStyle` models, so a test can tell "the style
    /// file was read" from "swing happened to be special-cased".
    private func styleFileXML(
        _ children: String = """
        <swingUnit>eighth</swingUnit>
        <swingRatio>67</swingRatio>
        <spatium>1.2</spatium>
        <ottavaNumbersOnly>0</ottavaNumbersOnly>
        """,
    ) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.70">
          <Style>
            \(children)
          </Style>
        </museScore>
        """.utf8)
    }

    private func containerXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container>
          <rootfiles>
            <rootfile full-path="score_style.mss"/>
            <rootfile full-path="score.mscx"/>
          </rootfiles>
        </container>
        """.utf8)
    }

    /// Zip the pieces into a `.mscz`. Built in memory rather than
    /// committed as a binary fixture so the XML under test is readable
    /// in the diff.
    private func mscz(mscx: Data, styleFile: Data?) throws -> Data {
        var writer = ZipWriter()
        try writer.add(path: "META-INF/container.xml", data: containerXML())
        if let styleFile {
            try writer.add(path: "score_style.mss", data: styleFile)
        }
        try writer.add(path: "score.mscx", data: mscx)
        return writer.finish()
    }

    private func noteOnTicks(_ midi: MidiFile) -> [Int] {
        midi.tracks.flatMap { track in
            track.events.compactMap { ev -> Int? in
                if case .noteOn = ev.event { return ev.tick }
                return nil
            }
        }.sorted()
    }

    // MARK: - Tests

    @Test("score_style.mss supplies the style when the mscx has none")
    func styleFileSuppliesScoreStyle() throws {
        let data = try mscz(mscx: mscxXML(), styleFile: styleFileXML())
        let score = try MSCZReader.parse(data)

        #expect(score.style.swingUnit == .eighth)
        #expect(score.style.swingRatio == 67)
        #expect(score.style.spatium == 1.2)
        #expect(score.style.ottavaNumbersOnly == false)
    }

    /// The bug as the user meets it: the score plays straight. Same
    /// arithmetic as `MidiSwingRenderTests.tripletSwingShift` —
    /// ratio 67 shifts up-beats by 480 * (67 - 50) / 100 = 81 ticks —
    /// but with the swing arriving from the container's style file
    /// instead of a hand-built `ScoreStyle`.
    @Test("swing declared in score_style.mss reaches MIDI playback")
    func styleFileSwingReachesPlayback() throws {
        let data = try mscz(mscx: mscxXML(), styleFile: styleFileXML())
        let score = try MSCZReader.parse(data)

        let midi = try MidiRenderer.render(score: score)
        #expect(noteOnTicks(midi) == [0, 321, 480, 801])
    }

    /// MuseScore reads the style file first and the score's inline
    /// `<Style>` second, so the inline block wins for the tags it
    /// carries and inherits the rest. MuseScore 4 writes one or the
    /// other, never both — this pins the layering for containers that
    /// do carry both.
    @Test("an inline <Style> overrides the style file tag by tag")
    func inlineStyleOverridesStyleFile() throws {
        let data = try mscz(
            mscx: mscxXML(extraScoreChildren: """
            <Style>
              <swingRatio>60</swingRatio>
            </Style>
            """),
            styleFile: styleFileXML(),
        )
        let score = try MSCZReader.parse(data)

        // Overridden by the mscx…
        #expect(score.style.swingRatio == 60)
        // …everything else still comes from the style file.
        #expect(score.style.swingUnit == .eighth)
        #expect(score.style.spatium == 1.2)
    }

    @Test("a container without a style file keeps MuseScore's defaults")
    func containerWithoutStyleFileKeepsDefaults() throws {
        let data = try mscz(mscx: mscxXML(), styleFile: nil)
        let score = try MSCZReader.parse(data)

        #expect(score.style.swingUnit == .off)
        #expect(score.style == .museScoreDefaults)
        let midi = try MidiRenderer.render(score: score)
        #expect(noteOnTicks(midi) == [0, 240, 480, 720])
    }

    /// A style file that will not parse must not fail the score — but
    /// it must not vanish quietly either, because the fallback (plain
    /// MuseScore defaults) is silently wrong for the score.
    @Test("an unreadable style file is reported, not silently dropped")
    func unreadableStyleFileIsReported() throws {
        let data = try mscz(
            mscx: mscxXML(),
            styleFile: Data("<museScore><Style".utf8),
        )
        let result = try MSCZReader.parseWithDiagnostics(data)

        #expect(result.score.style == .museScoreDefaults)
        #expect(result.diagnostics.contains {
            $0.code == "mscz.styleFile.unreadable"
        })
    }

    @Test("a style file with no <Style> element is reported")
    func styleFileWithoutStyleElementIsReported() throws {
        let data = try mscz(
            mscx: mscxXML(),
            styleFile: Data("<museScore version=\"4.70\"/>".utf8),
        )
        let result = try MSCZReader.parseWithDiagnostics(data)

        #expect(result.score.style == .museScoreDefaults)
        #expect(result.diagnostics.contains {
            $0.code == "mscz.styleFile.noStyleElement"
        })
    }
}
