#if !os(Android)
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

        static func digit(
            _ text: String, x: CGFloat, y: CGFloat,
            width: CGFloat = 3.3, height: CGFloat = 6.0,
        ) -> TextGlyph {
            TextGlyph(
                text: text,
                fontName: "FreeSerif",
                fontSize: height,
                origin: CGPoint(x: x, y: y),
                bbox: CGRect(x: x, y: y, width: width, height: height),
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
                    "3", x: 452.0, y: 126.1, width: 4.4, height: 8.0,
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
                    "3", x: 460.0, y: 42.2, width: 6.3, height: 11.0,
                )],
                paths: Self.drumBeams,
                staffYLines: Self.drumYLines,
                xRange: Self.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.isEmpty)
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
