#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A lyric's runs can carry what its plain text does not: a syllable of symbols alone has empty text, and MuseScore's
/// lyric editor joins two syllables sung on one note with `<sym>lyricsElision</sym>`
/// (`engraving/editing/textedit.cpp:738`), a glyph the plain projection leaves out. Layout lays such a syllable out and
/// spaces it by its runs. Stub numbers as in `RichTextLayoutTests`; at `staffSize: 20` the spatium is 5 pt.
@Suite("Rich lyrics in layout")
struct RichTextLyricLayoutTests {
    private static let metrics = StaffMetrics(staffSize: 20)

    /// The test that runs `LayoutEngine.layout` uses the installed provider, so it asserts relations, not constants.
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 1e-6
    }

    /// A syllable whose preserved markup is `content` and still describes `text`.
    private static func lyric(
        _ text: String, markup content: [PreservedTextMarkup.ContentItem], syllabic: Syllabic = .single, ticks: Int = 0,
    ) -> Lyric {
        Lyric(
            text: text, syllabic: syllabic, ticks: ticks,
            preservedTextMarkup: PreservedTextMarkup(content: content, derivedText: text),
        )
    }

    /// One bar of quarter chords, `lyrics[i]` on chord `i`, laid out with the installed provider.
    private static func document(_ lyrics: [Lyric?]) -> LayoutDocument {
        let chords = lyrics.enumerated().map { index, lyric in
            VoiceElement.chord(Chord(
                duration: .quarter, notes: ChordNotes([Note(pitch: 60 + index, tpc: 14)]),
                lyrics: lyric.map { [$0] } ?? [],
            ))
        }
        let staff = Staff(measures: [Measure(voices: [Voice(elements: chords)])])
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])])
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 900)
    }

    /// Every lyric syllable of the first measure: its text, its center x (measure-local) and its runs.
    private static func marks(_ document: LayoutDocument) -> [(text: String, x: CGFloat, rich: LayoutRichText?)] {
        (document.systems.first?.measures.first?.elements ?? []).compactMap { element in
            guard case let .textMark(.lyrics, text, origin, rich) = element else { return nil }
            return (text, origin.x, rich)
        }
    }

    /// The quantities lyric widths feed: every measure's width and every syllable's x.
    private static func spacing(_ document: LayoutDocument) -> [CGFloat] {
        document.systems.flatMap(\.measures).map(\.width) + marks(document).map(\.x)
    }

    /// An elided "gloria" set at 22 pt, twice the lyric size. The size makes its runs wider than the plain stand-in
    /// under every metrics provider: with the portable table (wasm) the lyric face is narrower than the semibold
    /// stand-in, and an elision alone measured 43.8 against the stand-in's 46.2.
    private static let wideElided: [PreservedTextMarkup.ContentItem] = [
        .element(.init(name: "font", attributes: ["size": "22"])),
        .characters("glo"), symbol("lyricsElision"), .characters("ria"),
    ]

    private static func symbol(_ name: String) -> PreservedTextMarkup.ContentItem {
        .element(.init(name: "sym", content: [.characters(name)]))
    }

    /// A symbol-only syllable decodes to empty text with a symbol run (`MSCXTextMarkupTests.symbolOnlyLyric`). Layout
    /// skipped it as empty; it now reaches the document with its runs, and spacing measures them.
    @Test("a syllable of symbols alone reaches the document with its runs")
    func symbolOnlyLyricIsLaidOut() {
        let lyric = Self.lyric("", markup: [Self.symbol("keyboardPedalPed")])
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), lyrics: [lyric])
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
        )], systemMeasures: [SystemMeasure()])
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
        let elements = document.systems.flatMap(\.measures).flatMap(\.elements)
        let laidOut = elements.compactMap { element -> LayoutRichText? in
            guard case let .textMark(.lyrics, "", _, rich?) = element else { return nil }
            return rich
        }
        #expect(laidOut.count == 1)
        #expect(laidOut.first?.lines.first?.runs.count == 1)
        #expect(LayoutEngine.chordLyricMaxWidth([lyric], metrics: document.metrics) > 0)
    }

    /// "glo" + `<sym>lyricsElision</sym>` + "ria". Stub: the plain stand-in measures "gloria" in its 11 pt face
    /// (2.2 sp), 6 × 0.5 × 11 = 33. The runs are set in the 10 pt lyric face with Bravura at the lyric symbol size 10:
    /// 15 + 0.55 × 10 + 15 = 35.5, wider, so the syllable is spaced by 35.5. Two such single syllables side by side ask
    /// for 35.5 / 2 + 0.25 sp + 35.5 / 2 = 36.75 between their centers; the plain 33 asked for 34.25, less than one
    /// syllable's drawn width. Three runs pin that the by-name table resolves `lyricsElision` — unresolved, the glyph
    /// is dropped and the runs measure 30.
    @Test("an elided syllable is spaced by its runs, which are wider than its plain text")
    func elidedLyricSpacing() {
        FontMetrics.$scopedProvider.withValue(StubFontMetricsProvider()) {
            let markup: [PreservedTextMarkup.ContentItem] = [
                .characters("glo"), Self.symbol("lyricsElision"), .characters("ria"),
            ]
            let lyric = Self.lyric("gloria", markup: markup)
            let rich = LayoutEngine.lyricRichText(lyric, metrics: Self.metrics)
            #expect(rich?.lines.first?.runs.count == 3)
            #expect(Self.close(rich?.size.width ?? 0, 35.5))
            #expect(Self.close(LayoutEngine.lyricsTextWidth("gloria", sp: Self.metrics.sp), 33))
            #expect(Self.close(LayoutEngine.chordLyricMaxWidth([lyric], metrics: Self.metrics), 35.5))
            let pair = LayoutEngine.lyricsPairWidth(
                currentLyrics: [lyric], next: (lyrics: [lyric], gaps: 1), metrics: Self.metrics,
            )
            #expect(Self.close(pair, 36.75) && pair >= (rich?.size.width ?? .infinity))
        }
    }

    /// A one-run formatted syllable is spaced like its plain twin: `lyricsTextWidth(_:properties:rich:metrics:)` takes
    /// the larger of the plain stand-in (system semibold) and the runs, so runs no wider than it change nothing. Real
    /// `LayoutEngine.layout`, installed provider: every measure width and every syllable x must be bit-identical. If
    /// the face makes the runs wider than the stand-in, this fails and says so; that is a finding, not a flake.
    @Test("a one-run formatted lyric is spaced exactly like its plain twin", arguments: ["i", "b"])
    func oneRunLyricSpacesLikePlain(tag: String) {
        let plain = Self.document([Lyric(text: "Ah"), nil, Lyric(text: "oh"), nil])
        let formatted = Self.lyric("Ah", markup: [.element(.init(name: tag, content: [.characters("Ah")]))])
        let rich = Self.document([formatted, nil, Lyric(text: "oh"), nil])
        #expect(Self.marks(rich).filter { $0.rich != nil }.count == 1, "<\(tag)> must reach layout as runs")
        #expect(Self.marks(plain).count == 2 && Self.marks(rich).count == 2)
        #expect(Self.spacing(rich) == Self.spacing(plain))
    }

    /// The hyphen after an elided syllable starts past the RUNS' right edge. "gloria" with the elision glyph is wider
    /// than its plain text (the first expectation guards that, or the test could not tell the two widths apart); the
    /// connecting dash is emitted from `centerX + width / 2 + 0.3 sp`, and a dash never starts left of that.
    @Test("the hyphen after an elided syllable starts past its rich width")
    func hyphenStartsAfterRichWidth() throws {
        let begin = Self.lyric("gloria", markup: Self.wideElided, syllabic: .begin)
        let document = Self.document([begin, nil, Lyric(text: "a", syllabic: .end), nil])
        let mark = try #require(Self.marks(document).first { $0.text == "gloria" })
        let rich = try #require(mark.rich)
        let plainWidth = LayoutEngine.lyricsTextWidth("gloria", properties: TextProperties(), metrics: document.metrics)
        #expect(rich.size.width > plainWidth, "the elision glyph must make the runs wider than the plain text")

        let elements = try #require(document.systems.first?.measures.first?.elements)
        let dashes = elements.compactMap { element -> CGFloat? in
            guard case let .lyricHyphen(from, to, _) = element else { return nil }
            return min(from.x, to.x)
        }
        let dashStart = try #require(dashes.min())
        let richRight = mark.x + rich.size.width / 2 + document.metrics.sp * 0.3
        let plainRight = mark.x + plainWidth / 2 + document.metrics.sp * 0.3
        #expect(dashStart >= richRight - 1e-6, "dash at \(dashStart), rich right edge \(richRight)")
        #expect(richRight > plainRight)
    }

    /// The melisma rule of an elided syllable starts at `centerX + richWidth / 2 + 0.25 sp` (`emitMelismaLine`), not at
    /// the narrower plain text's edge. Three ticks of 480 end the rule on the fourth chord's column.
    @Test("a melisma line starts after the rich width")
    func melismaStartsAfterRichWidth() throws {
        let held = Self.lyric("gloria", markup: Self.wideElided, ticks: 1440)
        let document = Self.document([held, nil, nil, nil])
        let mark = try #require(Self.marks(document).first { $0.text == "gloria" })
        let rich = try #require(mark.rich)
        let plainWidth = LayoutEngine.lyricsTextWidth("gloria", properties: TextProperties(), metrics: document.metrics)
        #expect(rich.size.width > plainWidth, "the elision glyph must make the runs wider than the plain text")

        let elements = try #require(document.systems.first?.measures.first?.elements)
        let starts = elements.compactMap { element -> CGFloat? in
            guard case let .lyricsMelisma(from, _, _) = element else { return nil }
            return from.x
        }
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(Self.close(start, mark.x + rich.size.width / 2 + document.metrics.sp * 0.25), "\(start)")
    }
}
