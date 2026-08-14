#if !os(Android)
    import CoreGraphics
    import Foundation
    import Testing

    /// Pins `OMRDetectorDecode` to `Training/model/decode.py`'s
    /// `test_decode.py` by construction: the planted-peak numbers in
    /// `decodeRecoversAPlantedPeak` are copied verbatim from
    /// `test_decode_recovers_a_planted_peak`, so a discrepancy between the
    /// two decoders shows up as a Swift test failure here, not just a
    /// Python one.
    struct OMRDetectorDecodeTests {
        @Test func decodeRecoversAPlantedPeak() throws {
            var heatmap = [Float](repeating: 0, count: 2 * 8 * 8)
            heatmap[1 * 64 + 3 * 8 + 4] = 0.9
            var offset = [Float](repeating: 0, count: 2 * 8 * 8)
            offset[0 * 64 + 3 * 8 + 4] = 0.25
            offset[1 * 64 + 3 * 8 + 4] = 0.5
            var geom = [Float](repeating: 0, count: 4 * 8 * 8)
            geom[0 * 64 + 3 * 8 + 4] = -0.5
            geom[2 * 64 + 3 * 8 + 4] = 1.0
            geom[3 * 64 + 3 * 8 + 4] = 0.75
            let out = OMRDetectorDecode.decode(
                heatmap: heatmap, offset: offset, geom: geom, classes: 2,
                width: 8, height: 8, stride: 4, staffSpacePx: 12,
                threshold: 0.3, topK: 10,
            )
            let detection = try #require(out.first)
            #expect(detection.classIndex == 1)
            #expect(abs(detection.centerPx.x - 17) < 1e-5)
            #expect(abs(detection.centerPx.y - 14) < 1e-5)
            #expect(abs(detection.originPx.x - 11) < 1e-5)
            #expect(abs(detection.advancePx - 12) < 1e-5)
        }

        /// Two cells of the SAME class, one cell apart, both inside each
        /// other's 3x3 neighbourhood: only the higher-scoring one may
        /// survive. Skipping the NMS step and going straight to
        /// threshold/top-K would keep BOTH — they both clear 0.3 — so this
        /// pins the 3x3 max-pool step specifically, not just thresholding.
        /// Verified by deletion: with `nms(...)` replaced by the raw
        /// `heatmap` (no suppression), this test fails with 2 detections
        /// instead of 1.
        @Test func decodeSuppressesANeighboringCellOfTheSameClass() throws {
            var heatmap = [Float](repeating: 0, count: 1 * 8 * 8)
            heatmap[3 * 8 + 4] = 0.9
            heatmap[3 * 8 + 5] = 0.5
            let offset = [Float](repeating: 0, count: 2 * 8 * 8)
            let geom = [Float](repeating: 0, count: 4 * 8 * 8)
            let out = OMRDetectorDecode.decode(
                heatmap: heatmap, offset: offset, geom: geom, classes: 1,
                width: 8, height: 8, stride: 4, staffSpacePx: 12,
                threshold: 0.3, topK: 10,
            )
            #expect(out.count == 1)
            let detection = try #require(out.first)
            #expect(abs(detection.score - 0.9) < 1e-5)
            #expect(abs(detection.centerPx.x - 16) < 1e-5)
            #expect(abs(detection.centerPx.y - 12) < 1e-5)
        }

        /// Verified by deletion: with the `guard value > threshold` line
        /// removed, this test fails — 10 detections (the `topK` cap) leak
        /// through instead of 0.
        @Test func decodeReturnsNothingBelowTheThreshold() {
            var heatmap = [Float](repeating: 0, count: 1 * 8 * 8)
            heatmap[3 * 8 + 4] = 0.2
            let offset = [Float](repeating: 0, count: 2 * 8 * 8)
            let geom = [Float](repeating: 0, count: 4 * 8 * 8)
            let out = OMRDetectorDecode.decode(
                heatmap: heatmap, offset: offset, geom: geom, classes: 1,
                width: 8, height: 8, stride: 4, staffSpacePx: 12,
                threshold: 0.3, topK: 10,
            )
            #expect(out.isEmpty)
        }

        /// pageWidth=12, tile=8, overlap=2 → OMRTiling.origins(12,8,2) ==
        /// [0, 4], and coreRange splits x at the midpoint 6: tile0 owns
        /// [0,6), tile1 owns [6,12). pageHeight=8 == tile, so the y core is
        /// always the full [0,8) and only x is exercised.
        ///
        /// Two tiles each detect (their own noisy view of) the SAME
        /// physical symbol near that x=6 boundary: tile0's copy maps to
        /// page x=5.9 (inside its own core), tile1's copy maps to page
        /// x=6.2 (inside ITS own core). Neither is dropped by the core
        /// filter alone — both survive it — so only the class-wise
        /// centre-distance pass can collapse them to one.
        ///
        /// Verified by deletion: with the `dedupe(...)` call replaced by
        /// returning `claimed` directly, this test fails with 2 detections
        /// instead of 1.
        @Test func mergeCollapsesABoundaryDetectionClaimedByBothCores() throws {
            let strong = OMRDetectorDecode.Detection(
                classIndex: 3, score: 0.9, centerPx: CGPoint(x: 5.9, y: 4),
                originPx: .zero, advancePx: 0, renderedSizePx: 0,
            )
            let weak = OMRDetectorDecode.Detection(
                classIndex: 3, score: 0.5, centerPx: CGPoint(x: 2.2, y: 4),
                originPx: .zero, advancePx: 0, renderedSizePx: 0,
            )
            let tiles: [(origin: CGPoint, detections: [OMRDetectorDecode.Detection])] = [
                (CGPoint(x: 0, y: 0), [strong]),
                (CGPoint(x: 4, y: 0), [weak]),
            ]
            let out = OMRDetectorDecode.merge(
                tiles, pageWidth: 12, pageHeight: 8, tile: 8, overlap: 2, nmsRadiusPx: 1.0,
            )
            #expect(out.count == 1)
            let detection = try #require(out.first)
            #expect(abs(detection.score - 0.9) < 1e-5)
            #expect(abs(detection.centerPx.x - 5.9) < 1e-5)
        }

        /// Same geometry as above, but the single tile's detection maps to
        /// page x=7.0 — inside the raw tile [0,8) but outside its CORE
        /// [0,6). No second tile is needed to prove this: the core filter
        /// must drop it on tile0's own account.
        ///
        /// Verified by deletion: with the core-membership `guard` replaced
        /// by an unconditional pass-through, this test fails with 1
        /// detection instead of 0.
        @Test func mergeDropsADetectionOutsideItsTilesCore() {
            let outside = OMRDetectorDecode.Detection(
                classIndex: 0, score: 0.9, centerPx: CGPoint(x: 7.0, y: 4),
                originPx: .zero, advancePx: 0, renderedSizePx: 0,
            )
            let tiles: [(origin: CGPoint, detections: [OMRDetectorDecode.Detection])] = [
                (CGPoint(x: 0, y: 0), [outside]),
            ]
            let out = OMRDetectorDecode.merge(
                tiles, pageWidth: 12, pageHeight: 8, tile: 8, overlap: 2, nmsRadiusPx: 1.0,
            )
            #expect(out.isEmpty)
        }
    }
#endif
