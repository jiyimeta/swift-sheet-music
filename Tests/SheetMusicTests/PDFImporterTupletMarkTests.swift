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
    }
#endif
