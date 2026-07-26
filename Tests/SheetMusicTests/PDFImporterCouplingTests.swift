#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterCouplingTests {
        /// Staff with five ascending line y-coordinates, 10pt apart.
        private func staff(bottomY: CGFloat) -> SheetMusicPDF.Staff {
            SheetMusicPDF.Staff(
                pageIndex: 0,
                yLines: (0 ..< 5).map { bottomY + 10 * CGFloat($0) },
                xRange: 100 ... 500,
                barlineCandidates: [],
            )
        }

        /// A brace glyph carrying ONLY the semantic — codepoint 0, to prove
        /// coupling no longer depends on the raw codepoint.
        private func brace(baselineY: CGFloat) -> ClassifiedGlyph {
            ClassifiedGlyph(
                raw: RawGlyph(
                    codepoint: 0, fontName: "Anything", fontSize: 20,
                    origin: CGPoint(x: 90, y: baselineY), advance: 5,
                    pageIndex: 0,
                ),
                semantic: .brace,
            )
        }

        @Test func couplesBracedPairIntoOnePart() {
            // Two staves; the brace baseline sits at the LOWER staff's bottom
            // line (yLines.first). staves arrive sorted top→bottom.
            let upper = staff(bottomY: 200)
            let lower = staff(bottomY: 100)
            let parts = PDFImporter.couplingIntoParts(
                staves: [upper, lower],
                paths: [],
                classified: [brace(baselineY: 100)],
                pageIndex: 0,
            )
            #expect(parts.count == 1)
            #expect(parts.first?.staves.count == 2)
        }

        @Test func withoutBraceEachStaffIsItsOwnPart() {
            let upper = staff(bottomY: 200)
            let lower = staff(bottomY: 100)
            // A non-brace glyph in the same place must not couple.
            let notABrace = ClassifiedGlyph(
                raw: RawGlyph(
                    codepoint: 0xE000, fontName: "Anything", fontSize: 20,
                    origin: CGPoint(x: 90, y: 100), advance: 5, pageIndex: 0,
                ),
                semantic: .noteheadBlack,
            )
            let parts = PDFImporter.couplingIntoParts(
                staves: [upper, lower], paths: [],
                classified: [notABrace], pageIndex: 0,
            )
            #expect(parts.count == 2)
        }
    }
#endif
