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

        /// Line spacing 5, so the walker's band ends 8 spatia (40 pt) under the bottom line at y 450 and an OCR glyph's
        /// at 10 spatia (y 440): a glyph at 9 spatia (y 445) is a lyric only when OCR read it, one at 11 (y 435) never.
        @Test func anOCRGlyphIsALyricDeeperUnderTheStaffThanAWalkerGlyph() {
            func glyph(y: CGFloat, ocr: Bool) -> TextGlyph {
                TextGlyph(
                    text: "a", fontName: ocr ? "OCR" : "F1", fontSize: 10, renderedSize: 10,
                    origin: CGPoint(x: 98, y: y), bbox: .zero, pageIndex: 0,
                    ocr: ocr ? OCRTextInfo(inkCenterX: 103, lyricEligible: true) : nil,
                )
            }
            func attached(_ text: TextGlyph) -> [String] {
                lyricTexts(PDFImporter.attachLyrics(
                    elements: [chordElement(x: 100)], texts: [text], staffYLines: staffYLines, pageIndex: 0,
                ))
            }
            #expect(attached(glyph(y: 445, ocr: true)) == ["a"])
            #expect(attached(glyph(y: 445, ocr: false)).isEmpty)
            #expect(attached(glyph(y: 435, ocr: true)).isEmpty)
        }

        @Test func chordSymbolsAndRepeatMarksAreIneligible() {
            let ineligible = [
                "Fm", "Cm/G", "D♭M7", "Eb7", "B♭m7/E♭", "C", "Esus4", "Gm/F", "/F", "A♭add9",
                "D，", "Cm7,", "D.S.", "Coda",
            ]
            for token in ineligible {
                #expect(!OCRTextGlyphs.isLyricEligible(token), "\(token)")
            }
            for token in ["Be", "Ado", "am", "a", "dance", "Day", "Go"] {
                #expect(OCRTextGlyphs.isLyricEligible(token), "\(token)")
            }
        }

        @Test func ocrIsOffByDefault() {
            #expect(PDFImportOptions().omrTextRecognizer == nil)
        }

        // MARK: - Characters to glyphs

        private let pageTransform = PageTransform(dpi: 72, widthPx: 1000, heightPx: 1000, deskewDegrees: 0)

        /// A line whose box spans its characters; each character is `(text, x, width)` on a 20 px tall row at y 500.
        private func ocrLine(_ text: String, _ chars: [(String, Double, Double)]) -> RasterTextLine {
            let characters = chars.map {
                RasterTextCharacter(text: $0.0, rect: PixelRect(x: $0.1, y: 500, width: $0.2, height: 20))
            }
            let minX = chars.map(\.1).min() ?? 0
            let maxX = chars.map { $0.1 + $0.2 }.max() ?? 0
            return RasterTextLine(
                text: text, confidence: 1,
                rect: PixelRect(x: minX, y: 500, width: maxX - minX, height: 20),
                characters: characters,
            )
        }

        @Test func eachCharacterBecomesOneGlyphAtItsBoxCentre() {
            let line = ocrLine("あい", [("あ", 100, 20), ("い", 120, 20)])
            let gs = OCRTextGlyphs.textGlyphs(from: [line], transform: pageTransform, pageIndex: 3)
            #expect(gs.map(\.text) == ["あ", "い"])
            #expect(gs.map(\.origin.x) == [100, 120])
            #expect(gs.allSatisfy { $0.origin.y == 480 }) // 1000 - (500 + 20)
            #expect(gs.map { $0.ocr?.inkCenterX } == [110, 130])
            #expect(gs.allSatisfy { $0.fontSize == 20 && $0.renderedSize == 20 && $0.pageIndex == 3 })
            #expect(gs.allSatisfy { $0.fontName == "OCR" && $0.bbox == .zero })
        }

        @Test func whitespaceIsNotAGlyph() {
            let line = ocrLine("a b", [("a", 100, 10), ("b", 120, 10)])
            let gs = OCRTextGlyphs.textGlyphs(from: [line], transform: pageTransform, pageIndex: 0)
            #expect(gs.map(\.text) == ["a", "b"])
        }

        @Test func nonLyricTokensAreMarkedIneligible() {
            #expect(!OCRTextGlyphs.isLyricEligible("mf"))
            #expect(!OCRTextGlyphs.isLyricEligible("cresc."))
            #expect(!OCRTextGlyphs.isLyricEligible("Ped."))
            #expect(!OCRTextGlyphs.isLyricEligible("Ped.*"))
            #expect(!OCRTextGlyphs.isLyricEligible("*Ped."))
            #expect(!OCRTextGlyphs.isLyricEligible("(p)"))
            #expect(!OCRTextGlyphs.isLyricEligible("mf,"))
            #expect(!OCRTextGlyphs.isLyricEligible("(cresc.)"))
            #expect(!OCRTextGlyphs.isLyricEligible("-4728"))
            #expect(!OCRTextGlyphs.isLyricEligible("★"))
            #expect(OCRTextGlyphs.isLyricEligible("woo"))
            #expect(OCRTextGlyphs.isLyricEligible("ることが"))
            #expect(OCRTextGlyphs.isLyricEligible("shin-ing"))
        }

        @Test func aDynamicNextToALyricOnOneLineIsSplitByTheGap() {
            // No space in the string, but a 30 px gap (line height 20) between "f" and "あ".
            let line = ocrLine("mfあ", [("m", 100, 10), ("f", 110, 10), ("あ", 150, 20)])
            let gs = OCRTextGlyphs.textGlyphs(from: [line], transform: pageTransform, pageIndex: 0)
            #expect(gs.map(\.text) == ["m", "f", "あ"])
            #expect(gs.map { $0.ocr?.lyricEligible } == [false, false, true])
        }

        @Test func aTempoIsIneligibleAsTwoWords() {
            let line = ocrLine(
                "a tempo",
                [("a", 100, 10), ("t", 130, 10), ("e", 140, 10), ("m", 150, 10), ("p", 160, 10), ("o", 170, 10)],
            )
            let gs = OCRTextGlyphs.textGlyphs(from: [line], transform: pageTransform, pageIndex: 0)
            #expect(gs.count == 6)
            #expect(gs.allSatisfy { $0.ocr?.lyricEligible == false })
        }
    }
#endif
