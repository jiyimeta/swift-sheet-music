#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF

    /// Split the beam oracle's advantage into the three things the labels'
    /// beams have that the raster detector's do not, one at a time.
    ///
    /// `truthBeams` wins +2.5 durP50 / +2.1 durMean on v2-eval after the
    /// staff-line round, and that one number is compatible with three
    /// different fixes in three different files:
    ///
    ///   1. X-EXTENT — a fitted slab cannot include the columns where its
    ///      own outermost stems stand (beam + stem ink merges there and
    ///      lands on no ladder rung), so its x-range stops INSIDE them.
    ///      `RasterPage.extendedSpan` walks that back out; what survives is
    ///      the `[beamdiag] windowDrop` count.
    ///   2. FALSE POSITIVES — 574 predicted beams no label beam explains.
    ///      Each one that lands on a stem promotes a quarter to an eighth.
    ///   3. MISSES — 31 label beams that matched nothing.
    ///
    /// There is no fourth component here, unlike `OMRVerticalHybrid`:
    /// `detectedFromRaster` is set on VERTICALS only (`RasterPage+Verticals`
    /// is its sole writer) and read by `PDFImporter.isStem` only, so
    /// substituting a beam cannot smuggle in a gate change the way
    /// substituting a vertical does.
    ///
    /// MATCHING MIRRORS `OMRSeamMetrics.beamAssignment` exactly — greedy,
    /// one-to-one, candidates need x-overlap and a top-edge distance within
    /// 0.5 staff spaces at the overlap midpoint, closest pairs first. It is
    /// restated here on `PathSegment` only because the hybrid front-end
    /// composes paths while the seam metric reads label records; keeping the
    /// rule identical is what lets this decomposition and the `[beamdiag]`
    /// ledger be read against each other.
    enum OMRBeamHybrid {
        enum Operation {
            /// Matched detections take their truth partner's x-range,
            /// keeping their own fitted edges. Unmatched detections and
            /// missed truths are left exactly as they are.
            case snapXRanges
            /// Drop detections no truth beam matched.
            case dropFalsePositives
            /// Add truth beams no detection matched.
            case addMisses
        }

        struct Stats {
            var detections = 0
            var truths = 0
            var matched = 0
            var falsePositives = 0
            var misses = 0
            var snapped = 0
            /// Summed signed shortfall in pt over the snapped ends —
            /// positive means the detection stopped INSIDE the truth.
            var snapShortfallLeftPt = 0.0
            var snapShortfallRightPt = 0.0
            /// Per snapped end, the shortfall in 0.5 pt buckets
            /// (key -1 = the detection overhangs its truth).
            var shortfall: [Int: Int] = [:]

            mutating func add(_ other: Stats) {
                detections += other.detections
                truths += other.truths
                matched += other.matched
                falsePositives += other.falsePositives
                misses += other.misses
                snapped += other.snapped
                snapShortfallLeftPt += other.snapShortfallLeftPt
                snapShortfallRightPt += other.snapShortfallRightPt
                for (k, v) in other.shortfall {
                    shortfall[k, default: 0] += v
                }
            }

            var line: String {
                "det=\(detections) truth=\(truths) matched=\(matched) "
                    + "fp=\(falsePositives) missed=\(misses) snapped=\(snapped) "
                    + String(
                        format: "shortLeftPt=%.2f shortRightPt=%.2f ",
                        snapShortfallLeftPt, snapShortfallRightPt,
                    )
                    + shortfall.keys.sorted()
                    .map { "s\($0)=\(shortfall[$0] ?? 0)" }
                    .joined(separator: " ")
            }
        }

        /// Greedy one-to-one detection→truth pairing; see the type comment.
        static func assignment(
            detected: [PathSegment], truth: [PathSegment], spacing: Double,
        ) -> [(di: Int, ti: Int)] {
            var pairs: [(score: Double, di: Int, ti: Int)] = []
            for (di, d) in detected.enumerated() {
                guard let dq = d.quad else { continue }
                for (ti, t) in truth.enumerated() {
                    guard let tq = t.quad else { continue }
                    let lo = max(dq.xRange.lowerBound, tq.xRange.lowerBound)
                    let hi = min(dq.xRange.upperBound, tq.xRange.upperBound)
                    guard hi > lo else { continue }
                    let mid = (lo + hi) / 2
                    let gap = Double(abs(
                        (dq.topSlope * mid + dq.topIntercept)
                            - (tq.topSlope * mid + tq.topIntercept),
                    ))
                    if gap <= 0.5 * spacing { pairs.append((-gap, di, ti)) }
                }
            }
            pairs.sort { ($0.score, $0.di, $0.ti) > ($1.score, $1.di, $1.ti) }
            var usedD = Set<Int>()
            var usedT = Set<Int>()
            var accepted: [(di: Int, ti: Int)] = []
            for pair in pairs where !usedD.contains(pair.di) && !usedT.contains(pair.ti) {
                usedD.insert(pair.di)
                usedT.insert(pair.ti)
                accepted.append((pair.di, pair.ti))
            }
            return accepted
        }

        /// `d` with `t`'s x-range and its OWN fitted edges. The rect is
        /// recomputed from those edges over the new range so the axis-
        /// aligned box and the quad keep describing the same slab —
        /// `beamWindow` reads `rect.midY` while `fullBeamSpans` reads the
        /// quad, and letting the two disagree would inject a defect this
        /// mode is not trying to measure.
        static func snapped(_ d: PathSegment, to t: PathSegment) -> PathSegment {
            guard let dq = d.quad, let tq = t.quad else { return d }
            var out = d
            var q = dq
            q.xRange = tq.xRange
            out.quad = q
            let x0 = q.xRange.lowerBound
            let x1 = q.xRange.upperBound
            let ys = [
                q.topSlope * x0 + q.topIntercept, q.topSlope * x1 + q.topIntercept,
                q.botSlope * x0 + q.botIntercept, q.botSlope * x1 + q.botIntercept,
            ]
            let minY = ys.min() ?? out.rect.minY
            let maxY = ys.max() ?? out.rect.maxY
            out.rect = CGRect(
                x: x0, y: minY, width: x1 - x0, height: maxY - minY,
            )
            return out
        }

        /// One page. `detected` and `truth` are the BEAMS only, in the same
        /// frame. `kept` is aligned with `detected` (nil = dropped) and
        /// `added` is appended after every raster path, so a no-op edit
        /// reproduces `.full`'s path ORDER and not merely its contents.
        static func apply(
            _ operation: Operation, detected: [PathSegment], truth: [PathSegment],
            spacing: Double,
        ) -> (kept: [PathSegment?], added: [PathSegment], stats: Stats) {
            var stats = Stats()
            stats.detections = detected.count
            stats.truths = truth.count
            guard spacing > 0 else { return (detected.map(\.self), [], stats) }

            let accepted = assignment(
                detected: detected, truth: truth, spacing: spacing,
            )
            var partner = [Int: Int]()
            var matchedTruth = Set<Int>()
            for pair in accepted {
                partner[pair.di] = pair.ti
                matchedTruth.insert(pair.ti)
            }
            stats.matched = accepted.count
            stats.falsePositives = detected.count - accepted.count
            stats.misses = truth.count - accepted.count

            switch operation {
            case .dropFalsePositives:
                return (
                    detected.indices.map { partner[$0] == nil ? nil : detected[$0] },
                    [], stats,
                )
            case .addMisses:
                let added = truth.indices
                    .filter { !matchedTruth.contains($0) }
                    .map { truth[$0] }
                return (detected.map(\.self), added, stats)
            case .snapXRanges:
                var kept: [PathSegment?] = []
                for (di, d) in detected.enumerated() {
                    guard let ti = partner[di], let dq = d.quad,
                          let tq = truth[ti].quad
                    else {
                        kept.append(d)
                        continue
                    }
                    stats.snapped += 1
                    let left = Double(dq.xRange.lowerBound - tq.xRange.lowerBound)
                    let right = Double(tq.xRange.upperBound - dq.xRange.upperBound)
                    stats.snapShortfallLeftPt += left
                    stats.snapShortfallRightPt += right
                    for shortfall in [left, right] {
                        let key = shortfall <= 0 ? -1 : Int((shortfall * 2).rounded(.down))
                        stats.shortfall[key, default: 0] += 1
                    }
                    kept.append(snapped(d, to: truth[ti]))
                }
                return (kept, [], stats)
            }
        }
    }

    extension OMRHybridFrontEnd.Mode {
        /// Which beam-set edits this mode applies, in order. Distinct from
        /// `substituted`: these modes keep the raster's own beams and EDIT
        /// them, so nothing is taken from the oracle wholesale.
        var beamHybrid: [OMRBeamHybrid.Operation] {
            switch self {
            case .snapBeamXRanges: [.snapXRanges]
            case .dropBeamFalsePositives: [.dropFalsePositives]
            case .addBeamMisses: [.addMisses]
            case .allBeamComponents:
                [.dropFalsePositives, .snapXRanges, .addMisses]
            default: []
            }
        }
    }

    /// The composition step, in an extension rather than in the enum's own
    /// body: `OMRHybridFrontEnd` is already at SwiftLint's
    /// `type_body_length` ceiling, and this belongs beside the operations
    /// it drives anyway.
    extension OMRHybridFrontEnd {
        /// One page's paths with the BEAM set edited in place, on the same
        /// contract as `hybridVerticals`: edits land where the beam sits,
        /// rescued truths are appended last, and the `[bhybrid]` line
        /// carries the per-page counts.
        static func hybridBeams(
            _ operations: [OMRBeamHybrid.Operation], pagePaths: [PathSegment],
            truth: [PathSegment], page: OMRPageLabels, analysis: RasterPageAnalysis,
            mode: Mode, index: Int,
        ) -> [PathSegment] {
            let reframed = reframe(truth, page: page, transform: analysis.transform)
            var paths = pagePaths
            for operation in operations {
                let edit = OMRBeamHybrid.apply(
                    operation,
                    detected: paths.filter { $0.kind == .beam },
                    truth: reframed,
                    spacing: Double(analysis.staffSpacingPt),
                )
                var cursor = 0
                var rebuilt: [PathSegment] = []
                for path in paths {
                    guard path.kind == .beam else {
                        rebuilt.append(path)
                        continue
                    }
                    if let kept = edit.kept[cursor] { rebuilt.append(kept) }
                    cursor += 1
                }
                print(
                    "[bhybrid] mode=\(mode.rawValue) op=\(operation) page=\(index) "
                        + "spacingPt=\(analysis.staffSpacingPt) \(edit.stats.line)",
                )
                paths = rebuilt + edit.added
            }
            return paths
        }
    }
#endif
