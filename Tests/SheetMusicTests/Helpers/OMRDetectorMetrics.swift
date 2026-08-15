#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF

    /// Detector-level seam metrics (task 16, design spec's stage-two
    /// headline number): CNN detections (`ClassifiedGlyph`, already in
    /// the front-end's own page frame) against the label glyphs, reframed
    /// into that same frame and restricted to the detector vocabulary by
    /// the caller (`OMRHybridFrontEnd.reframe` /
    /// `.detectorVocabularyGlyphs`).
    ///
    /// Matching is deliberately simpler than `OMRSeamMetrics.matchGlyphs`
    /// (IoU over LABEL bounding boxes): a detector's own emitted box is a
    /// decode artifact of its geometry head, not ground-truth ink, so the
    /// quantity this stage actually needs is origin distance — the same
    /// one the raster-CV seam already showed governs downstream pitch
    /// accuracy (0.25 sp free, 0.5 sp halves pitch). Per class, greedy
    /// nearest-CENTER within a radius (`matchSp`, staff spaces),
    /// one-to-one: two predictions on one truth score at most one true
    /// positive, or precision would be unbounded above.
    enum OMRDetectorMetrics {
        struct ClassCounts {
            var tp = 0
            var fp = 0
            var fn = 0
            /// One entry per MATCHED pair, in staff spaces.
            var originErrSp: [Double] = []
        }

        /// One page's (or, for the fixture tests, one hand-built set's)
        /// match result, aggregated per class name
        /// (`OMRLabelClassNames.className(for:)`).
        struct Result {
            var byClass: [String: ClassCounts] = [:]

            var tp: Int {
                byClass.values.reduce(0) { $0 + $1.tp }
            }

            var fp: Int {
                byClass.values.reduce(0) { $0 + $1.fp }
            }

            var fn: Int {
                byClass.values.reduce(0) { $0 + $1.fn }
            }

            var originErrSp: [Double] {
                byClass.values.flatMap(\.originErrSp)
            }

            var recall: Double {
                let denom = tp + fn
                return denom > 0 ? Double(tp) / Double(denom) : 0
            }

            var precision: Double {
                let denom = tp + fp
                return denom > 0 ? Double(tp) / Double(denom) : 0
            }

            var originErrorSpacesP50: Double {
                OMRDetectorMetrics.percentile(originErrSp, 0.5)
            }
        }

        /// Nearest-rank percentile. Called on small, already-in-memory
        /// lists — one page's matches, a fixture's hand-built few, or a
        /// per-render score percentage collected across a sweep — never
        /// on a whole corpus of RAW origin errors (which buckets those
        /// instead; see `OMRDetectorEvalSweep.Totals.originErrBuckets`,
        /// the `[endprofile]`-style histogram this repo uses precisely
        /// to avoid holding a tens-of-megabytes list in memory).
        static func percentile(_ values: [Double], _ q: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(
                sorted.count - 1,
                max(0, Int((Double(sorted.count) * q).rounded(.down))),
            )
            return sorted[idx]
        }

        /// Matches `predicted` against `truth` — both `ClassifiedGlyph`
        /// in the SAME frame — per class name, radius `matchSp` staff
        /// spaces converted to points via `staffSpacingPt`.
        static func match(
            predicted: [ClassifiedGlyph], truth: [ClassifiedGlyph],
            staffSpacingPt: Double, matchSp: Double,
        ) -> Result {
            var result = Result()
            guard staffSpacingPt > 0 else {
                // A page P3a found no staff on: there is no radius to
                // match within, and the real detector's own contract
                // (`OMRDetectorFrontEnd.glyphs`) returns `[]` here. But
                // every truth glyph on the page is still a genuine miss —
                // it must land in `fn`, not vanish from both sides'
                // denominators. Silently returning an empty `Result`
                // dropped the page's truth from the recall population
                // entirely, which is exactly the direction population
                // degradation (fewer detected staves) inflates recall.
                for glyph in truth {
                    result.byClass[className(glyph), default: ClassCounts()].fn += 1
                }
                return result
            }
            let radiusPt = matchSp * staffSpacingPt
            let classes = Set(predicted.map(className)).union(truth.map(className))
            for cls in classes.sorted() {
                result.byClass[cls] = matchOneClass(
                    predicted: predicted.filter { className($0) == cls },
                    truth: truth.filter { className($0) == cls },
                    radiusPt: radiusPt, staffSpacingPt: staffSpacingPt,
                )
            }
            return result
        }

        private static func className(_ glyph: ClassifiedGlyph) -> String {
            OMRLabelClassNames.className(for: glyph.semantic)
        }

        /// Greedy nearest-center, one-to-one: candidate pairs sorted by
        /// ascending distance, accepted while both sides are unused —
        /// mirrors `OMRSeamMetrics`'s own greedy-match shape (there
        /// sorted by descending IoU), just keyed on distance instead of
        /// overlap, since a detector's own box is not ground truth.
        private static func matchOneClass(
            predicted: [ClassifiedGlyph], truth: [ClassifiedGlyph],
            radiusPt: Double, staffSpacingPt: Double,
        ) -> ClassCounts {
            var counts = ClassCounts()
            var pairs: [(dist: Double, pi: Int, ti: Int)] = []
            for (pi, p) in predicted.enumerated() {
                for (ti, t) in truth.enumerated() {
                    let dx = Double(p.geometry.origin.x - t.geometry.origin.x)
                    let dy = Double(p.geometry.origin.y - t.geometry.origin.y)
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d <= radiusPt { pairs.append((d, pi, ti)) }
                }
            }
            pairs.sort { ($0.dist, $0.pi, $0.ti) < ($1.dist, $1.pi, $1.ti) }
            var usedP = Set<Int>()
            var usedT = Set<Int>()
            for pair in pairs where !usedP.contains(pair.pi) && !usedT.contains(pair.ti) {
                usedP.insert(pair.pi)
                usedT.insert(pair.ti)
                counts.tp += 1
                counts.originErrSp.append(pair.dist / staffSpacingPt)
            }
            counts.fp = predicted.count - usedP.count
            counts.fn = truth.count - usedT.count
            return counts
        }
    }
#endif
