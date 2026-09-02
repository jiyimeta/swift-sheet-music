#if !os(Android) && !os(WASI)
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
        /// Blob length lands in [3.0, 3.5) staff spaces — the band that
        /// the old 3.5 floor cut and that only a beam-touch could rescue.
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

        /// Every stem of the group survives — including the outermost
        /// two, which is the part that used to fail.
        ///
        /// While the length floor sat at 3.5 staff spaces, a stem this
        /// short was admitted only if `touchesBeam` found its x inside
        /// some `quad.xRange`, and that range structurally cannot reach
        /// the group's own outer stems (the test below still pins that
        /// geometry). So the outer two were deleted and their notes
        /// reached the rhythm pass stemless — read as quarters.
        ///
        /// What fixed it was not a pad on that containment test. Profiled
        /// over 299 pages, the truth-vertical miss rate was 0.45 inside a
        /// beam, 0.50 at a beam edge and 0.51 with no beam near: the beam
        /// relation was never the discriminator, the floor was. With the
        /// floor at 2.5 these stems clear it outright, and the precision
        /// the floor used to provide comes from `isStem`'s notehead-end
        /// test instead.
        @Test func everyStemOfABeamedGroupSurvives() {
            let analysis = RasterPage.analyze(Self.beamedGroupPage(), pageIndex: 0)
            let xs = analysis.paths.filter { $0.kind == .vertical }
                .map { Double($0.rect.midX) }.sorted()
            let expected = Self.stemXs.map {
                Self.pageX(Double($0) + Double(Self.stemWidthPx) / 2)
            }
            #expect(xs.count == Self.stemXs.count)
            for want in expected {
                #expect(
                    xs.contains { abs($0 - want) < 1.0 },
                    "no stem near x=\(want)pt; got \(xs)",
                )
            }
        }

        /// The fitted quad reaches its own outermost stems.
        ///
        /// It does not do so by fitting: at every stem column the ink run
        /// is beam + stem merged, lands on no ladder rung, and gives the
        /// slab no column, so the FIT necessarily stops about half a stem
        /// width inside each end. `extendedSpan` walks outward from there
        /// across columns whose ink still fills the fitted band, which is
        /// what the beam's own continuation over its outer stem looks
        /// like.
        ///
        /// The property matters because `beamWindow` uses a beam's
        /// x-range as a tuplet's member-run window and `fullBeamSpans`
        /// tests each stem's x against it — both written when the only
        /// producer was a vector PDF, where a beam quad's endpoints
        /// coincide with its outer stems by construction.
        @Test func theBeamQuadReachesTheOutermostStems() {
            let analysis = RasterPage.analyze(Self.beamedGroupPage(), pageIndex: 0)
            guard let quad = analysis.paths.first(where: { $0.kind == .beam })?.quad
            else {
                Issue.record("no beam detected")
                return
            }
            let leftStem = Self.pageX(
                Double(Self.stemXs[0]) + Double(Self.stemWidthPx) / 2,
            )
            let rightStem = Self.pageX(
                Double(Self.stemXs[3]) + Double(Self.stemWidthPx) / 2,
            )
            #expect(Double(quad.xRange.lowerBound) <= leftStem)
            #expect(Double(quad.xRange.upperBound) >= rightStem)
        }

        /// …and it stops there rather than running on. The bound is what
        /// keeps a notehead abutting a beam end — which also fills the
        /// band — from being swallowed into the beam's span.
        @Test func theBeamQuadDoesNotOverrunTheGroup() {
            let analysis = RasterPage.analyze(Self.beamedGroupPage(), pageIndex: 0)
            guard let quad = analysis.paths.first(where: { $0.kind == .beam })?.quad
            else {
                Issue.record("no beam detected")
                return
            }
            let inkLeft = Self.pageX(Double(Self.stemXs[0]))
            let inkRight = Self.pageX(Double(Self.stemXs[3] + Self.stemWidthPx))
            let slack = Self.pageX(Double(Self.spacingPx) * 0.35)
            #expect(Double(quad.xRange.lowerBound) >= inkLeft - slack)
            #expect(Double(quad.xRange.upperBound) <= inkRight + slack)
        }
    }
#endif
