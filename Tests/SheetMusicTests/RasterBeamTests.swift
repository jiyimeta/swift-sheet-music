#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct RasterBeamTests {
        static let spacing = 12.0

        static func transform(_ bmp: GrayBitmap) -> PageTransform {
            PageTransform(
                dpi: bmp.dpi, widthPx: bmp.width, heightPx: bmp.height,
                deskewDegrees: 0,
            )
        }

        static func beams(_ bmp: GrayBitmap) -> [PathSegment] {
            RasterPage.beamSegments(
                RasterPage.binarize(bmp), spacingPx: spacing,
                transform: transform(bmp), pageIndex: 0,
            )
        }

        /// A beam of `thickness` px descending `dy` px over [x0, x1).
        static func slopedBeam(
            _ bmp: inout GrayBitmap, x0: Int, x1: Int, y0: Int, dy: Int, thickness: Int,
        ) {
            for x in x0 ..< x1 {
                let t = Double(x - x0) / Double(x1 - x0)
                let y = y0 + Int((Double(dy) * t).rounded())
                RasterTestBitmaps.vLine(&bmp, x: x, y0: y, y1: y + thickness, thickness: 1)
            }
        }

        static func page() -> GrayBitmap {
            RasterTestBitmaps.blank(widthPx: 400, heightPx: 200, dpi: 300)
        }

        @Test func aFlatBeamIsFoundWithZeroSlope() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 90, dy: 0, thickness: 6)
            let segs = Self.beams(bmp)
            #expect(segs.count == 1)
            #expect(segs[0].kind == .beam)
            #expect(abs(Double(segs[0].quad?.topSlope ?? 1)) < 0.02)
        }

        /// Raster y grows downward and page y grows upward, so a beam
        /// descending in the raster has a NEGATIVE page-space slope. The
        /// beam here drops 20px over 200px.
        @Test func aSlopedBeamKeepsItsSlope() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 70, dy: 20, thickness: 6)
            let segs = Self.beams(bmp)
            #expect(segs.count == 1)
            #expect(abs(Double(segs[0].quad?.topSlope ?? 0) - -0.1) < 0.02)
        }

        /// A staff line is ~0.1 staff spaces thick and a notehead ~1.0.
        /// The k = 1 rung is 0.5 and the k = 2 rung 1.25, so both land in
        /// a ladder dead zone — that is the quantization earning its keep.
        @Test func staffLinesAndNoteheadsAreNotBeams() {
            var bmp = Self.page()
            RasterTestBitmaps.hLine(&bmp, y: 40, x0: 20, x1: 380, thickness: 1)
            RasterTestBitmaps.hLine(&bmp, y: 120, x0: 100, x1: 116, thickness: 12)
            #expect(Self.beams(bmp).isEmpty)
        }

        @Test func twoSeparateBeamsStayTwoBeams() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 80, dy: 0, thickness: 6)
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 95, dy: 0, thickness: 6)
            #expect(Self.beams(bmp).count == 2)
        }

        /// The measurement that made this necessary: 7.27% of stacked
        /// pairs have their gap closed by the degradation profile. A
        /// fused pair is 1.25 staff spaces — 15px here — which a
        /// single-beam window would REJECT, costing the group every beam
        /// level rather than one.
        @Test func aFusedPairIsSplitBackIntoTwoBeams() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 80, dy: 0, thickness: 15)
            let segs = Self.beams(bmp)
            #expect(segs.count == 2)
            let tops = segs.compactMap { $0.quad?.topIntercept }.sorted()
            // The two levels must be one pitch (0.75 sp = 9px = 2.16pt)
            // apart, not stacked on top of each other.
            #expect(abs(Double(tops[1] - tops[0]) - 2.16) < 0.3)
        }

        @Test func aFusedTripleIsSplitIntoThree() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 80, dy: 0, thickness: 24)
            #expect(Self.beams(bmp).count == 3)
        }

        /// The shortest beam measured on this dataset is 1.30 staff
        /// spaces — the hook of a dotted-eighth pair. A 1.5 sp gate would
        /// have discarded every one of them.
        @Test func aHookLengthBeamSurvivesTheExtentGate() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 100, x1: 116, y0: 90, dy: 0, thickness: 6)
            #expect(Self.beams(bmp).count == 1)
        }

        /// A stem crossing a beam merges into one long column run that
        /// lands on no ladder rung. Without bridging, the slab would end
        /// at every stem and a beam would arrive as fragments, most of
        /// them under the extent gate.
        @Test func aStemCrossingDoesNotSplitTheBeam() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 90, dy: 0, thickness: 6)
            for x in [100, 160, 220] {
                RasterTestBitmaps.vLine(&bmp, x: x, y0: 90, y1: 140, thickness: 2)
            }
            let segs = Self.beams(bmp)
            #expect(segs.count == 1)
            #expect(Double(segs[0].rect.width) > 40)
        }

        /// A secondary beam covering only part of a group, FUSED to the
        /// primary, gives one slab that is genuinely two levels thick
        /// over part of its x-range and one over the rest: 15px
        /// (1.25 sp) for x in [60, 180) and 6px (0.5 sp) after it. Taking
        /// one level for the whole slab would either reject it — its
        /// median thickness landing in a ladder dead zone — or invent a
        /// phantom second beam across the single-beam part.
        @Test func aPartialSecondaryBeamSplitsAlongX() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 180, y0: 80, dy: 0, thickness: 15)
            Self.slopedBeam(&bmp, x0: 180, x1: 300, y0: 80, dy: 0, thickness: 6)
            let segs = Self.beams(bmp)
            #expect(segs.count == 3)
        }

        /// Two beams that are NOT fused are simply two slabs, even when
        /// one is shorter than the other — no splitting involved.
        @Test func anUnfusedPartialSecondaryIsJustTwoBeams() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 300, y0: 80, dy: 0, thickness: 6)
            Self.slopedBeam(&bmp, x0: 60, x1: 180, y0: 89, dy: 0, thickness: 6)
            #expect(Self.beams(bmp).count == 2)
        }

        @Test func theQuadEdgesBracketTheSlab() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 260, y0: 90, dy: 0, thickness: 6)
            let quad = try? #require(Self.beams(bmp).first?.quad)
            let x = ((quad?.xRange.lowerBound ?? 0) + (quad?.xRange.upperBound ?? 0)) / 2
            let top = (quad?.topSlope ?? 0) * x + (quad?.topIntercept ?? 0)
            let bottom = (quad?.botSlope ?? 0) * x + (quad?.botIntercept ?? 0)
            #expect(top > bottom)
            #expect(abs(Double(top - bottom) - 6 * 72.0 / 300.0) < 0.2)
        }

        @Test func ladderRungsAreTheMeasuredThicknesses() {
            #expect(RasterPage.ladderThicknessInSpaces(levels: 1) == 0.5)
            #expect(RasterPage.ladderThicknessInSpaces(levels: 2) == 1.25)
            #expect(RasterPage.ladderThicknessInSpaces(levels: 3) == 2.0)
            #expect(RasterPage.ladderThicknessInSpaces(levels: 4) == 2.75)
        }

        @Test func aRunBetweenRungsLandsOnNoLevel() {
            // 1.0 staff space — a notehead's column run — sits in the
            // dead zone between the k = 1 and k = 2 rungs.
            #expect(RasterPage.beamLevels(runLengthPx: 12, spacingPx: 12) == nil)
            #expect(RasterPage.beamLevels(runLengthPx: 6, spacingPx: 12) == 1)
            #expect(RasterPage.beamLevels(runLengthPx: 15, spacingPx: 12) == 2)
        }
    }
#endif
