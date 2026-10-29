#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct OCRTextGlyphTests {
        // MARK: - Fixtures

        private func chordElement(x: CGFloat, midi: Int = 60) -> RhythmElement {
            RhythmElement(
                chord: Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: midi, tpc: 14)]),
                ),
                x: x,
                y: 500,
                stemDirection: .up,
                beamGroup: nil,
            )
        }

        /// Five staff lines, ascending y; `staffYLines[0] = 490` is the bottom line in page-space y-up.
        private let staffYLines: [CGFloat] = [490, 495, 500, 505, 510]

        private func lyricTexts(_ elements: [RhythmElement]) -> [String] {
            elements.flatMap { $0.chord.lyrics.map(\.text) }
        }

        // MARK: - Tests

        @Test func centerXUsesTheMeasuredBoxForAnOCRGlyph() {
            var g = TextGlyph(
                text: "あ", fontName: "OCR", fontSize: 10, renderedSize: 10,
                origin: CGPoint(x: 100, y: 50), bbox: .zero, pageIndex: 0,
            )
            #expect(PDFImporter.centerX(g) == 105) // estimate: origin + 1 em / 2
            g.ocr = OCRTextInfo(inkCenterX: 103.5, lyricEligible: true)
            #expect(PDFImporter.centerX(g) == 103.5)
        }

        /// One note at x 100 (centre ~102.95). An eligible and an ineligible OCR glyph both sit 40 pt under the
        /// bottom line with their measured centre under that note, so only eligibility decides.
        @Test func ineligibleOCRGlyphsNeverBecomeLyrics() {
            let elements = [chordElement(x: 100)]
            func ocrGlyph(_ text: String, eligible: Bool) -> TextGlyph {
                TextGlyph(
                    text: text, fontName: "OCR", fontSize: 10, renderedSize: 10,
                    origin: CGPoint(x: 98, y: 450), bbox: .zero, pageIndex: 0,
                    ocr: OCRTextInfo(inkCenterX: 103, lyricEligible: eligible),
                )
            }
            let texts = [ocrGlyph("a", eligible: true), ocrGlyph("mf", eligible: false)]
            let out = PDFImporter.attachLyrics(
                elements: elements, texts: texts,
                staffYLines: staffYLines, pageIndex: 0,
            )
            #expect(lyricTexts(out) == ["a"])
        }

        @Test func ocrIsOffByDefault() {
            #expect(PDFImportOptions().omrTextRecognizer == nil)
        }
    }
#endif
