#if !os(Android)
    import Foundation

    /// The printing half of `OMRStaffLineDiagnostics`.
    ///
    /// Split from the accumulation for the same reason
    /// `ScoreSemanticMetrics+Report` is: the counters and their formatting
    /// change for different reasons, and together they push one type past
    /// the body-length cap.
    extension OMRStaffLineDiagnostics {
        static func row(_ row: Row) -> String {
            let mech = Mechanism.allCases
                .map { "\($0.rawValue)=\(row.mechanism[$0.rawValue] ?? 0)" }
                .joined(separator: " ")
            return "truth=\(row.truth) matched=\(row.matched) "
                + "solid=\(row.solid) solidMatched=\(row.solidMatched) "
                + "pred=\(row.pred) predFalse=\(row.predUnmatched) " + mech
                + " stavesRaster=\(row.stavesRaster) "
                + "stavesTruthLines=\(row.stavesSubstituted) "
                + "stavesAligned=\(row.stavesAligned) "
                + "dyN=\(row.dyN) dyMean=" + String(format: "%+.4f", mean(row))
                + " dySd=" + String(format: "%.4f", sd(row))
                + " dyAbsMax=" + String(format: "%.4f", row.dyAbsMax)
        }

        private static func mean(_ row: Row) -> Double {
            row.dyN > 0 ? row.dySum / Double(row.dyN) : 0
        }

        private static func sd(_ row: Row) -> Double {
            guard row.dyN > 1 else { return 0 }
            let n = Double(row.dyN)
            return max(0, row.dySumSq / n - (row.dySum / n) * (row.dySum / n)).squareRoot()
        }

        /// One line per REAL staff line the front-end did not emit —
        /// where it is, how wide, and which mechanism.
        ///
        /// Printed rather than bucketed because the population is small
        /// and each member is individually actionable: these are the only
        /// staff-line misses that can cost a staff, and a staff is what
        /// costs score points.
        static func solidMissRows(_ row: Row, prefix: String) -> [String] {
            row.solidMissed.map { miss in
                let r = miss.line.rectPt
                return prefix + " y=" + String(format: "%.1f", r[1])
                    + " x0=" + String(format: "%.1f", r[0])
                    + " x1=" + String(format: "%.1f", r[2])
                    + " w=" + String(format: "%.1f", r[2] - r[0])
                    + " lw=" + String(format: "%.2f", miss.line.lineWidthPt)
                    + " mech=\(miss.mechanism.rawValue)"
            }
        }

        static func report(_ totals: Totals) {
            let recall = totals.truthTotal > 0
                ? Double(totals.matched) / Double(totals.truthTotal) : 0
            let missed = totals.truthTotal - totals.matched
            print(
                "[sldiag][SUMMARY] pages=\(totals.pages) truth=\(totals.truthTotal) "
                    + "matched=\(totals.matched) recall=\(String(format: "%.4f", recall)) "
                    + "missed=\(missed) pred=\(totals.predTotal) "
                    + "predFalse=\(totals.predUnmatched)",
            )
            let assigned = Mechanism.allCases
                .map { totals.mechanism[$0.rawValue] ?? 0 }.reduce(0, +)
            for mechanism in Mechanism.allCases {
                let n = totals.mechanism[mechanism.rawValue] ?? 0
                let share = missed > 0 ? Double(n) / Double(missed) * 100 : 0
                print(
                    "[sldiag][mech] \(mechanism.rawValue)=\(n) "
                        + "share=\(String(format: "%.1f", share))%",
                )
            }
            print("[sldiag][mech] assigned=\(assigned) missed=\(missed)")
            let solidRecall = totals.solidTotal > 0
                ? Double(totals.solidMatched) / Double(totals.solidTotal) : 0
            print(
                "[sldiag][solid] truth=\(totals.solidTotal) "
                    + "matched=\(totals.solidMatched) "
                    + "recall=\(String(format: "%.4f", solidRecall)) "
                    + "missed=\(totals.solidTotal - totals.solidMatched) "
                    + Mechanism.allCases
                    .map { "\($0.rawValue)=\(totals.solidMechanism[$0.rawValue] ?? 0)" }
                    .joined(separator: " "),
            )
            reportCounterfactuals(totals)
            reportPopulation(totals)
            reportStaves(totals)
            reportMatchedDy(totals)
            reportGeometry(totals.geometry)
        }

        /// The SIGNED error of the lines the metric was happy with.
        ///
        /// Reported as mean / sd / shape rather than as |dy|, because
        /// those separate the only two answers that matter: a mean far
        /// from zero with a small sd is one rounding site and is fixable;
        /// a mean at zero with a wide sd is per-line jitter and is not.
        private static func reportMatchedDy(_ totals: Totals) {
            let n = Double(totals.matchedDyN)
            guard n > 0 else { return }
            let mean = totals.matchedDySum / n
            let variance = max(0, totals.matchedDySumSq / n - mean * mean)
            print(
                "[sldiag][mdy][SUMMARY] n=\(totals.matchedDyN) "
                    + "meanSp=" + String(format: "%+.4f", mean)
                    + " sdSp=" + String(format: "%.4f", variance.squareRoot())
                    + " meanPt=" + String(format: "%+.4f", mean * 4.56),
            )
            var running = 0
            for b in totals.matchedDy.keys.sorted() {
                running += totals.matchedDy[b] ?? 0
                print(
                    "[sldiag][mdy] dySp=" + String(format: "%+.2f", Double(b) * 0.05)
                        + " n=\(totals.matchedDy[b] ?? 0) "
                        + "solid=\(totals.matchedDySolid[b] ?? 0) cum=\(running)",
                )
            }
        }

        /// The two gate sweeps, as cumulative recoveries.
        private static func reportCounterfactuals(_ totals: Totals) {
            var running = 0
            for bucket in totals.offsetDy.keys.sorted() {
                running += totals.offsetDy[bucket] ?? 0
                print(
                    "[sldiag][dy] dySp=\(Double(bucket) / 20) n=\(totals.offsetDy[bucket] ?? 0) "
                        + "cumulativeIfGateWidened=\(running)",
                )
            }
            var remaining = totals.truncatedCoverage.values.reduce(0, +)
            for bucket in totals.truncatedCoverage.keys.sorted() {
                print(
                    "[sldiag][cov] cov=\(Double(bucket) / 20) "
                        + "n=\(totals.truncatedCoverage[bucket] ?? 0) "
                        + "cumulativeIfGateLowered=\(remaining)",
                )
                remaining -= totals.truncatedCoverage[bucket] ?? 0
            }
        }

        private static func reportPopulation(_ totals: Totals) {
            for bucket in Set(totals.widthFracHit.keys)
                .union(totals.widthFracMiss.keys).sorted()
            {
                print(
                    "[sldiag][width] frac=\(Double(bucket) / 20) "
                        + "hit=\(totals.widthFracHit[bucket] ?? 0) "
                        + "miss=\(totals.widthFracMiss[bucket] ?? 0)",
                )
            }
            for bucket in Set(totals.inkFracHit.keys)
                .union(totals.inkFracMiss.keys).sorted()
            {
                print(
                    "[sldiag][ink] frac=\(Double(bucket) / 20) "
                        + "hit=\(totals.inkFracHit[bucket] ?? 0) "
                        + "miss=\(totals.inkFracMiss[bucket] ?? 0)",
                )
            }
            for key in Set(totals.positionHit.keys)
                .union(totals.positionMiss.keys).sorted()
            {
                print(
                    "[sldiag][pos] key=\(key) hit=\(totals.positionHit[key] ?? 0) "
                        + "miss=\(totals.positionMiss[key] ?? 0)",
                )
            }
        }

        private static func reportStaves(_ totals: Totals) {
            print(
                "[sldiag][staves] raster=\(totals.stavesRaster) "
                    + "truthLines=\(totals.stavesSubstituted) "
                    + "aligned=\(totals.stavesAligned) "
                    + "pagesEqual=\(totals.pagesStaffCountEqual) "
                    + "pagesRasterFewer=\(totals.pagesRasterFewer) "
                    + "pagesRasterMore=\(totals.pagesRasterMore)",
            )
            print(
                "[sldiag][even] incompleteKept=\(totals.evenKeptIncomplete) "
                    + "incompleteLost=\(totals.evenLostIncomplete)",
            )
            var keptRunning = 0
            var lostRunning = 0
            for bucket in Set(totals.evenKept.keys).union(totals.evenLost.keys).sorted() {
                keptRunning += totals.evenKept[bucket] ?? 0
                lostRunning += totals.evenLost[bucket] ?? 0
                print(
                    "[sldiag][even] cv=\(Double(bucket) / 200) "
                        + "kept=\(totals.evenKept[bucket] ?? 0) "
                        + "lost=\(totals.evenLost[bucket] ?? 0) "
                        + "cumKept=\(keptRunning) cumLost=\(lostRunning)",
                )
            }
            for detail in totals.lostDetail.sorted() {
                print("[sldiag][lost] " + detail)
            }
        }

        /// What the consumers of a KEPT staff actually read, both ways.
        ///
        /// `geo` is priced in consumer units on purpose: `flip` is a
        /// wrong PITCH for every note on that staff position and `bars`
        /// is a wrong MEASURE GRID, whereas a dy bucket is only a number
        /// until something reads it.
        private static func reportGeometry(_ geo: StaffGeometry) {
            guard geo.pairs > 0 else { return }
            print(
                "[sldiag][geo][SUMMARY] pairs=\(geo.pairs) "
                    + "pitchFlipStaves=\(geo.pitchFlipStaves) "
                    + "barlineEqual=\(geo.barlinePairsEqual) "
                    + "barlineDiff=\(geo.pairs - geo.barlinePairsEqual)",
            )
            sweep(geo.anchorDy, tag: "anchorDy", scale: 0.05)
            sweep(geo.spanErr, tag: "spanErr", scale: 0.05)
            sweep(geo.maxAbsDy, tag: "maxAbsDy", scale: 0.05)
            for k in geo.pitchFlipByPosition.keys.sorted() {
                print("[sldiag][geo][flip] position=\(k) staves=\(geo.pitchFlipByPosition[k] ?? 0)")
            }
            for d in geo.barlineDelta.keys.sorted() {
                print("[sldiag][geo][bars] delta=\(d) pairs=\(geo.barlineDelta[d] ?? 0)")
            }
            for d in geo.xLoErr.keys.sorted() {
                print("[sldiag][geo][xlo] dSp=\(d) pairs=\(geo.xLoErr[d] ?? 0)")
            }
            for d in geo.xHiErr.keys.sorted() {
                print("[sldiag][geo][xhi] dSp=\(d) pairs=\(geo.xHiErr[d] ?? 0)")
            }
            for detail in geo.detail.sorted() {
                print("[sldiag][geo][staff] " + detail)
            }
        }

        /// One bucketed quantity with its cumulative column — the form
        /// every counterfactual in this probe is read in.
        private static func sweep(_ histogram: [Int: Int], tag: String, scale: Double) {
            var running = 0
            for b in histogram.keys.sorted() {
                running += histogram[b] ?? 0
                print(
                    "[sldiag][geo][\(tag)] sp=" + String(format: "%+.2f", Double(b) * scale)
                        + " n=\(histogram[b] ?? 0) cum=\(running)",
                )
            }
        }
    }
#endif
