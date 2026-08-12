#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// A beamed group, drawn as ink, put through the real front-end.
    ///
    /// Why a synthetic page rather than a corpus sweep: the question here
    /// is a MECHANISM — does a beam's fitted x-range reach the outermost
    /// stems of its own group? — and a sweep can only answer it
    /// statistically, after half an hour, mixed with every other effect on
    /// the page. Here the answer is a deterministic four-stem picture.
    ///
    /// The geometry is the one the detector actually has to survive: a
    /// beam ends FLUSH with the outer edge of its outer stems, and at
    /// every stem column the ink run is beam + stem merged, which lands on
    /// no ladder rung and so contributes no column to the slab. The outer
    /// stems therefore sit at the two x positions the fitted quad
    /// structurally cannot cover.
    struct RasterBeamedStemProbeTests {
        static let dpi = 300.0
        static let spacingPx = 20
        static let stemWidthPx = 3
        /// Stem x positions — the outermost two are flush with the beam's
        /// ends, as engraving draws them.
        static let stemXs = [100, 126, 152, 178]
        static let beamTopY = 40
        /// One beam: 0.5 staff spaces.
        static let beamThicknessPx = 10
        /// Blob length lands in [3.0, 3.5) staff spaces — the band where
        /// `verticalBeamedMinLengthInSpaces` admits a vertical only by
        /// asking a beam whether it touches one.
        static let stemBottomY = 105

        static func beamedGroupPage() -> GrayBitmap {
            var bmp = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 300, dpi: dpi, topY: 140, spacingPx: spacingPx,
            )
            RasterTestBitmaps.hLine(
                &bmp, y: beamTopY,
                x0: stemXs[0], x1: stemXs[3] + stemWidthPx,
                thickness: beamThicknessPx,
            )
            for x in stemXs {
                RasterTestBitmaps.vLine(
                    &bmp, x: x, y0: beamTopY, y1: stemBottomY, thickness: stemWidthPx,
                )
            }
            return bmp
        }

        /// Pixel x → page-space x, the conversion `PageTransform` applies.
        static func pageX(_ px: Double) -> Double {
            px * 72.0 / dpi
        }

        /// The fixture must be one the detector's own gates accept, or a
        /// failure below would only say the picture was unreadable.
        @Test func theFixtureYieldsOneBeamOverTheWholeGroup() {
            let analysis = RasterPage.analyze(Self.beamedGroupPage(), pageIndex: 0)
            let beams = analysis.paths.filter { $0.kind == .beam }
            #expect(beams.count == 1)
            #expect(analysis.staffSpacingPt > 0)
        }

        /// CHARACTERIZATION, and the mechanism it pins is a real defect —
        /// measured, and measured SMALL.
        ///
        /// Only the two INTERIOR stems survive. The outer two are dropped,
        /// because a short vertical is admitted only when
        /// `touchesBeam` finds its x inside some `quad.xRange`, and that
        /// range structurally cannot reach them (see the test below).
        ///
        /// Why this is pinned rather than fixed: profiling every truth
        /// vertical on 299 pages by length AND by position relative to the
        /// detected beams, the miss rate is 0.45 inside a beam, 0.50 at a
        /// beam edge and 0.51 with no beam near — i.e. the beam relation
        /// is NOT the discriminator, length is, and the cliff sits exactly
        /// at `verticalMinLengthInSpaces`. This pathway is worth tens of
        /// stems; the length floor is worth ~6,200. Fixing it is
        /// worthwhile and is not where the duration gap lives.
        @Test func onlyTheInteriorStemsOfABeamedGroupSurvive() {
            let analysis = RasterPage.analyze(Self.beamedGroupPage(), pageIndex: 0)
            let xs = analysis.paths.filter { $0.kind == .vertical }
                .map { Double($0.rect.midX) }.sorted()
            let expected = Self.stemXs.map {
                Self.pageX(Double($0) + Double(Self.stemWidthPx) / 2)
            }
            #expect(xs.count == 2)
            #expect(xs.contains { abs($0 - expected[1]) < 1.0 })
            #expect(xs.contains { abs($0 - expected[2]) < 1.0 })
            #expect(!xs.contains { abs($0 - expected[0]) < 1.0 })
            #expect(!xs.contains { abs($0 - expected[3]) < 1.0 })
        }

        /// …and the reason, stated on the beam: at every stem column the
        /// ink run is beam + stem merged, which lands on no ladder rung
        /// and contributes no column to the slab. Interior stems are
        /// bridged over; the OUTER ones are the slab's own endpoints, so
        /// the fitted x-range stops short of them by about half a stem
        /// width plus a pixel of binarization spread.
        ///
        /// The shortfall is asserted as a BOUND, not an equality: what
        /// matters downstream is its size relative to the consumers'
        /// tolerances — `fullBeamSpans` pads by 1.5pt and survives it,
        /// `touchesBeam` pads by nothing and does not. Measured over the
        /// corpus the same shortfall shows up as beam x-coverage
        /// p50 = 0.90, p01 = 0.85.
        @Test func theBeamQuadStopsJustShortOfTheOutermostStems() {
            let analysis = RasterPage.analyze(Self.beamedGroupPage(), pageIndex: 0)
            guard let quad = analysis.paths.first(where: { $0.kind == .beam })?.quad
            else {
                Issue.record("no beam detected")
                return
            }
            let stemWidthPt = Self.pageX(Double(Self.stemWidthPx))
            let leftStem = Self.pageX(
                Double(Self.stemXs[0]) + Double(Self.stemWidthPx) / 2,
            )
            let rightStem = Self.pageX(
                Double(Self.stemXs[3]) + Double(Self.stemWidthPx) / 2,
            )
            #expect(Double(quad.xRange.lowerBound) > leftStem)
            #expect(Double(quad.xRange.upperBound) < rightStem)
            #expect(Double(quad.xRange.lowerBound) - leftStem <= stemWidthPt)
            #expect(rightStem - Double(quad.xRange.upperBound) <= stemWidthPt)
        }
    }
#endif
