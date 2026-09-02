#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct PDFImporterStaffLinesTests {
        @Test func detectsFiveEvenlySpacedLinesAsStaff() {
            let paths = horizontals(at: [100, 110, 120, 130, 140], xRange: 50 ... 500)
            let staves = PDFImporter.detectStaves(paths: paths, classified: [], pageIndex: 0)
            #expect(staves.count == 1)
            #expect(staves.first?.yLines.count == 5)
            #expect(staves.first?.xRange == 50 ... 500)
        }

        @Test func ignoresFourLineBand() {
            let paths = horizontals(at: [100, 110, 120, 130], xRange: 50 ... 500)
            let staves = PDFImporter.detectStaves(paths: paths, classified: [], pageIndex: 0)
            #expect(staves.isEmpty)
        }

        @Test func detectsStaff5LinesGlyphPath() {
            let glyph = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 50, y: 100), advance: 450,
                    pageIndex: 0, fontSize: 24,
                ),
                semantic: .staff5Lines,
            )
            let staves = PDFImporter.detectStaves(paths: [], classified: [glyph], pageIndex: 0)
            #expect(staves.count == 1)
            #expect(staves.first?.yLines.count == 5)
            // lineSpacing = fontSize / 4 = 6, midline = 100 -> [88,94,100,106,112]
            #expect(staves.first?.yLines == [88, 94, 100, 106, 112])
            #expect(staves.first?.xRange == 50 ... 500)
        }

        @Test func deduplicatesGlyphAndPathDetections() {
            let paths = horizontals(at: [100, 110, 120, 130, 140], xRange: 50 ... 500)
            let glyph = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 50, y: 120), advance: 450,
                    pageIndex: 0, fontSize: 24,
                ),
                semantic: .staff5Lines,
            )
            let staves = PDFImporter.detectStaves(paths: paths, classified: [glyph], pageIndex: 0)
            #expect(staves.count == 1)
        }

        @Test func collectsBarlineCandidates() {
            var paths = horizontals(at: [100, 110, 120, 130, 140], xRange: 50 ... 500)
            paths.append(PathSegment(
                kind: .vertical,
                rect: CGRect(x: 200, y: 100, width: 0, height: 40),
                lineWidth: 0.5,
                pageIndex: 0,
            ))
            let staves = PDFImporter.detectStaves(paths: paths, classified: [], pageIndex: 0)
            #expect(staves.first?.barlineCandidates.count == 1)
        }
    }

    private func horizontals(at ys: [CGFloat], xRange: ClosedRange<CGFloat>) -> [PathSegment] {
        ys.map {
            PathSegment(
                kind: .horizontal,
                rect: CGRect(
                    x: xRange.lowerBound,
                    y: $0,
                    width: xRange.upperBound - xRange.lowerBound,
                    height: 0,
                ),
                lineWidth: 0.5,
                pageIndex: 0,
            )
        }
    }
#endif
