// swiftlint:disable file_length
import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct HarmonyTests {
    @Test func defaultsAreInert() {
        let h = Harmony(name: "C")
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
        #expect(h.rootCase == .auto)
        #expect(h.bassCase == .auto)
        #expect(h.leftParen == false)
        #expect(h.rightParen == false)
        #expect(h.play == true)
        #expect(h.offsetX == 0)
        #expect(h.offsetY == 0)
        #expect(h.color == nil)
        #expect(h.styleType == .chordSymbolA)
    }

    @Test func styleTypeFollowsHarmonyType() {
        #expect(Harmony(name: "C", harmonyType: .standard).styleType
            == .chordSymbolA)
        #expect(Harmony(name: "I", harmonyType: .roman).styleType
            == .chordSymbolRomanNumeral)
        #expect(Harmony(name: "1", harmonyType: .nashville).styleType
            == .chordSymbolA)
    }

    @Test func voiceElementHarmonyCaseExists() {
        let element: VoiceElement = .harmony(Harmony(name: "C"))
        guard case let .harmony(h) = element else {
            Issue.record("expected .harmony case")
            return
        }
        #expect(h.name == "C")
    }
}

extension HarmonyTests {
    @Test func decodesStandardChordNameAndType() throws {
        let xml = "<Harmony><name>C</name></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
    }

    @Test func decodesSlashChordRootAndBassTpc() throws {
        let xml = """
        <Harmony>
          <name>F#m7b5/A</name>
          <root>20</root>
          <base>17</base>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.name == "F#m7b5/A")
        #expect(h.rootTpc == 20)
        #expect(h.bassTpc == 17)
    }

    @Test func decodesRomanNumeralType() throws {
        let xml = """
        <Harmony>
          <name>bIII</name>
          <harmonyType>1</harmonyType>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.harmonyType == .roman)
        #expect(h.styleType == .chordSymbolRomanNumeral)
    }

    @Test func decodesParentheses() throws {
        let xml = """
        <Harmony>
          <name>Am7</name>
          <leftParen/>
          <rightParen/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.leftParen)
        #expect(h.rightParen)
    }

    @Test func tpcInvalidNormalizesToNil() throws {
        let xml = """
        <Harmony>
          <name>C</name>
          <root>-1</root>
          <base>-1</base>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
    }

    @Test func decodesOffsetAndColor() throws {
        let xml = """
        <Harmony>
          <name>C</name>
          <offset x="0.5" y="-1.2"/>
          <color r="200" g="80" b="40" a="255"/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.offsetX == 0.5)
        #expect(h.offsetY == -1.2)
        #expect(h.color?.red == 200)
        #expect(h.color?.green == 80)
        #expect(h.color?.blue == 40)
    }

    @Test func decodesPlayDefaultsTrue() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8)))
        #expect(h.play == true)
    }

    @Test func decodesPlayFalseFromZero() throws {
        let xml = "<Harmony><name>C</name><play>0</play></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.play == false)
    }

    @Test func missingHarmonyTypeDefaultsToStandard() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8)))
        #expect(h.harmonyType == .standard)
    }

    @Test func voiceDecoderRecognizesHarmony() throws {
        let xml = """
        <voice>
          <Harmony><name>Am7</name></Harmony>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 2)
        guard case let .harmony(h) = voice.elements[0] else {
            Issue.record("element 0 is not .harmony")
            return
        }
        #expect(h.name == "Am7")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func sharpAfterLetterIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].kind == .text)
        #expect(runs[0].content == "F")
        #expect(runs[1].kind == .accidental(.sharp))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func flatAfterLetterIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "Bb"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "B")
        #expect(runs[1].kind == .accidental(.flat))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func doubleFlatIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "Bbb"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "B")
        #expect(runs[1].kind == .accidental(.doubleFlat))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func doubleSharpIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F##"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "F")
        #expect(runs[1].kind == .accidental(.doubleSharp))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func slashChordHasMultipleAccidentals() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#m7b5/Ab"),
            metrics: StaffMetrics(staffSize: 28)
        )
        let kinds = runs.map(\.kind)
        #expect(kinds == [
            .text,
            .accidental(.sharp),
            .text,
            .accidental(.flat),
            .text,
            .accidental(.flat),
        ])
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func romanLeadingFlatIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "bIII", harmonyType: .roman),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].kind == .accidental(.flat))
        #expect(runs[1].content == "III")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func standardLeadingFlatIsNotSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "bVII", harmonyType: .standard),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 1)
        #expect(runs[0].content == "bVII")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func widthAccumulatesAcrossRuns() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#"),
            metrics: StaffMetrics(staffSize: 28)
        )
        let width = HarmonyRendering.width(of: runs)
        let summed = runs.reduce(0.0) { $0 + $1.advance }
        #expect(width == summed)
        #expect(width > 0)
        var cumulative = 0.0
        for run in runs {
            #expect(run.x == cumulative)
            cumulative += run.advance
        }
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func nashvilleLeadingSharpIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "#1", harmonyType: .nashville),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].kind == .accidental(.sharp))
        #expect(runs[1].content == "1")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutHarmonyTypeShapeCompiles() {
        let runs: [HarmonyRun] = [
            HarmonyRun(
                kind: .text, content: "F",
                advance: 5.0, x: 0
            ),
            HarmonyRun(
                kind: .accidental(.sharp), content: "",
                advance: 4.0, x: 5.0
            ),
        ]
        let lh = LayoutHarmony(
            harmony: Harmony(name: "F#"),
            anchorX: 100, y: -10,
            runs: runs, width: 9.0
        )
        let element: LayoutElement = .harmony(lh)
        guard case let .harmony(unwrapped) = element else {
            Issue.record("expected .harmony case"); return
        }
        #expect(unwrapped.runs.count == 2)
        #expect(unwrapped.width == 9.0)
        #expect(HarmonyAccidental.flat.codepoint == "\u{E260}")
        #expect(HarmonyAccidental.doubleFlat.codepoint == "\u{E264}")
        #expect(HarmonyAccidental.sharp.codepoint == "\u{E262}")
        #expect(HarmonyAccidental.doubleSharp.codepoint == "\u{E263}")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutEmitsHarmonyAboveStaff() throws {
        let url = try #require(Bundle.module.url(
            forResource: "harmony-basic", withExtension: "mscx"
        ))
        let score = try SheetMusic.loadScore(mscxURL: url)
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800
        )
        var foundHarmony: LayoutHarmony?
        var clefY: CGFloat?
        outer: for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    if case let .harmony(lh) = el, foundHarmony == nil {
                        foundHarmony = lh
                    }
                    if case let .clef(_, p) = el, clefY == nil {
                        clefY = p.y
                    }
                    if foundHarmony != nil, clefY != nil { break outer }
                }
            }
        }
        let lh = try #require(foundHarmony)
        let clefMidY = try #require(clefY)
        // Harmony sits ABOVE the staff (clef glyph anchored at staff
        // mid-line). With y measured downward, harmony.y must be
        // less than the clef's anchor.
        #expect(lh.y < Double(clefMidY))
        #expect(lh.runs.isEmpty == false)
        #expect(lh.harmony.name == "C")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func multipleHarmoniesAtSameTickStackVertically() {
        let note = Note(pitch: 60, tpc: 14)
        let measure = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .harmony(Harmony(name: "C")),
            .harmony(Harmony(name: "Am7")),
            .chord(Chord(duration: .whole, notes: [note])),
        ])])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [measure])]
        )
        let score = Score(division: 480, parts: [part])
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800
        )
        var harmonies: [LayoutHarmony] = []
        for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    if case let .harmony(lh) = el {
                        harmonies.append(lh)
                    }
                }
            }
        }
        #expect(harmonies.count == 2)
        let ys = harmonies.map(\.y).sorted()
        #expect(ys[0] < ys[1])
        #expect(abs(harmonies[0].y - harmonies[1].y) > 0.5)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func wideHarmonyExpandsChordSpacing() {
        // Measure with two quarters; with a wide chord symbol on the
        // first chord, the second chord must be pushed further right
        // than the bare-chord baseline.
        func chordXs(harmonyName: String?) -> [CGFloat] {
            var elements: [VoiceElement] = [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 2, denominator: 4)),
            ]
            if let name = harmonyName {
                elements.append(.harmony(Harmony(name: name)))
            }
            elements.append(.chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)]
            )))
            elements.append(.chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16)]
            )))
            let part = Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [
                    Measure(voices: [Voice(elements: elements)]),
                ])]
            )
            let score = Score(division: 480, parts: [part])
            // Use a tiny availableWidth so the layout doesn't add
            // discretionary slack — we want a measure squeezed to its
            // minimum so the harmony's contribution is visible.
            let document = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 28),
                availableWidth: 100
            )
            var xs: [CGFloat] = []
            for system in document.systems {
                for measure in system.measures {
                    for el in measure.elements {
                        if case let .chord(_, _, _, so, _, _, _, _) = el {
                            xs.append(so.x)
                        }
                    }
                }
            }
            return xs
        }
        let bare = chordXs(harmonyName: nil)
        let wide = chordXs(harmonyName: "F#m7b5/Ab")
        #expect(bare.count == 2)
        #expect(wide.count == 2)
        // With the wide chord symbol, the SECOND chord's X must move
        // further to the right than the bare baseline.
        #expect(wide[1] > bare[1])
    }

    @Test func basicFixtureExposesFiveHarmonies() throws {
        let url = try #require(Bundle.module.url(
            forResource: "harmony-basic", withExtension: "mscx"
        ))
        let score = try SheetMusic.loadScore(mscxURL: url)
        let harmonies: [Harmony] = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap {
                if case let .harmony(h) = $0 { return h } else { return nil }
            }
        #expect(harmonies.count == 5)
        #expect(harmonies.map(\.name)
            == ["C", "Am7", "F#m7b5/A", "bIII", "C"])
        #expect(harmonies[3].harmonyType == .roman)
        #expect(harmonies[4].leftParen)
        #expect(harmonies[4].rightParen)
    }
}
