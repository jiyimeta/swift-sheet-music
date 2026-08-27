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
                + "stavesAligned=\(row.stavesAligned)"
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
    }
#endif
