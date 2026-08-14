#if !os(Android)
    import CoreGraphics
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
        /// overall (not per class).
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
            let peaks = nms(heatmap, classes: classes, width: width, height: height)
            let plane = height * width
            var candidates: [(score: Double, classIndex: Int, iy: Int, ix: Int)] = []
            for cls in 0 ..< classes {
                for iy in 0 ..< height {
                    for ix in 0 ..< width {
                        let value = Double(peaks[cls * plane + iy * width + ix])
                        guard value > threshold else { continue }
                        candidates.append((value, cls, iy, ix))
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

        /// 3x3 max-pool NMS, independently per class channel: a cell
        /// survives only if it is the maximum of its own 3x3 neighbourhood
        /// (which always includes the cell itself, so a strict local
        /// maximum always survives, and a tie survives on both sides).
        /// Suppressed cells come back as 0. Mirrors `decode.py::_nms`.
        private static func nms(_ heatmap: [Float], classes: Int, width: Int, height: Int) -> [Float] {
            let plane = height * width
            var peaks = [Float](repeating: 0, count: heatmap.count)
            for cls in 0 ..< classes {
                let base = cls * plane
                for iy in 0 ..< height {
                    for ix in 0 ..< width {
                        let value = heatmap[base + iy * width + ix]
                        let isPeak = neighborhood(iy: iy, ix: ix, width: width, height: height)
                            .allSatisfy { ny, nx in heatmap[base + ny * width + nx] <= value }
                        peaks[base + iy * width + ix] = isPeak ? value : 0
                    }
                }
            }
            return peaks
        }

        private static func neighborhood(iy: Int, ix: Int, width: Int, height: Int) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            for dy in -1 ... 1 {
                let ny = iy + dy
                guard ny >= 0, ny < height else { continue }
                for dx in -1 ... 1 {
                    let nx = ix + dx
                    guard nx >= 0, nx < width else { continue }
                    result.append((ny, nx))
                }
            }
            return result
        }
    }
#endif
