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

        static func staffLineRecall(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            staffSpacingPt: Double,
        ) -> (matched: Int, total: Int, endpointErrPt: [Double]) {
            let tLines = truth.filter { $0.kind == "horizontal" }
            let pLines = predicted.filter { $0.kind == "horizontal" }
            var used = Set<Int>()
            var matched = 0
            var errs: [Double] = []
            for t in tLines {
                var best: (idx: Int, dy: Double)?
                for (i, p) in pLines.enumerated() where !used.contains(i) {
                    let dy = abs(p.rectPt[1] - t.rectPt[1])
                    let xOverlap = min(p.rectPt[2], t.rectPt[2]) - max(p.rectPt[0], t.rectPt[0])
                    let tWidth = t.rectPt[2] - t.rectPt[0]
                    guard dy <= 0.25 * staffSpacingPt, tWidth > 0,
                          xOverlap >= 0.8 * tWidth else { continue }
                    if best == nil || dy < best?.dy ?? .infinity { best = (i, dy) }
                }
                if let best {
                    used.insert(best.idx)
                    matched += 1
                    let p = pLines[best.idx]
                    errs.append(abs(p.rectPt[0] - t.rectPt[0]))
                    errs.append(abs(p.rectPt[2] - t.rectPt[2]))
                }
            }
            return (matched, tLines.count, errs)
        }

        static func barlinePR(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            staffSpacingPt: Double,
        ) -> (tp: Int, fp: Int, fn: Int) {
            let tBars = truth.filter { $0.kind == "vertical" }
            let pBars = predicted.filter { $0.kind == "vertical" }
            var used = Set<Int>()
            var tp = 0
            for t in tBars {
                let tx = (t.rectPt[0] + t.rectPt[2]) / 2
                let ty = (t.rectPt[1] + t.rectPt[3]) / 2
                for (i, p) in pBars.enumerated() where !used.contains(i) {
                    let px = (p.rectPt[0] + p.rectPt[2]) / 2
                    let py = (p.rectPt[1] + p.rectPt[3]) / 2
                    let d = ((px - tx) * (px - tx) + (py - ty) * (py - ty)).squareRoot()
                    if d <= 0.5 * staffSpacingPt {
                        used.insert(i)
                        tp += 1
                        break
                    }
                }
            }
            return (tp, pBars.count - used.count, tBars.count - tp)
        }

        /// |top-edge y error| sampled at 5 x positions per truth beam
        /// against its nearest (by x0) predicted beam.
        static func beamEdgeError(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
        ) -> [Double] {
            var errs: [Double] = []
            for t in truth {
                guard let p = predicted.min(by: { abs($0.x0 - t.x0) < abs($1.x0 - t.x0) })
                else { continue }
                for k in 0 ..< 5 {
                    let x = t.x0 + (t.x1 - t.x0) * Double(k) / 4
                    let ty = t.topSlope * x + t.topIntercept
                    let py = p.topSlope * x + p.topIntercept
                    errs.append(abs(py - ty))
                }
            }
            return errs
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
