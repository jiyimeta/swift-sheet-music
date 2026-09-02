#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Pure Swift decode of `net.SymbolNet`'s three exported heads
/// (heatmap probability / offset / geom) into a list of `Detection`.
///
/// This is the literal inverse of `dataset.SymbolTiles.__getitem__`'s
/// encoding, matching `Training/model/decode.py::decode_heads` — the
/// two are deliberately pinned to each other by the same planted-peak
/// numbers in their respective tests, so a discrepancy during Core ML
/// bring-up is attributable to the model, not to the decode. All heads
/// arrive as flat `[Float]` in CHW order at the same `(height, width)`.
enum OMRDetectorDecode {
    /// One decoded symbol, in the tile's local pixel space (y-down),
    /// the same units as the label pipeline's `Glyph.centerPx` /
    /// `originPx`. `originPx` is the SMuFL registration point
    /// reconstructed from `geom`, not a box corner. `score` is the
    /// heatmap probability at the peak cell, post-NMS.
    struct Detection {
        let classIndex: Int
        let score: Double
        let centerPx: CGPoint
        let originPx: CGPoint
        let advancePx: Double
        let renderedSizePx: Double
    }

    /// `heatmap` is `classes * height * width` PER-CLASS PROBABILITY
    /// (post-sigmoid — the exported Core ML graph applies the sigmoid,
    /// this decode applies none of its own). `offset` is
    /// `2 * height * width`, `geom` is `4 * height * width`, both at
    /// the same `(height, width)` as `heatmap`. Order of operations,
    /// matching the CenterNet decode this net was trained against:
    /// 3x3 max-pool NMS on the heatmap, threshold (score > `threshold`
    /// survives), then keep the `topK` highest-scoring survivors
    /// overall (not per class). A cell survives NMS only if it is the
    /// maximum of its own 3x3 neighbourhood (which includes itself,
    /// so a strict local maximum always survives and a tie survives
    /// on both sides) — the same rule as `decode.py::_nms`, fused
    /// into the threshold scan rather than materialising a separate
    /// peaks plane.
    ///
    /// The fusion is what makes this affordable. Measured over the
    /// 34-render eval set, the separated form was **130.8 ms per
    /// tile and 96% of the whole sweep** — it allocated a 9-element
    /// neighbour array for every one of the 62 x 96 x 96 cells (over
    /// 20 million array allocations per page) and ran the
    /// neighbourhood test on all of them, when on a trained heatmap
    /// almost every cell is far below the threshold and can never be
    /// a candidate whatever its peak status. Core ML's own
    /// prediction, by contrast, was 0.75 ms per tile.
    ///
    /// `centre = (cell + offset) * stride` — no `+ 0.5`; `offset` IS
    /// the sub-pixel remainder in cell units, not a half-cell shift.
    /// `geom`'s four channels are `(originΔx, originΔy, advance,
    /// renderedSize)` in staff-space units, so each is multiplied by
    /// `staffSpacePx`. `origin = centre + geom[:2] * staffSpacePx`.
    ///
    /// Returns detections sorted by descending score.
    static func decode(
        heatmap: [Float], offset: [Float], geom: [Float], classes: Int,
        width: Int, height: Int, stride: Int, staffSpacePx: Double,
        threshold: Double, topK: Int,
    ) -> [Detection] {
        let plane = height * width
        var candidates: [(score: Double, classIndex: Int, iy: Int, ix: Int)] = []
        // Compared as `Double(value) > threshold`, never against a
        // `Float(threshold)`: `Float(0.3)` is 0.30000001192…, so a
        // cell between the two representations would change sides
        // purely from where the conversion happens.
        heatmap.withUnsafeBufferPointer { hm in
            for cls in 0 ..< classes {
                let base = cls * plane
                for iy in 0 ..< height {
                    let rowBase = base + iy * width
                    let y0 = max(0, iy - 1), y1 = min(height - 1, iy + 1)
                    for ix in 0 ..< width {
                        let value = hm[rowBase + ix]
                        // Sub-threshold cells are skipped BEFORE the
                        // neighbourhood test, not after: they cannot
                        // become candidates whether or not they are
                        // peaks, and on a trained heatmap almost
                        // every one of the 62 x 96 x 96 cells is one.
                        // Exact because `threshold > 0` (enforced by
                        // `OMRModelManifest.validate`) — a
                        // suppressed cell scores 0, which is never
                        // above a positive threshold.
                        guard Double(value) > threshold else { continue }
                        let x0 = max(0, ix - 1), x1 = min(width - 1, ix + 1)
                        var isPeak = true
                        neighbourhood: for ny in y0 ... y1 {
                            let nRow = base + ny * width
                            for nx in x0 ... x1 where hm[nRow + nx] > value {
                                isPeak = false
                                break neighbourhood
                            }
                        }
                        guard isPeak else { continue }
                        candidates.append((Double(value), cls, iy, ix))
                    }
                }
            }
        }
        candidates.sort { $0.score > $1.score }

        return candidates.prefix(topK).map { candidate in
            let idx = candidate.iy * width + candidate.ix
            let cx = (Double(candidate.ix) + Double(offset[idx])) * Double(stride)
            let cy = (Double(candidate.iy) + Double(offset[plane + idx])) * Double(stride)
            let dx = Double(geom[idx]) * staffSpacePx
            let dy = Double(geom[plane + idx]) * staffSpacePx
            let advance = Double(geom[2 * plane + idx]) * staffSpacePx
            let renderedSize = Double(geom[3 * plane + idx]) * staffSpacePx
            return Detection(
                classIndex: candidate.classIndex, score: candidate.score,
                centerPx: CGPoint(x: cx, y: cy),
                originPx: CGPoint(x: cx + dx, y: cy + dy),
                advancePx: advance, renderedSizePx: renderedSize,
            )
        }
    }
}
