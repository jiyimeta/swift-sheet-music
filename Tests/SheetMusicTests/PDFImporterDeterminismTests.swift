#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// The importer must not depend on Dictionary / Set iteration order.
    /// Swift randomizes hash seeds per process, but within one process a
    /// repeated parse of identical input must be bit-stable — and any
    /// order-dependent pass shows up as instability across shuffled input
    /// that is geometrically identical.
    @MainActor struct PDFImporterDeterminismTests {
        private func glyph(
            x: CGFloat, y: CGFloat, _ semantic: SMuFLSemantic,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: semantic,
            )
        }

        @Test func staffDetectionIsOrderIndependent() {
            let paths = (0 ..< 5).map { i in
                PathSegment(
                    kind: .horizontal,
                    rect: CGRect(
                        x: 100,
                        y: 100 + CGFloat(i) * 10,
                        width: 400,
                        height: 0,
                    ),
                    lineWidth: 0.5, pageIndex: 0,
                )
            }
            let glyphs = [
                glyph(x: 150, y: 120, .noteheadBlack),
                glyph(x: 200, y: 130, .noteheadBlack),
                glyph(x: 250, y: 110, .noteheadBlack),
            ]
            let a = PDFImporter.detectStaves(
                paths: paths, classified: glyphs, pageIndex: 0,
            )
            let b = PDFImporter.detectStaves(
                paths: paths.reversed(), classified: glyphs.reversed(),
                pageIndex: 0,
            )
            #expect(a.count == b.count)
            #expect(a.first?.yLines == b.first?.yLines)
            #expect(a.first?.xRange == b.first?.xRange)
        }
    }
#endif
