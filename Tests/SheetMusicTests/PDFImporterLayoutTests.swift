#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterLayoutTests {
        private func staff(
            yMid: CGFloat,
            xRange: ClosedRange<CGFloat>,
            barlineXs: [CGFloat],
        ) -> Staff {
            let yLines = (-2 ... 2).map { yMid + CGFloat($0) * 5 }
            let yLo = yLines.first ?? yMid
            let yHi = yLines.last ?? yMid
            let bars = barlineXs.map {
                PathSegment(
                    kind: .vertical,
                    rect: CGRect(x: $0, y: yLo, width: 0, height: yHi - yLo),
                    lineWidth: 0.5,
                    pageIndex: 0,
                )
            }
            return Staff(
                pageIndex: 0,
                yLines: yLines,
                xRange: xRange,
                barlineCandidates: bars,
            )
        }

        @Test func twoNearStavesFormOneSystem() {
            let s1 = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let s2 = staff(yMid: 660, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let systems = PDFImporter.layoutSystems(
                staves: [s1, s2], paths: [], classified: [], pageIndex: 0,
            )
            #expect(systems.count == 1)
            #expect(systems.first?.parts.flatMap(\.staves).count == 2)
        }

        @Test func farStavesSplitIntoTwoSystems() {
            let s1 = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [550])
            let s2 = staff(yMid: 200, xRange: 50 ... 550, barlineXs: [550])
            let systems = PDFImporter.layoutSystems(
                staves: [s1, s2], paths: [], classified: [], pageIndex: 0,
            )
            #expect(systems.count == 2)
        }

        @Test func barlinesSplitMeasures() {
            let s = staff(yMid: 500, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let systems = PDFImporter.layoutSystems(
                staves: [s], paths: [], classified: [], pageIndex: 0,
            )
            let measures = systems.first?.parts.first?.staves.first?.measures ?? []
            // 3 cells: (50,200), (200,400), (400,550)
            #expect(measures.count == 3)
            #expect(abs(measures[0].xRange.lowerBound - 50) < 1)
            #expect(abs(measures[2].xRange.upperBound - 550) < 1)
        }

        @Test func bracketCouplesGrandStaff() {
            let upper = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [550])
            let lower = staff(yMid: 660, xRange: 50 ... 550, barlineXs: [550])
            let bracket = PathSegment(
                kind: .vertical,
                rect: CGRect(x: 48, y: 658, width: 0, height: 44),
                lineWidth: 1.5, pageIndex: 0,
            )
            let systems = PDFImporter.layoutSystems(
                staves: [upper, lower], paths: [bracket],
                classified: [], pageIndex: 0,
            )
            #expect(systems.first?.parts.count == 1)
            #expect(systems.first?.parts.first?.staves.count == 2)
        }

        @Test func glyphsAreAssignedToTheirMeasureCell() {
            let s = staff(yMid: 500, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let g = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 250, y: 500), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .noteheadBlack,
            )
            let systems = PDFImporter.layoutSystems(
                staves: [s], paths: [], classified: [g], pageIndex: 0,
            )
            let measures = systems.first?.parts.first?.staves.first?.measures ?? []
            #expect(measures[0].glyphs.isEmpty)
            #expect(measures[1].glyphs.count == 1)
            #expect(measures[2].glyphs.isEmpty)
        }

        @Test func crossStaffAlignmentUnifiesBarlines() {
            let s1 = staff(yMid: 700, xRange: 50 ... 550, barlineXs: [200, 400, 550])
            let s2 = staff(yMid: 660, xRange: 50 ... 550, barlineXs: [400, 550])
            let systems = PDFImporter.layoutSystems(
                staves: [s1, s2], paths: [], classified: [], pageIndex: 0,
            )
            let counts = systems.first?.parts.flatMap { $0.staves.map(\.measures.count) }
            #expect(counts == [3, 3])
        }
    }
#endif
