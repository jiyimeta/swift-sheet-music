#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF

    /// The half of `OMRStaffLineDiagnostics` that measures a staff the
    /// raster KEPT against the same staff built from truth lines.
    ///
    /// Round one measured the staves the raster LOSES and closed that gap
    /// (27 → 2 of 574). What it could not measure is the staff that
    /// survives with slightly wrong geometry, because every line-level
    /// gate it had is wider than the error: the seam's dy gate is 0.25 sp
    /// = 1.14pt and `gapCV < 0.1` is a pass/fail on evenness, not on
    /// position. A staff placed half a raster row low passes both and is
    /// still a different staff to everything downstream.
    ///
    /// So this asks the consumers' own questions instead of a
    /// line-geometry one:
    ///
    ///   * `staffAnchor` reads `yLines.first` (the pitch origin) and
    ///     `yLines.last − yLines.first` (the pitch scale) and NOTHING
    ///     between them, then quantises `(noteheadY − bottomY) / (span/8)`
    ///     with `.rounded()`. The counterfactual that matters is
    ///     therefore not "how big is dy" but "does a notehead on truth
    ///     staff position k still round to k".
    ///   * `barlineCandidates` reads those same two lines plus `xRange`,
    ///     and its output is the measure grid.
    ///
    /// Both are recorded per aligned pair so the corpus histogram and the
    /// per-render score deltas describe one experiment.
    extension OMRStaffLineDiagnostics {
        /// Staff positions, in half-spaces above the bottom line, at which
        /// a notehead is tested. 0…8 is the staff itself; the margin
        /// reaches the ledger positions that carry real notes, where an
        /// error in the SCALE has had the longest lever to act.
        static let pitchProbePositions = -6 ... 14

        static func compareGeometry(
            raster: SheetMusicPDF.Staff, truth: SheetMusicPDF.Staff,
            spacingPt: Double, label: String, into geo: inout StaffGeometry,
        ) {
            guard spacingPt > 0, raster.yLines.count == 5, truth.yLines.count == 5,
                  let rLo = raster.yLines.first, let rHi = raster.yLines.last,
                  let tLo = truth.yLines.first, let tHi = truth.yLines.last,
                  rHi > rLo, tHi > tLo
            else { return }
            geo.pairs += 1
            let anchorDy = Double(rLo - tLo) / spacingPt
            let spanErr = Double((rHi - rLo) - (tHi - tLo)) / spacingPt
            let maxAbsDy = zip(raster.yLines, truth.yLines)
                .map { abs(Double($0 - $1)) / spacingPt }.max() ?? 0
            geo.anchorDy[bucket(anchorDy), default: 0] += 1
            geo.spanErr[bucket(spanErr), default: 0] += 1
            geo.maxAbsDy[bucket(maxAbsDy), default: 0] += 1

            let flips = pitchFlips(raster: raster, truth: truth)
            for k in flips {
                geo.pitchFlipByPosition[k, default: 0] += 1
            }
            if !flips.isEmpty { geo.pitchFlipStaves += 1 }

            let dBars = raster.barlineCandidates.count - truth.barlineCandidates.count
            geo.barlineDelta[dBars, default: 0] += 1
            if dBars == 0 { geo.barlinePairsEqual += 1 }
            let dLo = Double(raster.xRange.lowerBound - truth.xRange.lowerBound) / spacingPt
            let dHi = Double(raster.xRange.upperBound - truth.xRange.upperBound) / spacingPt
            geo.xLoErr[Int(dLo.rounded()), default: 0] += 1
            geo.xHiErr[Int(dHi.rounded()), default: 0] += 1

            guard dBars != 0 || !flips.isEmpty || abs(dLo) >= 1 || abs(dHi) >= 1 else { return }
            geo.detail.append(
                label + " y=" + String(format: "%.1f", Double(tLo))
                    + " anchorDy=" + String(format: "%+.3f", anchorDy)
                    + " spanErr=" + String(format: "%+.3f", spanErr)
                    + " maxDy=" + String(format: "%.3f", maxAbsDy)
                    + " flips=" + (flips.isEmpty
                        ? "-" : flips.map(String.init).joined(separator: "/"))
                    + " bars=\(raster.barlineCandidates.count)"
                    + "/\(truth.barlineCandidates.count)"
                    + " dxLo=" + String(format: "%+.2f", dLo)
                    + " dxHi=" + String(format: "%+.2f", dHi),
            )
        }

        /// The staff positions whose notehead the raster's anchor would
        /// quantise to a DIFFERENT diatonic step than the truth staff's.
        ///
        /// This is `PDFImporter.pitchKey` with its own arithmetic: a
        /// notehead is placed at the y truth says position k is at, and
        /// read back through the raster's anchor. Anything but k is a
        /// wrong pitch for every note that lands on that position.
        static func pitchFlips(
            raster: SheetMusicPDF.Staff, truth: SheetMusicPDF.Staff,
        ) -> [Int] {
            guard let rLo = raster.yLines.first, let rHi = raster.yLines.last,
                  let tLo = truth.yLines.first, let tHi = truth.yLines.last,
                  rHi > rLo, tHi > tLo
            else { return [] }
            let rHalf = (rHi - rLo) / CGFloat(raster.yLines.count - 1) / 2
            let tHalf = (tHi - tLo) / CGFloat(truth.yLines.count - 1) / 2
            guard rHalf > 0 else { return [] }
            return pitchProbePositions.filter { k in
                let y = tLo + CGFloat(k) * tHalf
                return Int(((y - rLo) / rHalf).rounded()) != k
            }
        }

        /// 0.05-staff-space buckets, floored so the sign survives and the
        /// buckets tile the axis evenly through zero.
        static func bucket(_ valueSp: Double) -> Int {
            Int((valueSp / 0.05).rounded(.down))
        }
    }
#endif
