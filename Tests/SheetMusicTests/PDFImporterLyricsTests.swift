#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterLyricsTests {
        // MARK: - Fixtures

        private func textGlyph(
            _ text: String, x: CGFloat, y: CGFloat,
        ) -> TextGlyph {
            TextGlyph(
                text: text,
                fontName: "Helvetica",
                fontSize: 10,
                origin: CGPoint(x: x, y: y),
                bbox: CGRect(x: x, y: y, width: 20, height: 10),
                pageIndex: 0,
            )
        }

        private func chordElement(
            x: CGFloat, midi: Int = 60,
        ) -> RhythmElement {
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

        /// Five staff lines, ascending y. The "bottom" of the staff in
        /// PDF y-up coordinates is `staffYLines[0] = 490`. Lyrics live
        /// just below that.
        private let staffYLines: [CGFloat] = [490, 495, 500, 505, 510]

        // MARK: - Centre-based snapping

        /// A glyph carrying a real page-space em, so `centerX` engages.
        /// `origin` is the LEFT EDGE of the ink, as the walker records it.
        private func sizedGlyph(
            _ text: String, x: CGFloat, y: CGFloat, em: CGFloat,
        ) -> TextGlyph {
            TextGlyph(
                text: text,
                fontName: "HiraginoSans",
                fontSize: em / 0.2,
                renderedSize: em,
                origin: CGPoint(x: x, y: y),
                bbox: .zero,
                pageIndex: 0,
            )
        }

        /// MuseScore centres a syllable under its note, so the snap must
        /// compare CENTRES on both sides. Geometry here (spatium = 5):
        ///
        /// - notes at x = 100 and 120; `RhythmElement.x` is the notehead's
        ///   LEFT edge, so their centres are 102.95 and 122.95
        ///   (+ 1.18 sp / 2).
        /// - a full-width kana, em 10, left edge 109 → centre 114.
        ///
        /// By LEFT edges the kana is nearer note 0 (9 vs 11). By CENTRES it
        /// is nearer note 1 (11.05 vs 8.95). It must attach to note 1.
        @Test func fullWidthKanaSnapsByCentresNotLeftEdges() {
            let elements = [chordElement(x: 100), chordElement(x: 120)]
            let texts = [sizedGlyph("あ", x: 109, y: 480, em: 10)]
            let out = PDFImporter.attachLyrics(
                elements: elements, texts: texts,
                staffYLines: staffYLines, pageIndex: 0,
            )
            #expect(out[0].chord.lyrics.isEmpty)
            #expect(out[1].chord.lyrics == [Lyric(text: "あ", syllabic: .single)])
        }

        /// The SAME origin and em, but a proportional Latin letter. Latin
        /// advances about half an em, so its centre is 111.5, not 114 — near
        /// note 0. A blanket half-em offset would wrongly send this to note 1
        /// exactly like the kana, which is what the pre-fix origin did.
        @Test func latinGlyphUsesAHalfEmAdvanceSoItStaysOnTheNearerNote() {
            let elements = [chordElement(x: 100), chordElement(x: 120)]
            let texts = [sizedGlyph("a", x: 109, y: 480, em: 10)]
            let out = PDFImporter.attachLyrics(
                elements: elements, texts: texts,
                staffYLines: staffYLines, pageIndex: 0,
            )
            #expect(out[0].chord.lyrics == [Lyric(text: "a", syllabic: .single)])
            #expect(out[1].chord.lyrics.isEmpty)
        }

        /// `centerX` reproduces the measured 革命道中 datum exactly: the kana
        /// "む" at em 5.88 with left edge 295.14 has its centre at 298.08 —
        /// which is also where the pre-fix walker used to record its origin,
        /// and precisely why this pass was calibrated on that bug.
        @Test func centerXReproducesTheMeasuredFullWidthCase() {
            let mu = sizedGlyph("む", x: 295.14, y: 0, em: 5.88)
            #expect(abs(PDFImporter.centerX(mu) - 298.08) < 0.01)
            // A multi-character run sums its advances.
            let run = sizedGlyph("むむ", x: 295.14, y: 0, em: 5.88)
            #expect(abs(PDFImporter.centerX(run) - 301.02) < 0.01)
            // Without a page-space em there is nothing to offset by.
            var noSize = mu
            noSize.renderedSize = 0
            #expect(PDFImporter.centerX(noSize) == 295.14)
        }

        // MARK: - Measure-cell gate

        /// The cell gate must admit on the same landmark the snap compares:
        /// the syllable's CENTRE. Cell 100...200 is padded by 6, so the
        /// admitted window is 94...206. A full-width kana at left edge 90
        /// has its centre at 95 — inside the window, even though its left
        /// edge is outside. Gating on the left edge drops it.
        @Test func syllableAdmittedWhenItsCentreIsInsideTheCell() {
            let elements = [chordElement(x: 100)]
            let texts = [sizedGlyph("あ", x: 90, y: 480, em: 10)]
            let out = PDFImporter.attachLyrics(
                elements: elements, texts: texts,
                staffYLines: staffYLines, pageIndex: 0,
                xRange: 100 ... 200,
            )
            #expect(out[0].chord.lyrics == [Lyric(text: "あ", syllabic: .single)])
        }

        /// The mirror case, and the one that caused the over-production on
        /// 旅路 (countB 1328 vs countA 1214): a kana at left edge 204 is
        /// inside the 206 bound by its left edge but its centre is at 209,
        /// past the cell. It belongs to the NEXT measure and must not be
        /// claimed by this one.
        @Test func syllableRejectedWhenItsCentreIsPastTheCell() {
            let elements = [chordElement(x: 200)]
            let texts = [sizedGlyph("あ", x: 204, y: 480, em: 10)]
            let out = PDFImporter.attachLyrics(
                elements: elements, texts: texts,
                staffYLines: staffYLines, pageIndex: 0,
                xRange: 100 ... 200,
            )
            #expect(out[0].chord.lyrics.isEmpty)
        }

        // MARK: - Tests

        @Test func singleSyllableAttachesToNearestNote() {
            let elements = [chordElement(x: 100)]
            let texts = [textGlyph("Hi", x: 100, y: 480)]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out.count == 1)
            #expect(out[0].chord.lyrics == [Lyric(text: "Hi", syllabic: .single)])
        }

        @Test func hyphenStartsBeginMiddleEnd() {
            let elements = [
                chordElement(x: 100),
                chordElement(x: 200),
            ]
            let texts = [
                textGlyph("Hap-", x: 100, y: 480),
                textGlyph("py", x: 200, y: 480),
            ]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out[0].chord.lyrics == [Lyric(text: "Hap", syllabic: .begin)])
            #expect(out[1].chord.lyrics == [Lyric(text: "py", syllabic: .end)])
        }

        @Test func fourSyllableHyphenChain() {
            let elements = [
                chordElement(x: 100),
                chordElement(x: 200),
                chordElement(x: 300),
                chordElement(x: 400),
            ]
            let texts = [
                textGlyph("Hap-", x: 100, y: 480),
                textGlyph("py", x: 200, y: 480),
                textGlyph("birth-", x: 300, y: 480),
                textGlyph("day", x: 400, y: 480),
            ]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out[0].chord.lyrics == [Lyric(text: "Hap", syllabic: .begin)])
            #expect(out[1].chord.lyrics == [Lyric(text: "py", syllabic: .end)])
            #expect(out[2].chord.lyrics == [Lyric(text: "birth", syllabic: .begin)])
            #expect(out[3].chord.lyrics == [Lyric(text: "day", syllabic: .end)])
        }

        @Test func underscoreExtendsMelisma() {
            let elements = [
                chordElement(x: 100),
                chordElement(x: 200),
            ]
            let texts = [
                textGlyph("Sing", x: 100, y: 480),
                textGlyph("_", x: 200, y: 480),
            ]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            // First chord still gets a single syllable; underscore is not
            // attached as a new syllable. (Melisma `ticks` updating is
            // deferred to Task 13 assembleScore.)
            #expect(out[0].chord.lyrics.count == 1)
            #expect(out[0].chord.lyrics[0].text == "Sing")
            #expect(out[0].chord.lyrics[0].syllabic == .single)
            #expect(out[1].chord.lyrics.isEmpty)
        }

        @Test func textOutsideYWindowIsIgnored() {
            let elements = [chordElement(x: 100)]
            // y=300 is far above the staff bottom (490) — way outside the
            // four-line-spacing lyric band below it.
            let texts = [textGlyph("Nope", x: 100, y: 300)]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out[0].chord.lyrics.isEmpty)
        }
    }
#endif
