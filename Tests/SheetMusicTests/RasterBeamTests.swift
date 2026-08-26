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

        /// Two 0.5 sp beams a 0.25 sp gap apart over [x0, x1), with the
        /// gap inked — the pair FUSED — over [f0, f1).
        static func fusedStack(x0: Int, x1: Int, f0: Int, f1: Int) -> GrayBitmap {
            var bmp = Self.page()
            RasterTestBitmaps.hLine(&bmp, y: 80, x0: x0, x1: x1, thickness: 6)
            RasterTestBitmaps.hLine(&bmp, y: 89, x0: x0, x1: x1, thickness: 6)
            RasterTestBitmaps.hLine(&bmp, y: 86, x0: f0, x1: f1, thickness: 3)
            return bmp
        }

        /// ONE inked column across the gap used to cost the stack a whole
        /// beam. The merged column is a single run, so the first slab took
        /// it and the second starved — but the worse half is what it did to
        /// the slab that took it: that column's y-range is the whole
        /// 1.25 sp band inside an interval the median smoothing still calls
        /// one level, and `quads` fails the WHOLE interval on straightness
        /// and drops it. One beam is left where the page has two, one beam
        /// pitch away — which is the corpus's dominant beam loss (114 of
        /// 199 unmatched truth beams).
        @Test func aSingleFusedColumnKeepsBothBeams() {
            let bmp = Self.fusedStack(x0: 60, x1: 260, f0: 150, f1: 151)
            let segs = Self.beams(bmp)
            #expect(segs.count == 2)
            let tops = segs.compactMap { $0.quad?.topIntercept }.sorted()
            guard tops.count == 2 else {
                Issue.record("expected two levels, got \(tops.count)")
                return
            }
            // One beam pitch apart: 0.75 sp = 9px = 2.16pt.
            #expect(abs(Double(tops[1] - tops[0]) - 2.16) < 0.3)
        }

        /// A fusion long enough to exhaust the starved slab's bridge costs
        /// the group's x-range rather than a level: both beams arrive as
        /// fragments that stop either side of the fused stretch. Sharing
        /// the merged columns keeps each one whole.
        @Test func aFusedStretchDoesNotFragmentTheStack() {
            let bmp = Self.fusedStack(x0: 60, x1: 260, f0: 150, f1: 166)
            let segs = Self.beams(bmp)
            #expect(segs.count == 2)
            // 200px at 300dpi is 48pt; a fragment would be under half that.
            for seg in segs {
                #expect(Double(seg.rect.width) > 45)
            }
        }

        /// Two beams that are NOT fused are simply two slabs, even when
        /// one is shorter than the other — no splitting involved.
        @Test func anUnfusedPartialSecondaryIsJustTwoBeams() {
            var bmp = Self.page()
            Self.slopedBeam(&bmp, x0: 60, x1: 300, y0: 80, dy: 0, thickness: 6)
            Self.slopedBeam(&bmp, x0: 60, x1: 180, y0: 89, dy: 0, thickness: 6)
            #expect(Self.beams(bmp).count == 2)
        }

        /// A flat 0.5 sp beam over [x0, x1) with the single column at
        /// `speckleX` lifted `dy` px — one bad column on an edge that is
        /// otherwise perfectly straight.
        static func speckledBeam(
            x0: Int, x1: Int, y0: Int, speckleX: Int, dy: Int,
        ) -> GrayBitmap {
            var bmp = Self.page()
            for x in x0 ..< x1 {
                RasterTestBitmaps.vLine(
                    &bmp, x: x, y0: x == speckleX ? y0 - dy : y0,
                    y1: (x == speckleX ? y0 - dy : y0) + 6, thickness: 1,
                )
            }
            return bmp
        }

        /// ONE speckled column used to cost the whole beam, and that —
        /// not fusion — is what the corpus was losing.
        ///
        /// The straightness gate is 0.12 sp, here 1.44px. A single column
        /// 3px off an otherwise exact edge takes the residual to ~3px, and
        /// `quads` dropped the WHOLE interval on it. Measured on v2-eval,
        /// every one of the 114 unmatched truth beams with a prediction
        /// one beam pitch away sits under an interval dropped this way,
        /// and 83 of them miss the gate by under 0.13 sp — speckle, not
        /// curved ink.
        @Test func aSpeckledColumnDoesNotCostTheWholeBeam() {
            let bmp = Self.speckledBeam(x0: 60, x1: 260, y0: 90, speckleX: 150, dy: 3)
            let segs = Self.beams(bmp)
            #expect(segs.count == 1)
            // The whole run, not the part either side of the speckle.
            #expect(Double(segs.first?.rect.width ?? 0) > 45)
        }

        /// …and the refit must not turn a CURVE into a beam. A slur is
        /// not detected as anything yet, so on a page where one grazes a
        /// stem row the only thing keeping it out of the beam stream is
        /// this gate. A curve misses it everywhere: the columns within
        /// tolerance of its own chord are two thin bands either side of
        /// the quarter points, about a third of the run, which is what
        /// `beamTrimKeepFraction` rejects.
        @Test func aCurvedBandIsStillNotABeam() {
            var bmp = Self.page()
            for x in 60 ..< 260 {
                let t = Double(x - 60) / 200
                let y = 90 - Int((32 * t * (1 - t)).rounded())
                RasterTestBitmaps.vLine(&bmp, x: x, y0: y, y1: y + 6, thickness: 1)
            }
            #expect(Self.beams(bmp).isEmpty)
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
