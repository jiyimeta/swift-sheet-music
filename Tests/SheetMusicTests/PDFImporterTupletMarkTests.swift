#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct PDFImporterTupletMarkTests {
        static let staffYLines: [CGFloat] = [498.3, 501.6, 505.0, 508.3, 511.7]
        static let cellX: ClosedRange<CGFloat> = 65.1 ... 216.0

        /// A degenerate 1-D segment, the shape the content-stream walker
        /// emits for a stroked line.
        static func seg(
            _ kind: PathSegment.Kind,
            x: CGFloat, y: CGFloat, w: CGFloat = 0, h: CGFloat = 0,
        ) -> PathSegment {
            PathSegment(
                kind: kind,
                rect: CGRect(x: x, y: y, width: w, height: h),
                lineWidth: 0.5,
                pageIndex: 0,
                quad: nil,
            )
        }

        /// A digit in the shape the REAL content-stream walker emits.
        ///
        /// Two things here are deliberately faithful to production rather
        /// than convenient:
        ///
        /// - `bbox` is `.zero`. `emitTextGlyph` hardcodes that and nothing
        ///   fills it in later, so a fixture carrying a real rect would let
        ///   a detector that reads `bbox` pass here while never matching
        ///   anything on a real file — which is exactly what happened.
        /// - `fontSize` is the raw text-space `Tf` operand, so it is set to
        ///   `em / ctmScale`, NOT to `em`. Anything geometric must come from
        ///   `renderedSize`; a detector that reaches for `fontSize` will be
        ///   wrong by the CTM and these fixtures will show it.
        ///
        /// `em` is the page-space em. The digit's width is derived from it
        /// by the detector (`em * tupletDigitWidthPerEm`), matching the
        /// `pdftotext -bbox` ground truth: a 6.0pt em gives 3.306pt of ink.
        static func digit(
            _ text: String, x: CGFloat, y: CGFloat,
            em: CGFloat = 6.0, ctmScale: CGFloat = 0.2,
        ) -> TextGlyph {
            TextGlyph(
                text: text,
                fontName: "FreeSerif",
                fontSize: em / ctmScale,
                renderedSize: em,
                origin: CGPoint(x: x, y: y),
                bbox: .zero,
                pageIndex: 0,
            )
        }

        /// The five staff lines every cell carries. They must never be
        /// mistaken for bracket arms.
        static var staffLines: [PathSegment] {
            staffYLines.map { seg(.horizontal, x: 65.1, y: $0, w: 151.2) }
        }

        /// 君とParadiso p0 m0: a bracket over a triplet quarter + eighth.
        static var bracketPaths: [PathSegment] {
            staffLines + [
                seg(.horizontal, x: 178.2, y: 518.7, w: 10.9),
                seg(.horizontal, x: 195.5, y: 518.7, w: 10.9),
                seg(.vertical, x: 178.2, y: 516.2, h: 2.5),
                seg(.vertical, x: 206.4, y: 516.2, h: 2.5),
            ]
        }

        @Test func bracketAnchorSpansItsOuterArms() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [Self.digit("3", x: 190.8, y: 517.0)],
                paths: Self.bracketPaths,
                staffYLines: Self.staffYLines,
                xRange: Self.cellX,
                pageIndex: 0,
            )
            #expect(marks.count == 1)
            #expect(marks.first?.anchor == .bracket)
            #expect(marks.first?.normal == 2)
            #expect(marks.first?.actual == 3)
            let span = try? #require(marks.first?.xRange)
            #expect(abs((span?.lowerBound ?? 0) - 178.2) < 0.01)
            #expect(abs((span?.upperBound ?? 0) - 206.4) < 0.01)
        }

        @Test func digitWithNoAnchorIsRejected() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [Self.digit("3", x: 190.8, y: 517.0)],
                paths: Self.staffLines,
                staffYLines: Self.staffYLines,
                xRange: Self.cellX,
                pageIndex: 0,
            )
            #expect(marks.isEmpty)
        }

        @Test func sixIsATupletDigitAndFiveIsNot() {
            let six = PDFImporter.detectTupletMarks(
                texts: [Self.digit("6", x: 190.8, y: 517.0)],
                paths: Self.bracketPaths,
                staffYLines: Self.staffYLines,
                xRange: Self.cellX,
                pageIndex: 0,
            )
            #expect(six.first?.normal == 4)
            #expect(six.first?.actual == 6)

            let five = PDFImporter.detectTupletMarks(
                texts: [Self.digit("5", x: 190.8, y: 517.0)],
                paths: Self.bracketPaths,
                staffYLines: Self.staffYLines,
                xRange: Self.cellX,
                pageIndex: 0,
            )
            #expect(five.isEmpty)
        }

        static let drumYLines: [CGFloat] = [107.9, 110.7, 113.5, 116.4, 119.2]
        static let drumCellX: ClosedRange<CGFloat> = 450.0 ... 552.8

        static func beam(
            xLo: CGFloat, xHi: CGFloat, yLo: CGFloat, yHi: CGFloat,
        ) -> PathSegment {
            PathSegment(
                kind: .beam,
                rect: CGRect(x: xLo, y: yLo, width: xHi - xLo, height: yHi - yLo),
                lineWidth: 1,
                pageIndex: 0,
                quad: BeamQuad(
                    xRange: xLo ... xHi,
                    topSlope: 0, topIntercept: yHi,
                    botSlope: 0, botIntercept: yLo,
                    pageIndex: 0,
                ),
            )
        }

        static var drumStaffLines: [PathSegment] {
            drumYLines.map { seg(.horizontal, x: 450.3, y: $0, w: 102.5) }
        }

        /// Primary beam over five stems plus the secondary over the
        /// triplet's three. The number must pick the NARROWER one.
        static var drumBeams: [PathSegment] {
            drumStaffLines + [
                beam(xLo: 457.3, xHi: 480.1, yLo: 124.2, yHi: 125.6),
                beam(xLo: 457.3, xHi: 467.9, yLo: 122.1, yHi: 123.5),
                beam(xLo: 472.8, xHi: 480.1, yLo: 122.1, yHi: 123.5),
            ]
        }

        @Test func beamAnchorPicksTheNarrowestBeamOverTheDigit() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [Self.digit("3", x: 461.16, y: 126.1)],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.count == 1)
            #expect(marks.first?.anchor == .beam)
            let span = try? #require(marks.first?.xRange)
            // The 457.3..467.9 secondary, not the 457.3..480.1 primary.
            #expect(abs((span?.upperBound ?? 0) - 467.9) < 0.01)
        }

        /// A measure number sits at the system's left edge with no beam or
        /// bracket beneath it. Measured on 君とParadiso: 8pt tall at
        /// x ≈ 46–56, versus a 6pt tuplet number over its beam.
        @Test func measureNumberAtTheSystemEdgeIsRejected() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [Self.digit(
                    "3", x: 452.0, y: 126.1, em: 8.0,
                )],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.isEmpty)
        }

        /// A digit sitting just outside the mark band in y, but still
        /// within `beamWindow`'s own y-tolerance and in x over the
        /// secondary beam, is rejected by the mark-band gate ALONE — the
        /// anchor search never runs. This is the load-bearing counterpart
        /// to `pageNumberInTheMarginIsRejected`, which sits far enough
        /// away that either gate would reject it on its own.
        ///
        /// spatium = (119.2 - 107.9) / 4 = 2.825; band = 3 * 2.825 =
        /// 8.475, so the band's outer edge is 119.2 + 8.475 = 127.675.
        /// beamWindow's own y-tolerance is 3 * 2.825 = 8.475 around the
        /// secondary beam's midY (122.8), i.e. up to 131.275. A digit at
        /// y = 128.5 clears the beam tolerance but sits 0.825 past the
        /// band's edge.
        @Test func digitOutsideTheMarkBandIsRejectedByTheBandGateAlone() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [Self.digit("3", x: 461.16, y: 128.5)],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.isEmpty)
        }

        /// A page number lives in the page margin, far outside both the
        /// mark band and `beamWindow`'s own y-tolerance around any beam —
        /// an end-to-end guard confirming a page number never becomes a
        /// tuplet mark, redundantly protected by two independent gates
        /// rather than isolating either one.
        @Test func pageNumberInTheMarginIsRejected() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [Self.digit(
                    "3", x: 460.0, y: 42.2, em: 11.0,
                )],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.isEmpty)
        }

        /// THE REGRESSION GUARD. A glyph carrying `bbox: .zero` — byte for
        /// byte what `emitTextGlyph` actually produces — must still be
        /// found.
        ///
        /// This is the test whose absence let sixteen green unit tests
        /// coexist with a detector that never fired once on a real file.
        /// Every fixture here used to hand the detector a fully populated
        /// `bbox`, so `beamWindow` reading `bbox.midX` looked correct; in
        /// production that read returned 0, every digit's x collapsed to the
        /// page origin, no beam ever contained it, and the pass silently did
        /// nothing across a 135-score corpus.
        ///
        /// Constructed inline rather than through `digit(...)` on purpose:
        /// if someone later "helpfully" gives the shared helper a real bbox
        /// again, this test must keep testing the production shape.
        @Test func digitWithAZeroBBoxIsStillDetected() {
            let glyph = TextGlyph(
                text: "3",
                fontName: "FreeSerif",
                fontSize: 30, // raw Tf; page-space em = 30 * 0.2 = 6.0
                renderedSize: 6.0,
                origin: CGPoint(x: 461.16, y: 126.1),
                bbox: .zero, // exactly what emitTextGlyph writes
                pageIndex: 0,
            )
            #expect(glyph.bbox == .zero)
            let marks = PDFImporter.detectTupletMarks(
                texts: [glyph],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.count == 1)
            #expect(marks.first?.anchor == .beam)
            #expect(marks.first?.actual == 3)
            // The digit's centre must land inside the secondary beam, which
            // is only possible if the extent came from origin.x + a real
            // width rather than from the empty bbox.
            let centre = try? #require(marks.first?.digitCenterX)
            #expect((centre ?? 0) > 461.16)
            #expect(abs((marks.first?.xRange.upperBound ?? 0) - 467.9) < 0.01)
        }

        /// The same physical digit engraved through a different CTM must
        /// detect identically.
        ///
        /// ロビンソン draws its digits at `Tf` 89 under a 0.06 CTM where the
        /// other five curated scores use `Tf` 30-40 under a 0.2 one — same
        /// ink on the page, raw `fontSize` 3.3x apart. A width derived from
        /// `fontSize` would be 3.3x too wide there; one derived from
        /// `renderedSize` is identical. This pins that the detector reads
        /// the page-space size and not the raw operand.
        @Test func detectionIsIndependentOfTheContentStreamCTM() {
            let museScoreLike = PDFImporter.detectTupletMarks(
                texts: [Self.digit("3", x: 461.16, y: 126.1, em: 6.0, ctmScale: 0.2)],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            let robinsonLike = PDFImporter.detectTupletMarks(
                texts: [Self.digit("3", x: 461.16, y: 126.1, em: 6.0, ctmScale: 0.06)],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(museScoreLike.count == 1)
            #expect(robinsonLike == museScoreLike)
        }

        /// The extent must reproduce the `pdftotext -bbox` ground truth the
        /// width factor was derived from.
        @Test func digitExtentMatchesTheMeasuredGroundTruth() {
            // 君とParadiso tuplet "3": em 6.000, measured ink width 3.306.
            let kimi = Self.digit("3", x: 100, y: 0, em: 6.0)
            let kimiWidth = PDFImporter.digitExtent(kimi).upperBound
                - PDFImporter.digitExtent(kimi).lowerBound
            #expect(abs(kimiWidth - 3.306) < 0.005)
            // Now_is_the_time tuplet "3": em 5.200, measured ink width 2.865.
            let now = Self.digit("3", x: 100, y: 0, em: 5.2)
            let nowWidth = PDFImporter.digitExtent(now).upperBound
                - PDFImporter.digitExtent(now).lowerBound
            #expect(abs(nowWidth - 2.865) < 0.005)
            // The extent starts at the pen position, not centred on it.
            #expect(PDFImporter.digitExtent(kimi).lowerBound == 100)
        }

        /// A digit belonging to another page must not be claimed.
        @Test func digitOnAnotherPageIsIgnored() {
            var other = Self.digit("3", x: 461.16, y: 126.1)
            other.pageIndex = 1
            let marks = PDFImporter.detectTupletMarks(
                texts: [other],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.isEmpty)
        }
    }
#endif
