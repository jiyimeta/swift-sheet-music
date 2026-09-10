#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @Suite("PDF producer identity")
    struct PDFProducerIdentityTests {
        @Test func assemblyIdentifiesItsScore() {
            let lines: [CGFloat] = [490, 495, 500, 505, 510]
            let staff = SheetMusicPDF.Staff(
                pageIndex: 0, yLines: lines, xRange: 50 ... 550, barlineCandidates: [],
            )
            let measure = ImportMeasure(
                xRange: 50 ... 550, glyphs: [], leadingBarline: nil,
                trailingBarline: nil, staffYLines: lines,
            )
            let system = ImportSystem(
                pageIndex: 0, yRange: 480 ... 520,
                parts: [ImportPart(staves: [ImportStaff(staff: staff, measures: [measure])])],
            )
            let score = PDFImporter.assembleScore(
                firstPageSize: nil, documentAttributes: nil, systems: [system],
                texts: [], classified: [], paths: [], options: PDFImportOptions(),
            )
            #expect(score.parts.count == 1)
            #expect(score.parts[0].staves.count == 1)
            #expect(!score.hasUnassignedIDs)
        }
    }
#endif
