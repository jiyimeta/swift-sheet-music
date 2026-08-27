#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Seam-level evaluation (spec §8.1): a front-end's WalkedContent
    /// (as label records) vs the page labels. Match criteria:
    /// - normal classes: greedy same-class matching by descending IoU,
    ///   accepted at IoU ≥ 0.5;
    /// - tiny-ink classes (IoU unstable): center distance ≤ 0.5 × staff
    ///   spacing;
    /// all traversal in sorted/positional order (determinism contract).
    enum OMRSeamMetrics {
        struct ClassCounts {
            var tp = 0
            var fp = 0
            var fn = 0
            var originErrPt: [Double] = []
            var sizeErrPt: [Double] = []
        }

        static let centerDistanceClasses: Set = [
            "augmentationDot", "repeatBarlineDots",
        ]

        static func iou(_ a: [Double], _ b: [Double]) -> Double {
            let ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
            let iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
            let inter = ix * iy
            let areaA = (a[2] - a[0]) * (a[3] - a[1])
            let areaB = (b[2] - b[0]) * (b[3] - b[1])
            let union = areaA + areaB - inter
            return union > 0 ? inter / union : 0
        }

        /// Glyph center: bbox center when the ink bbox was recoverable,
        /// origin otherwise (a nil `bboxPt` is a deliberate fact — see
        /// `Glyph.bboxPt`'s doc comment — not a zero rect).
        private static func center(_ g: OMRPageLabels.Glyph) -> (Double, Double) {
            if let b = g.bboxPt { return ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2) }
            return (g.originPt[0], g.originPt[1])
        }

        static func matchGlyphs(
            predicted: [OMRPageLabels.Glyph], truth: [OMRPageLabels.Glyph],
            staffSpacingPt: Double,
        ) -> [String: ClassCounts] {
            var out: [String: ClassCounts] = [:]
            let classes = Set(predicted.map(\.className)).union(truth.map(\.className))
            for cls in classes.sorted() {
                out[cls] = matchOneClass(
                    predicted: predicted.filter { $0.className == cls },
                    truth: truth.filter { $0.className == cls },
                    isCenterDistance: centerDistanceClasses.contains(cls),
                    staffSpacingPt: staffSpacingPt,
                )
            }
            return out
        }

        /// One class's greedy match: candidate pairs scored (IoU, or
        /// negated center distance for tiny-ink classes), sorted best
        /// first, then greedily accepted while both sides are unused.
        private static func matchOneClass(
            predicted: [OMRPageLabels.Glyph], truth: [OMRPageLabels.Glyph],
            isCenterDistance: Bool, staffSpacingPt: Double,
        ) -> ClassCounts {
            var counts = ClassCounts()
            var pairs: [(score: Double, pi: Int, ti: Int)] = []
            for (pi, pe) in predicted.enumerated() {
                for (ti, te) in truth.enumerated() {
                    if isCenterDistance {
                        let (px, py) = center(pe)
                        let (tx, ty) = center(te)
                        let d = ((px - tx) * (px - tx) + (py - ty) * (py - ty)).squareRoot()
                        if d <= 0.5 * staffSpacingPt {
                            pairs.append((score: -d, pi: pi, ti: ti))
                        }
                    } else if let pb = pe.bboxPt, let tb = te.bboxPt {
                        let v = iou(pb, tb)
                        if v >= 0.5 { pairs.append((score: v, pi: pi, ti: ti)) }
                    }
                    // A nil bbox on a normal (non-tiny-ink) class never
                    // pairs — it always resolves to fp/fn below, never a
                    // crash and never a fabricated zero-rect match.
                }
            }
            pairs.sort { ($0.score, $0.pi, $0.ti) > ($1.score, $1.pi, $1.ti) }
            var usedP = Set<Int>()
            var usedT = Set<Int>()
            for pair in pairs where !usedP.contains(pair.pi) && !usedT.contains(pair.ti) {
                usedP.insert(pair.pi)
                usedT.insert(pair.ti)
                counts.tp += 1
                let pe = predicted[pair.pi]
                let te = truth[pair.ti]
                let dx = pe.originPt[0] - te.originPt[0]
                let dy = pe.originPt[1] - te.originPt[1]
                counts.originErrPt.append((dx * dx + dy * dy).squareRoot())
                counts.sizeErrPt.append(abs(pe.renderedSizePt - te.renderedSizePt))
            }
            counts.fp = predicted.count - usedP.count
            counts.fn = truth.count - usedT.count
            return counts
        }

        /// Staff spacing from the labels' own staff-line paths, via the
        /// importer's staff detector (reuses tested code): median gap of
        /// adjacent detected staff lines; 8pt fallback when no staff.
        static func staffSpacing(page: OMRPageLabels) -> Double {
            guard let replay = try? OMROracleFrontEnd.replay(pages: [page]) else { return 8 }
            let idx = page.page.index
            let staves = PDFImporter.detectStaves(
                paths: replay.walked.paths.filter { $0.pageIndex == idx },
                classified: replay.walked.glyphs.filter { $0.geometry.pageIndex == idx },
                pageIndex: idx,
            )
            var gaps: [Double] = []
            for staff in staves {
                let ys = staff.yLines.map(Double.init).sorted()
                for i in 1 ..< ys.count {
                    gaps.append(ys[i] - ys[i - 1])
                }
            }
            guard !gaps.isEmpty else { return 8 }
            return gaps.sorted()[gaps.count / 2]
        }

        /// Co-linear horizontal paths unioned into one span per line.
        ///
        /// The vector front-end emits ONE STAFF LINE AS 1 TO 10 SEGMENTS
        /// (measured on this dataset), while a raster front-end emits one
        /// merged segment per line. `staffLineRecall` matches one-to-one,
        /// so comparing the two representations directly scores a perfect
        /// detector at roughly one over the fragment count — the first
        /// raster sweep read 0.176 for exactly this reason, and none of
        /// it was detector error. Spec §8.1 says "per line"; this is what
        /// makes both sides lines.
        ///
        /// Applied to BOTH sides, so the oracle self-check is unaffected.
        /// The tolerance mirrors the importer's own `lineMergeTolerance`.
        static func mergedHorizontals(
            _ paths: [OMRPageLabels.Path], tolerancePt: Double = 2.0,
        ) -> [OMRPageLabels.Path] {
            let lines = paths.filter { $0.kind == "horizontal" }
                .sorted { ($0.rectPt[1], $0.rectPt[0]) < ($1.rectPt[1], $1.rectPt[0]) }
            var out: [OMRPageLabels.Path] = []
            for line in lines {
                guard var last = out.last,
                      abs(last.rectPt[1] - line.rectPt[1]) <= tolerancePt
                else {
                    out.append(line)
                    continue
                }
                last.rectPt[0] = min(last.rectPt[0], line.rectPt[0])
                last.rectPt[2] = max(last.rectPt[2], line.rectPt[2])
                last.rectPt[3] = max(last.rectPt[3], line.rectPt[3])
                last.lineWidthPt = max(last.lineWidthPt, line.lineWidthPt)
                out[out.count - 1] = last
            }
            return out + paths.filter { $0.kind != "horizontal" }
        }

        /// The dy gate `staffLineRecall` applies, in staff spaces.
        ///
        /// Named rather than inlined so a probe can report how far a
        /// near-miss sits from the gate it failed, in the gate's own
        /// units, without a second copy of the number.
        static let staffLineDyGateInSpaces = 0.25

        /// The x-overlap gate `staffLineRecall` applies, as a fraction of
        /// the TRUTH line's width. Same reason as above.
        static let staffLineOverlapGate = 0.8

        static func staffLineRecall(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            staffSpacingPt: Double,
        ) -> (matched: Int, total: Int, endpointErrPt: [Double]) {
            let tLines = truth.filter { $0.kind == "horizontal" }
            let pLines = predicted.filter { $0.kind == "horizontal" }
            let assign = staffLineAssignment(
                predicted: pLines, truth: tLines, staffSpacingPt: staffSpacingPt,
            )
            var errs: [Double] = []
            for (ti, pi) in assign.truthPartner.enumerated() where pi != nil {
                guard let pi else { continue }
                errs.append(abs(pLines[pi].rectPt[0] - tLines[ti].rectPt[0]))
                errs.append(abs(pLines[pi].rectPt[2] - tLines[ti].rectPt[2]))
            }
            return (assign.truthPartner.compactMap(\.self).count, tLines.count, errs)
        }

        /// WHICH prediction each truth staff line is paired with, rather
        /// than only how many pair at all.
        ///
        /// Extracted for the same reason `barlineAssignment` was: a truth
        /// line that matched nothing may have found no candidate, or may
        /// have found one an EARLIER truth line already consumed — the
        /// greedy `used` set makes those two indistinguishable in the
        /// count, and they want opposite fixes. `staffLineRecall` is
        /// written in terms of this, so the two can never disagree.
        ///
        /// Both arrays must already be filtered to `kind == "horizontal"`;
        /// the returned indices refer to them.
        static func staffLineAssignment(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            staffSpacingPt: Double,
        ) -> (truthPartner: [Int?], predMatched: [Bool]) {
            var partner = [Int?](repeating: nil, count: truth.count)
            var used = [Bool](repeating: false, count: predicted.count)
            for (ti, t) in truth.enumerated() {
                var best: (idx: Int, dy: Double)?
                for (i, p) in predicted.enumerated() where !used[i] {
                    guard staffLinePairs(p, t, staffSpacingPt: staffSpacingPt) else { continue }
                    let dy = abs(p.rectPt[1] - t.rectPt[1])
                    if best == nil || dy < best?.dy ?? .infinity { best = (i, dy) }
                }
                if let best {
                    used[best.idx] = true
                    partner[ti] = best.idx
                }
            }
            return (partner, used)
        }

        /// The pair test itself: within the dy gate, and covering at least
        /// `staffLineOverlapGate` of the truth line's width.
        static func staffLinePairs(
            _ p: OMRPageLabels.Path, _ t: OMRPageLabels.Path, staffSpacingPt: Double,
        ) -> Bool {
            let dy = abs(p.rectPt[1] - t.rectPt[1])
            let xOverlap = min(p.rectPt[2], t.rectPt[2]) - max(p.rectPt[0], t.rectPt[0])
            let tWidth = t.rectPt[2] - t.rectPt[0]
            return dy <= staffLineDyGateInSpaces * staffSpacingPt && tWidth > 0
                && xOverlap >= staffLineOverlapGate * tWidth
        }

        static func barlinePR(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            staffSpacingPt: Double,
        ) -> (tp: Int, fp: Int, fn: Int) {
            let tBars = truth.filter { $0.kind == "vertical" }
            let pBars = predicted.filter { $0.kind == "vertical" }
            let assign = barlineAssignment(
                predicted: pBars, truth: tBars, staffSpacingPt: staffSpacingPt,
            )
            let tp = assign.truthMatched.filter(\.self).count
            let usedP = assign.predMatched.filter(\.self).count
            return (tp, pBars.count - usedP, tBars.count - tp)
        }

        /// WHICH verticals the greedy centre-distance match above pairs,
        /// rather than only how many.
        ///
        /// Extracted so a probe can ask a question the counts cannot
        /// answer: an unmatched prediction may be a spurious stroke, or it
        /// may be one segment of a truth vertical the other side merged
        /// differently — and those two want opposite responses. Both input
        /// arrays must already be filtered to `kind == "vertical"`; the
        /// returned flags are indexed to them.
        static func barlineAssignment(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            staffSpacingPt: Double,
        ) -> (truthMatched: [Bool], predMatched: [Bool]) {
            var truthMatched = [Bool](repeating: false, count: truth.count)
            var predMatched = [Bool](repeating: false, count: predicted.count)
            for (ti, t) in truth.enumerated() {
                let tx = (t.rectPt[0] + t.rectPt[2]) / 2
                let ty = (t.rectPt[1] + t.rectPt[3]) / 2
                for (i, p) in predicted.enumerated() where !predMatched[i] {
                    let px = (p.rectPt[0] + p.rectPt[2]) / 2
                    let py = (p.rectPt[1] + p.rectPt[3]) / 2
                    let d = ((px - tx) * (px - tx) + (py - ty) * (py - ty)).squareRoot()
                    if d <= 0.5 * staffSpacingPt {
                        predMatched[i] = true
                        truthMatched[ti] = true
                        break
                    }
                }
            }
            return (truthMatched, predMatched)
        }

        /// Greedy one-to-one beam match: a predicted beam may satisfy at
        /// most ONE truth beam. Candidate pairs need x-overlap and a
        /// top-edge distance within 0.5 × staff spacing at the overlap
        /// midpoint; the closest pairs are accepted first.
        ///
        /// The `used` set is load-bearing. Stacked 16th / 32nd beams sit
        /// ~0.25–0.5 staff spaces apart, and the failure mode a raster
        /// beam detector is most likely to have is FUSING them into one
        /// double-thickness slab under erosion or blur. Without the set,
        /// that one slab would satisfy both truth beams and the metric
        /// would report the fusion — which silently turns every 16th into
        /// an 8th downstream — as a perfect score.
        ///
        /// `coverage` exists because the match criterion above is
        /// PURELY VERTICAL: any x-overlap at all qualifies, so a beam
        /// detected in the right place but truncated to a fraction of its
        /// span still scores a clean true positive. Downstream,
        /// `fullBeamSpans` tests each stem's x against `quad.xRange`, so a
        /// truncated beam silently drops the stems past its end out of the
        /// group and turns their eighths into quarters — with beam recall
        /// still reading 0.97. The fraction of each matched truth beam's
        /// x-range that its prediction actually covers is the dimension
        /// that was missing; it is REPORTED rather than gated, because the
        /// honest shortfall (a slab ends where the outermost stem's ink
        /// begins) is nonzero and its size is a measurement, not a guess.
        static func beamPR(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
            staffSpacingPt: Double,
        ) -> (tp: Int, fp: Int, fn: Int, coverage: [Double]) {
            let accepted = beamAssignment(
                predicted: predicted, truth: truth, staffSpacingPt: staffSpacingPt,
            )
            let coverage = accepted.map {
                xCoverage(predicted[$0.pi], of: truth[$0.ti])
            }
            return (
                accepted.count, predicted.count - accepted.count,
                truth.count - accepted.count, coverage,
            )
        }

        /// WHICH beams the greedy match above pairs, in acceptance order,
        /// rather than only how many.
        ///
        /// Extracted so a probe can ask what the counts cannot: an
        /// unmatched truth beam may be a thin beam nobody saw or the inner
        /// level of a stack whose outer level DID match, and only the
        /// assignment distinguishes them. `beamPR` is written in terms of
        /// this, so the two can never describe different matchings.
        static func beamAssignment(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
            staffSpacingPt: Double,
        ) -> [(pi: Int, ti: Int)] {
            var pairs: [(score: Double, pi: Int, ti: Int)] = []
            for (pi, p) in predicted.enumerated() {
                for (ti, t) in truth.enumerated() {
                    let lo = max(p.x0, t.x0)
                    let hi = min(p.x1, t.x1)
                    guard hi > lo else { continue }
                    let mid = (lo + hi) / 2
                    let d = abs(
                        (p.topSlope * mid + p.topIntercept)
                            - (t.topSlope * mid + t.topIntercept),
                    )
                    if d <= 0.5 * staffSpacingPt { pairs.append((-d, pi, ti)) }
                }
            }
            pairs.sort { ($0.score, $0.pi, $0.ti) > ($1.score, $1.pi, $1.ti) }
            var usedP = Set<Int>()
            var usedT = Set<Int>()
            var accepted: [(pi: Int, ti: Int)] = []
            for pair in pairs where !usedP.contains(pair.pi) && !usedT.contains(pair.ti) {
                usedP.insert(pair.pi)
                usedT.insert(pair.ti)
                accepted.append((pair.pi, pair.ti))
            }
            return accepted
        }

        /// Fraction of `truth`'s x-range covered by `predicted`'s. A
        /// zero-width truth beam (which the labels do not produce, but
        /// which arithmetic must survive) counts as fully covered.
        static func xCoverage(
            _ predicted: OMRPageLabels.Beam, of truth: OMRPageLabels.Beam,
        ) -> Double {
            let span = truth.x1 - truth.x0
            guard span > 0 else { return 1 }
            let overlap = min(predicted.x1, truth.x1) - max(predicted.x0, truth.x0)
            return max(0, min(1, overlap / span))
        }

        /// |top-edge y error| sampled at 5 x positions per MATCHED truth
        /// beam, plus the number of truth beams that matched nothing.
        ///
        /// Returning `unmatchedTruth` is the whole point of this
        /// signature. The previous version returned only the error list
        /// and skipped a truth beam that found no partner, so a
        /// front-end predicting NO BEAMS AT ALL produced an empty list —
        /// which every caller read as "no error", i.e. as a perfect
        /// score. An empty list must be distinguishable from a perfect
        /// match, because for a raster detector those are the two most
        /// likely outcomes.
        static func beamEdgeError(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
        ) -> (errs: [Double], unmatchedTruth: Int) {
            var errs: [Double] = []
            var used = Set<Int>()
            var unmatched = 0
            for t in truth {
                var best: (idx: Int, d: Double)?
                for (i, p) in predicted.enumerated() where !used.contains(i) {
                    let d = abs(p.x0 - t.x0)
                    if best == nil || d < best?.d ?? .infinity { best = (i, d) }
                }
                guard let best else {
                    unmatched += 1
                    continue
                }
                used.insert(best.idx)
                let p = predicted[best.idx]
                for k in 0 ..< 5 {
                    let x = t.x0 + (t.x1 - t.x0) * Double(k) / 4
                    let ty = t.topSlope * x + t.topIntercept
                    let py = p.topSlope * x + p.topIntercept
                    errs.append(abs(py - ty))
                }
            }
            return (errs, unmatched)
        }

        static func curveRecall(
            predicted: [OMRPageLabels.Curve], truth: [OMRPageLabels.Curve],
            staffSpacingPt: Double,
        ) -> (matched: Int, total: Int, endpointErrPt: [Double]) {
            var used = Set<Int>()
            var matched = 0
            var errs: [Double] = []
            for t in truth {
                for (i, p) in predicted.enumerated() where !used.contains(i) {
                    let dl = (
                        (p.leftPt[0] - t.leftPt[0]) * (p.leftPt[0] - t.leftPt[0])
                            + (p.leftPt[1] - t.leftPt[1]) * (p.leftPt[1] - t.leftPt[1]),
                    ).squareRoot()
                    let dr = (
                        (p.rightPt[0] - t.rightPt[0]) * (p.rightPt[0] - t.rightPt[0])
                            + (p.rightPt[1] - t.rightPt[1]) * (p.rightPt[1] - t.rightPt[1]),
                    ).squareRoot()
                    if dl <= staffSpacingPt, dr <= staffSpacingPt {
                        used.insert(i)
                        matched += 1
                        errs.append(dl)
                        errs.append(dr)
                        break
                    }
                }
            }
            return (matched, truth.count, errs)
        }
    }
#endif
