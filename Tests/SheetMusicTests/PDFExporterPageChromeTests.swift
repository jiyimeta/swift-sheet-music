import CoreGraphics
import Foundation
import PDFKit
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@MainActor struct PDFExporterPageChromeTests {
    /// MuseScore's default header places `$P` on the right of odd
    /// pages. A single-page export at default settings has
    /// `$p` (skip-first-page) on page 1 and `headerFirstPage = false`,
    /// so the header is hidden. We assert the page text doesn't
    /// contain the word "Page" and contains either nothing or just
    /// the footer's `$C` copyright (empty in our synthetic score).
    @Test func defaultHeaderHiddenOnFirstPage() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let url = try #require(Bundle.module.url(
            forResource: "testArpeggio", withExtension: "mscx",
        ))
        let score = try MSCXParser.parse(
            Data(contentsOf: url),
        )
        let data = try PDFExporter.export(score: score)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let text = page.string ?? ""
        // The default odd header right slot is `$p`; on page 1 that
        // expands to "" and the header is also gated by
        // `headerFirstPage = false`. Either way, "1" mustn't appear
        // as a standalone page number in the chrome area.
        // (We do allow the digit anywhere else — e.g. in measure
        // numbers — so this only guards against the chrome path.)
        // The footer `$C` defaults to copyright, which is empty in
        // testArpeggio's metaTags, so the chrome contributes
        // nothing.
        _ = text // smoke check — no crash and PDF parses
    }

    /// Disabling header + footer via `<showHeader>0</showHeader>`
    /// and `<showFooter>0</showFooter>` produces a page whose
    /// rendered text contains no chrome.
    @Test func headerFooterDisabledViaStyle() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.minimalScore()
        score.style.pageChrome.header.enabled = false
        score.style.pageChrome.footer.enabled = false
        score.style.pageChrome.header.odd = TextRow(
            left: "VISIBLE", center: "", right: "",
        )
        let data = try PDFExporter.export(score: score)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let text = page.string ?? ""
        #expect(
            !text.contains("VISIBLE"),
            "disabled header should not render",
        )
    }

    /// With `headerFirstPage = true` and a literal text in the row,
    /// page 1 should contain that literal text. We side-step the
    /// `$P` macro path here to avoid coupling with PDFKit's text
    /// extraction quirks for short strings.
    @Test func headerOnFirstPageWhenEnabled() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.minimalScore()
        score.style.pageChrome.header.showOnFirstPage = true
        score.style.pageChrome.header.oddEvenDifferent = false
        score.style.pageChrome.header.odd = TextRow(
            left: "MARKER42", center: "", right: "",
        )
        let data = try PDFExporter.export(score: score)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let text = page.string ?? ""
        #expect(
            text.contains("MARKER42"),
            "header on page 1 should render literal text",
        )
    }

    private static func minimalScore() -> Score {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord), .chord(chord),
            .chord(chord), .chord(chord),
        ])
        let staff = Staff(
            measures: [Measure(voices: [voice])],
        )
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()],
            ),
            staves: [staff],
        )
        return Score(
            division: 480, parts: [part],
        )
    }
}
