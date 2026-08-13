#if !os(Android)
    import Foundation
    import Testing

    @Suite struct OMRTilingTests {
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
#endif
