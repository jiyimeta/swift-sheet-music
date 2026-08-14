#if !os(Android)
    import CoreGraphics
    import Foundation

    extension OMRDetectorDecode {
        /// Merges per-tile detections (each still in that tile's LOCAL
        /// pixel space) into one page-space list. A detection is claimed
        /// by the tile whose CORE (`OMRTiling.coreRange`) contains its
        /// page-space centre, so the overlap between adjacent tiles
        /// cannot double-count it; a class-wise centre-distance pass
        /// afterwards removes anything that still slipped through at a
        /// shared boundary — two tiles can each legitimately claim their
        /// own, slightly-off-center detection of the same physical
        /// symbol when it sits right at the boundary. This exclusivity
        /// is an INFERENCE-time rule only: training deliberately lets
        /// overlapping crops both carry a glyph as a target.
        static func merge(
            _ tiles: [(origin: CGPoint, detections: [Detection])],
            pageWidth: Int, pageHeight: Int, tile: Int, overlap: Int, nmsRadiusPx: Double,
        ) -> [Detection] {
            var claimed: [Detection] = []
            for (origin, detections) in tiles {
                let coreX = OMRTiling.coreRange(
                    origin: Int(origin.x), extent: pageWidth, tile: tile, overlap: overlap,
                )
                let coreY = OMRTiling.coreRange(
                    origin: Int(origin.y), extent: pageHeight, tile: tile, overlap: overlap,
                )
                for detection in detections {
                    let mapped = mapped(detection, origin: origin)
                    guard coreX.contains(Int(mapped.centerPx.x)),
                          coreY.contains(Int(mapped.centerPx.y))
                    else { continue }
                    claimed.append(mapped)
                }
            }
            return dedupe(claimed, radius: nmsRadiusPx)
        }

        /// Translates a tile-local detection into page space by adding
        /// the tile's origin to both `centerPx` and `originPx`.
        private static func mapped(_ detection: Detection, origin: CGPoint) -> Detection {
            Detection(
                classIndex: detection.classIndex, score: detection.score,
                centerPx: CGPoint(x: origin.x + detection.centerPx.x, y: origin.y + detection.centerPx.y),
                originPx: CGPoint(x: origin.x + detection.originPx.x, y: origin.y + detection.originPx.y),
                advancePx: detection.advancePx, renderedSizePx: detection.renderedSizePx,
            )
        }

        /// One pass, highest score first: a detection is dropped once
        /// something already kept, of the SAME class, lies within
        /// `radius` of its centre.
        private static func dedupe(_ detections: [Detection], radius: Double) -> [Detection] {
            var kept: [Detection] = []
            for detection in detections.sorted(by: { $0.score > $1.score }) {
                let isDuplicate = kept.contains { existing in
                    existing.classIndex == detection.classIndex
                        && hypot(
                            existing.centerPx.x - detection.centerPx.x,
                            existing.centerPx.y - detection.centerPx.y,
                        ) < radius
                }
                if !isDuplicate { kept.append(detection) }
            }
            return kept
        }
    }
#endif
