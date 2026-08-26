#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterStructureTests {
        private func vertical(
            x: CGFloat, lineWidth: CGFloat = 0.5,
            yRange: ClosedRange<CGFloat> = 480 ... 520,
        ) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(
                    x: x, y: yRange.lowerBound,
                    width: lineWidth,
                    height: yRange.upperBound - yRange.lowerBound,
                ),
                lineWidth: lineWidth, pageIndex: 0,
            )
        }

        private func rectangle(
            _ rect: CGRect, lineWidth: CGFloat = 0.5,
        ) -> PathSegment {
            PathSegment(
                kind: .rectangle, rect: rect,
                lineWidth: lineWidth, pageIndex: 0,
            )
        }

        private func dotsGlyph(at point: CGPoint) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: point, advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .repeatBarlineDots,
            )
        }

        private func text(
            _ str: String, at origin: CGPoint,
            fontSize: CGFloat = 10,
        ) -> TextGlyph {
            // Approx bbox: width ≈ str.count * 0.6 * fontSize, height ≈ fontSize.
            let width = CGFloat(str.count) * 0.6 * fontSize
            return TextGlyph(
                text: str, fontName: "Helvetica",
                fontSize: fontSize, origin: origin,
                bbox: CGRect(
                    x: origin.x, y: origin.y,
                    width: width, height: fontSize,
                ),
                pageIndex: 0,
            )
        }

        // MARK: - classifyBarline

        @Test func startRepeatBarline() {
            let primary = vertical(x: 200, lineWidth: 1.6)
            let dots = dotsGlyph(at: CGPoint(x: 210, y: 500))
            let bar = PDFImporter.classifyBarline(
                primary: primary,
                in: 200 ... 400,
                paths: [primary],
                glyphs: [dots],
            )
            #expect(bar.subtype == "start-repeat")
        }

        @Test func endRepeatBarline() {
            let primary = vertical(x: 400, lineWidth: 1.6)
            let dots = dotsGlyph(at: CGPoint(x: 392, y: 500))
            let bar = PDFImporter.classifyBarline(
                primary: primary,
                in: 200 ... 400,
                paths: [primary],
                glyphs: [dots],
            )
            #expect(bar.subtype == "end-repeat")
        }

        @Test func doubleBarline() {
            let primary = vertical(x: 200, lineWidth: 0.5)
            let secondary = vertical(x: 204, lineWidth: 0.5)
            let bar = PDFImporter.classifyBarline(
                primary: primary,
                in: 100 ... 300,
                paths: [primary, secondary],
                glyphs: [],
            )
            #expect(bar.subtype == "double")
        }

        @Test func singleBarlineDefault() {
            let primary = vertical(x: 200, lineWidth: 0.5)
            let bar = PDFImporter.classifyBarline(
                primary: primary,
                in: 100 ... 300,
                paths: [primary],
                glyphs: [],
            )
            #expect(bar.subtype == nil)
        }

        // MARK: - detectVoltas

        @Test func detectsVolta1Bracket() {
            // System top y=480; volta rectangle above (y > 480), measure 0
            // and measure 1 covered, with "1." text inside.
            let measures: [(index: Int, xRange: ClosedRange<CGFloat>)] = [
                (0, 100 ... 200),
                (1, 200 ... 300),
                (2, 300 ... 400),
            ]
            let rect = rectangle(CGRect(x: 100, y: 460, width: 200, height: 12))
            let label = text("1.", at: CGPoint(x: 105, y: 462), fontSize: 8)
            let result = PDFImporter.detectVoltas(
                measures: measures,
                paths: [rect],
                texts: [label],
                systemTopY: 480, pageIndex: 0,
            )
            #expect(result.count == 1)
            #expect(result.first?.measureIndex == 0)
            #expect(result.first?.spanner.kind == .volta)
            #expect(result.first?.spanner.voltaEndings == [1])
            #expect(result.first?.spanner.nextMeasuresOffset == 1)
        }

        // MARK: - detectRehearsalMarks

        @Test func detectsRehearsalMarkA() {
            let measures: [(index: Int, xRange: ClosedRange<CGFloat>)] = [
                (0, 100 ... 200),
                (1, 200 ... 300),
            ]
            let box = rectangle(CGRect(x: 100, y: 460, width: 14, height: 14))
            let label = text("A", at: CGPoint(x: 103, y: 462), fontSize: 10)
            let result = PDFImporter.detectRehearsalMarks(
                measures: measures,
                paths: [box],
                texts: [label],
                systemTopY: 480, pageIndex: 0,
            )
            #expect(result.count == 1)
            #expect(result.first?.measureIndex == 0)
            #expect(result.first?.mark.text == "A")
        }

        // MARK: - detectMarkersAndJumps

        @Test func parsesDCAlFine() {
            let measures: [(index: Int, xRange: ClosedRange<CGFloat>)] = [
                (0, 100 ... 200),
                (1, 200 ... 300),
                (2, 300 ... 400),
            ]
            // Right-end of last measure is x≈400.
            let label = text(
                "D.C. al Fine",
                at: CGPoint(x: 360, y: 470),
                fontSize: 10,
            )
            let result = PDFImporter.detectMarkersAndJumps(
                texts: [label],
                measures: measures,
                systemTopY: 480, pageIndex: 0,
            )
            #expect(result.markers.isEmpty)
            #expect(result.jumps.count == 1)
            #expect(result.jumps.first?.measureIndex == 2)
            #expect(result.jumps.first?.jump.jumpTo == "start")
            #expect(result.jumps.first?.jump.playUntil == "fine")
            #expect(result.jumps.first?.jump.text == "D.C. al Fine")
        }

        @Test func parsesSegnoMarker() {
            let measures: [(index: Int, xRange: ClosedRange<CGFloat>)] = [
                (0, 100 ... 200),
                (1, 200 ... 300),
            ]
            // Near left end of measure 1.
            let label = text("Segno", at: CGPoint(x: 205, y: 470), fontSize: 10)
            let result = PDFImporter.detectMarkersAndJumps(
                texts: [label],
                measures: measures,
                systemTopY: 480, pageIndex: 0,
            )
            #expect(result.jumps.isEmpty)
            #expect(result.markers.count == 1)
            #expect(result.markers.first?.measureIndex == 1)
            #expect(result.markers.first?.marker.kind == .segno)
            #expect(result.markers.first?.marker.text == "Segno")
        }
    }
#endif
