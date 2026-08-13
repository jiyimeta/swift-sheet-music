#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct OMRTilingTests {
        @Test func aPageShorterThanOneTileIsASingleTile() {
            #expect(OMRTiling.origins(extent: 200, tile: 384, overlap: 64) == [0])
        }

        @Test func tilesStepByTileMinusOverlapAndTheLastOneIsFlushRight() {
            // step = 320; 0, 320, 640 would run past 900, so the last
            // origin is clamped flush to the right edge instead of
            // producing a short tile the model was never trained on.
            #expect(
                OMRTiling.origins(extent: 900, tile: 384, overlap: 64)
                    == [0, 320, 516],
            )
        }

        @Test func anExactFitDoesNotRepeatTheLastTile() {
            #expect(OMRTiling.origins(extent: 384, tile: 384, overlap: 64) == [0])
            #expect(
                OMRTiling.origins(extent: 704, tile: 384, overlap: 64)
                    == [0, 320],
            )
        }

        @Test func coreRegionsPartitionThePageExactly() {
            let extent = 900, tile = 384, overlap = 64
            let ranges = OMRTiling.origins(extent: extent, tile: tile, overlap: overlap)
                .map { OMRTiling.coreRange(origin: $0, extent: extent, tile: tile, overlap: overlap) }
            // Every pixel column belongs to exactly one tile's core, so a
            // detection is claimed once and only once.
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == extent)
            for (a, b) in zip(ranges, ranges.dropFirst()) {
                #expect(a.upperBound == b.lowerBound)
            }
        }
    }

    struct OMRPrepNormalizeTests {
        @Test func halvingTheStaffSpaceHalvesThePage() throws {
            let page = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 300, dpi: 300, topY: 100, spacingPx: 16,
            )
            let out = try #require(OMRPrepNormalize.normalize(
                page, staffSpacingPx: 16, targetStaffSpacePx: 8,
            ))
            #expect(abs(out.scale - 0.5) < 1e-12)
            #expect(out.bitmap.width == 200)
            #expect(out.bitmap.height == 150)
        }

        @Test func anAlreadyCanonicalPageIsReturnedUnchanged() throws {
            let page = RasterTestBitmaps.staff(
                widthPx: 120, heightPx: 90, dpi: 300, topY: 30, spacingPx: 12,
            )
            let out = try #require(OMRPrepNormalize.normalize(
                page, staffSpacingPx: 12, targetStaffSpacePx: 12,
            ))
            #expect(out.scale == 1.0)
            // Byte-identical, not merely same-sized: scale 1 must not
            // round-trip the page through a resampler that softens ink.
            #expect(out.bitmap.pixels == page.pixels)
        }

        @Test func theStaffStaysWhereTheScaleSaysItShould() throws {
            let page = RasterTestBitmaps.staff(
                widthPx: 400, heightPx: 400, dpi: 300, topY: 100, spacingPx: 16,
            )
            let out = try #require(OMRPrepNormalize.normalize(
                page, staffSpacingPx: 16, targetStaffSpacePx: 8,
            ))
            // The top staff line was at y=100; at scale 0.5 its darkest
            // row must be at 50 ± 1.
            let darkest = (0 ..< out.bitmap.height).min {
                rowInk(out.bitmap, $0) < rowInk(out.bitmap, $1)
            }
            #expect(abs((darkest ?? -1) - 50) <= 1)
        }

        @Test func aPageWithNoStaffCannotBeNormalized() {
            let blank = RasterTestBitmaps.blank(widthPx: 40, heightPx: 40, dpi: 300)
            #expect(OMRPrepNormalize.normalize(
                blank, staffSpacingPx: 0, targetStaffSpacePx: 12,
            ) == nil)
        }

        private func rowInk(_ bitmap: GrayBitmap, _ y: Int) -> Int {
            (0 ..< bitmap.width).reduce(0) { $0 + Int(bitmap[$1, y]) }
        }
    }
#endif
