#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// `beamMemberSpan` — the tuplet reader's beam window — pads a RASTER
    /// beam's x-range and reads a VECTOR beam's range raw.
    ///
    /// The pad exists because a fitted raster slab stops inside its own
    /// outermost stems (beam + stem ink merges there), so without it a
    /// triplet's end note fell outside the window and the mark was
    /// discarded (+2.5 durP50 on v2-eval). A vector beam's drawn endpoints
    /// already coincide with its stems, and padding those too moved one
    /// real corpus score's duration accuracy (`bacon_epi`, 95 % → 94 %) —
    /// the byte-identical vector gate is what caught it. So the pad is
    /// gated on provenance, and each side is pinned here.
    struct PDFImporterBeamMemberSpanTests {
        static func beam(fromRaster: Bool) -> PathSegment {
            PathSegment(
                kind: .beam,
                rect: CGRect(x: 100, y: 500, width: 40, height: 2),
                lineWidth: 2,
                pageIndex: 0,
                quad: nil,
                detectedFromRaster: fromRaster,
            )
        }

        @Test func aVectorBeamsWindowIsItsDrawnRange() {
            let span = PDFImporter.beamMemberSpan(Self.beam(fromRaster: false))
            #expect(span == 100 ... 140)
        }

        @Test func aRasterBeamsWindowIsPaddedByTheEndpointPad() {
            let span = PDFImporter.beamMemberSpan(Self.beam(fromRaster: true))
            let pad = PDFImporter.beamEndpointPad
            #expect(span == (100 - pad) ... (140 + pad))
        }

        /// The provenance the gate reads must actually be set by the raster
        /// beam fitter, or the raster side silently loses its pad. Same
        /// fixture as `RasterBeamTests.aFlatBeamIsFoundWithZeroSlope`.
        @Test func theRasterBeamFitterMarksItsProvenance() {
            var bmp = RasterBeamTests.page()
            RasterBeamTests.slopedBeam(&bmp, x0: 60, x1: 260, y0: 90, dy: 0, thickness: 6)
            let segs = RasterBeamTests.beams(bmp)
            #expect(segs.count == 1, "the fixture must yield a beam, or this passes blind")
            let allRaster = segs.allSatisfy(\.detectedFromRaster)
            #expect(allRaster)
        }

        /// And the staff-line recovery, for the same reason — `analyze` on
        /// the fallback fixture yields only staff lines.
        @Test func theRasterStaffLineRecoveryMarksItsProvenance() {
            let analysis = RasterPage.analyze(
                PDFImporterRasterFallbackTests.staffBitmap(), pageIndex: 0,
            )
            #expect(!analysis.paths.isEmpty, "the fixture must yield paths, or this passes blind")
            let allRaster = analysis.paths.allSatisfy(\.detectedFromRaster)
            #expect(allRaster)
        }
    }
#endif
