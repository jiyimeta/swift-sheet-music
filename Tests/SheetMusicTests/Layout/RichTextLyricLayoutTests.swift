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
    private static func lyric(_ text: String, markup content: [PreservedTextMarkup.ContentItem]) -> Lyric {
        Lyric(text: text, preservedTextMarkup: PreservedTextMarkup(content: content, derivedText: text))
    }

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
}
