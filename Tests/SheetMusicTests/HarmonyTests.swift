import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGFloat`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

struct HarmonyTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

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
        #expect(
            Harmony(name: "C", harmonyType: .standard).styleType
                == .chordSymbolA,
        )
        #expect(
            Harmony(name: "I", harmonyType: .roman).styleType
                == .chordSymbolRomanNumeral,
        )
        #expect(
            Harmony(name: "1", harmonyType: .nashville).styleType
                == .chordSymbolA,
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        #expect(h.offsetX == 0.5)
        #expect(h.offsetY == -1.2)
        #expect(h.color?.red == 200)
        #expect(h.color?.green == 80)
        #expect(h.color?.blue == 40)
    }

    /// MuseScore 4.4+ nests the chord-symbol content (`<name>`,
    /// `<root>`, `<base>`) inside a `<harmonyInfo>` wrapper while
    /// leaving `<rootCase>`, `<color>`, `<eid>` … as direct children
    /// of `<Harmony>`. The decoder must read the wrapped content;
    /// otherwise text-only chord symbols decode to an empty name and
    /// render nothing.
    @Test func decodesNameNestedInHarmonyInfo() throws {
        let xml = """
        <Harmony>
          <rootCase>1</rootCase>
          <harmonyInfo>
            <name>赤色のところは裏声でもよい</name>
          </harmonyInfo>
          <color r="255" g="0" b="0" a="255"/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        #expect(h.name == "赤色のところは裏声でもよい")
        #expect(h.color?.red == 255)
        #expect(h.color?.green == 0)
        #expect(h.color?.blue == 0)
    }

    @Test func decodesRootAndBaseNestedInHarmonyInfo() throws {
        let xml = """
        <Harmony>
          <harmonyInfo>
            <name>m7</name>
            <root>12</root>
            <base>17</base>
          </harmonyInfo>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        #expect(h.name == "m7")
        #expect(h.rootTpc == 12)
        #expect(h.bassTpc == 17)
    }

    @Test func decodesPlayDefaultsTrue() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8,
            )),
        )
        #expect(h.play == true)
    }

    @Test func decodesPlayFalseFromZero() throws {
        let xml = "<Harmony><name>C</name><play>0</play></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        #expect(h.play == false)
    }

    @Test func missingHarmonyTypeDefaultsToStandard() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8,
            )),
        )
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
            XMLTreeParser.parse(Data(xml.utf8)),
        )
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
            metrics: StaffMetrics(staffSize: 28),
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
            metrics: StaffMetrics(staffSize: 28),
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "B")
        #expect(runs[1].kind == .accidental(.flat))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func doubleFlatIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "Bbb"),
            metrics: StaffMetrics(staffSize: 28),
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "B")
        #expect(runs[1].kind == .accidental(.doubleFlat))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func doubleSharpIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F##"),
            metrics: StaffMetrics(staffSize: 28),
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "F")
        #expect(runs[1].kind == .accidental(.doubleSharp))
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func slashChordHasMultipleAccidentals() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#m7b5/Ab"),
            metrics: StaffMetrics(staffSize: 28),
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
            metrics: StaffMetrics(staffSize: 28),
        )
        #expect(runs.count == 2)
        #expect(runs[0].kind == .accidental(.flat))
        #expect(runs[1].content == "III")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func standardLeadingFlatIsNotSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "bVII", harmonyType: .standard),
            metrics: StaffMetrics(staffSize: 28),
        )
        #expect(runs.count == 1)
        #expect(runs[0].content == "bVII")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func widthAccumulatesAcrossRuns() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#"),
            metrics: StaffMetrics(staffSize: 28),
        )
        let width = HarmonyRendering.width(of: runs)
        let summed = runs.reduce(0.0) { $0 + $1.advance }
        #expect(width == summed)
        #expect(width > 0)
        // Runs are placed in left-to-right order. Accidental runs
        // may have a `.x` shifted by `-leftBearing` to trim Bravura's
        // natural left padding, so we don't assert `run.x ==
        // cumulative_advance`; we just check monotonic order.
        for i in 0 ..< runs.count - 1 {
            #expect(runs[i].x < runs[i + 1].x)
        }
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func rootTpcReconstructsLetterAndAccidental() {
        // <root>11</root>: TPC 11 = E flat. <name>m7</name> is the
        // suffix only. Display must be "E" + flat + "m7".
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "m7", rootTpc: 11),
            metrics: StaffMetrics(staffSize: 28),
        )
        let kinds = runs.map(\.kind)
        #expect(kinds == [.text, .accidental(.flat), .text])
        #expect(runs[0].content == "E")
        #expect(runs[2].content == "m7")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func rootTpcNaturalEmitsLetterOnly() {
        // TPC 16 = D natural — no accidental.
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "aug", rootTpc: 16),
            metrics: StaffMetrics(staffSize: 28),
        )
        // Letter + suffix coalesce into a single text run.
        #expect(runs.count == 1)
        #expect(runs[0].content == "Daug")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func slashChordReconstructsBassFromTpc() {
        // <root>10</root><name>7</name><base>11</base>
        //   = A flat + 7 + / + E flat
        let runs = HarmonyRendering.runs(
            for: Harmony(
                name: "7", rootTpc: 10, bassTpc: 11,
            ),
            metrics: StaffMetrics(staffSize: 28),
        )
        let kinds = runs.map(\.kind)
        #expect(kinds == [
            .text, // "A"
            .accidental(.flat),
            .text, // "7/E"
            .accidental(.flat),
        ])
        #expect(runs[0].content == "A")
        #expect(runs[2].content == "7/E")
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func glyphPointSizeMatchesTextSize() {
        // Chord-symbol accidentals must size with the text, not the
        // staff glyph (which is sp * 4 = 4× too big at 10 pt text).
        let metrics = StaffMetrics(staffSize: 28)
        let h = Harmony(name: "C")
        #expect(HarmonyRendering.glyphPointSize(
            for: h, metrics: metrics,
        ) < metrics.glyphFontSize)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func nashvilleLeadingSharpIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "#1", harmonyType: .nashville),
            metrics: StaffMetrics(staffSize: 28),
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
                advance: 5.0, x: 0,
            ),
            HarmonyRun(
                kind: .accidental(.sharp), content: "",
                advance: 4.0, x: 5.0,
            ),
        ]
        let lh = LayoutHarmony(
            harmony: Harmony(name: "F#"),
            anchorX: 100, y: -10,
            runs: runs, width: 9.0,
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
        let url = try #require(TestResources.url(
            forResource: "harmony-basic", withExtension: "mscx",
        ))
        let score = try SheetMusic.loadScore(mscxURL: url)
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800,
        )
        var foundHarmony: LayoutHarmony?
        var clefY: CGFloat?
        outer: for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    if case let .harmony(lh) = el, foundHarmony == nil {
                        foundHarmony = lh
                    }
                    if case let .clef(_, p, _) = el, clefY == nil {
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
            staves: [Staff(measures: [measure])],
        )
        let score = Score(division: 480, parts: [part])
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800,
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
        /// Measure with two quarters; with a wide chord symbol on the
        /// first chord, the second chord must be pushed further right
        /// than the bare-chord baseline.
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
                notes: [Note(pitch: 60, tpc: 14)],
            )))
            elements.append(.chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16)],
            )))
            let part = Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [
                    Measure(voices: [Voice(elements: elements)]),
                ])],
            )
            let score = Score(division: 480, parts: [part])
            // Use a tiny availableWidth so the layout doesn't add
            // discretionary slack — we want a measure squeezed to its
            // minimum so the harmony's contribution is visible.
            let document = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 28),
                availableWidth: 100,
            )
            var xs: [CGFloat] = []
            for system in document.systems {
                for measure in system.measures {
                    for el in measure.elements {
                        if case let .chord(_, _, _, so, _, _, _, _, _, _, _) = el {
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

    @available(macOS 15.0, iOS 16.0, *)
    // swiftlint:disable:next function_body_length
    @Test func aboveArchingTieLiftsHarmonyClearOfArc() {
        /// A high chord (well above the top staff line) carrying a tie
        /// on its top note: the tie arcs UPWARD past the notehead. The
        /// harmony auto-placer must lift the chord symbol above the
        /// tie's apex, not just above the notehead. We compare the
        /// tied vs. untied case by the GAP between the chord notehead
        /// and the harmony in document-absolute coords. (Absolute
        /// harmony Y alone is not a useful gauge: the per-staff top
        /// padding expands to absorb the autoplace shift, so the
        /// harmony's absolute Y stays roughly constant — but the staff
        /// sinks down and the gap above the notehead grows.)
        func gap(withTie: Bool) -> Double {
            let topNote = Note(
                pitch: 89, // F6, three ledger lines above treble staff
                tpc: 13,
                tieForward: withTie ? 1 : nil,
            )
            let landingNote = Note(
                pitch: 89,
                tpc: 13,
                tieBack: withTie ? 1 : nil,
            )
            let m1 = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .harmony(Harmony(name: "C")),
                .chord(Chord(duration: .whole, notes: [topNote])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [landingNote])),
            ])])
            let part = Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [m1, m2])],
            )
            let score = Score(division: 480, parts: [part])
            let document = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 28),
                availableWidth: 800,
            )
            var harmonyY: Double?
            var noteY: Double?
            for system in document.systems {
                for measure in system.measures {
                    for el in measure.elements {
                        if case let .harmony(lh) = el, harmonyY == nil {
                            harmonyY = lh.y + Double(
                                system.origin.y
                                    + measure.origin.y,
                            )
                        }
                        if case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = el,
                           noteY == nil,
                           let n = notes.first
                        {
                            noteY = Double(
                                n.origin.y + system.origin.y
                                    + measure.origin.y,
                            )
                        }
                    }
                }
            }
            guard let h = harmonyY, let n = noteY else { return .nan }
            return n - h
        }
        let untied = gap(withTie: false)
        let tied = gap(withTie: true)
        // Tied case must sit at least 1 sp (= 7 pt at staffSize=28)
        // further above the notehead than the untied case to clear
        // the tie's shoulder.
        #expect(tied > untied)
        #expect(tied - untied > 7.0)
    }

    @Test func basicFixtureExposesFiveHarmonies() throws {
        let url = try #require(TestResources.url(
            forResource: "harmony-basic", withExtension: "mscx",
        ))
        let score = try SheetMusic.loadScore(mscxURL: url)
        let harmonies: [Harmony] = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap {
                if case let .harmony(h) = $0 { return h } else { return nil }
            }
        #expect(harmonies.count == 5)
        #expect(
            harmonies.map(\.name)
                == ["C", "Am7", "F#m7b5/A", "bIII", "C"],
        )
        #expect(harmonies[3].harmonyType == .roman)
        #expect(harmonies[4].leftParen)
        #expect(harmonies[4].rightParen)
    }
}

/// Root / bass spelling against MuseScore's real TPC numbering.
///
/// `Tpc::TPC_F_BBB = -8` is the first entry of the enum
/// (`engraving/dom/pitchspelling.h:40-51`), which puts the naturals
/// at `F = 13, C = 14, G = 15, D = 16, A = 17, E = 18, B = 19` —
/// the same origin `SheetMusicCore.PitchSpelling` documents. A
/// spelling table anchored one fifth away renders every imported
/// chord symbol a perfect fourth too high (F → B♭), which is what
/// a user hit on a MuseScore import.
extension HarmonyTests {
    @available(macOS 15.0, iOS 16.0, *)
    @Test(arguments: [
        (13, "F"), (14, "C"), (15, "G"), (16, "D"),
        (17, "A"), (18, "E"), (19, "B"),
        (12, "Bb"), (11, "Eb"), (10, "Ab"), (7, "Cb"),
        (20, "F#"), (21, "C#"), (26, "B#"),
        (5, "Bbb"), (27, "F##"),
    ] as [(Int, String)])
    func rootTpcSpellsMuseScoreNaturalsAndAlterations(
        tpc: Int, spelled: String,
    ) {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "", rootTpc: tpc),
            metrics: StaffMetrics(staffSize: 28),
        )
        // Rebuild the displayed spelling from the runs so the test
        // exercises the same path the renderer draws.
        let rebuilt = runs.map { run -> String in
            switch run.kind {
            case .text: run.content
            case .accidental(.flat): "b"
            case .accidental(.doubleFlat): "bb"
            case .accidental(.sharp): "#"
            case .accidental(.doubleSharp): "##"
            }
        }.joined()
        #expect(rebuilt == spelled)
    }

    /// MuseScore 4.6 renamed the slash-bass tag from `<base>` to
    /// `<bass>` (`rw/read460/tread.cpp:2961` vs
    /// `rw/read410/tread.cpp:2991`). Reading only the historical
    /// spelling silently drops the slash bass from every chord
    /// symbol written by a current MuseScore.
    @Test func decodesModernBassTagInsideHarmonyInfo() throws {
        let xml = """
        <Harmony>
          <bassCase>2</bassCase>
          <harmonyInfo>
            <name>m7</name>
            <root>13</root>
            <bass>12</bass>
          </harmonyInfo>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        #expect(h.rootTpc == 13)
        #expect(h.bassTpc == 12)
        #expect(h.bassCase == .lower)
    }

    /// The historical spelling must keep working — MuseScore 4.5
    /// and earlier (and our own encoder) write `<base>`.
    @Test func decodesLegacyBaseTagStill() throws {
        let xml = """
        <Harmony>
          <baseCase>2</baseCase>
          <harmonyInfo>
            <name>m7</name>
            <root>13</root>
            <base>12</base>
          </harmonyInfo>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        #expect(h.bassTpc == 12)
        #expect(h.bassCase == .lower)
    }

    /// End-to-end shape of the reported bug: `Fm7/B♭` as a current
    /// MuseScore writes it must display as `Fm7/B♭`, not `B♭m7`.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func museScore46SlashChordDisplaysRootAndBass() throws {
        let xml = """
        <Harmony>
          <harmonyInfo>
            <name>m7</name>
            <root>13</root>
            <bass>12</bass>
          </harmonyInfo>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)),
        )
        let runs = HarmonyRendering.runs(
            for: h, metrics: StaffMetrics(staffSize: 28),
        )
        #expect(runs.map(\.kind) == [
            .text, // "Fm7/B"
            .accidental(.flat),
        ])
        #expect(runs[0].content == "Fm7/B")
    }
}
