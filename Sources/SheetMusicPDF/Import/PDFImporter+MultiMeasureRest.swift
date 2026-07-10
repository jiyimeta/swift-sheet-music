import CoreGraphics
import Foundation
import SheetMusicCore

/// Stage [11b] — expand multi-measure rests back into individual measures.
///
/// When "Create multimeasure rests" is enabled, MuseScore collapses a run of
/// N consecutive all-staff empty measures into a single H-bar cell captioned
/// with the count "N" (drawn as SMuFL timeSig digits, U+E080–E089, ABOVE the
/// staff — distinct from a real time signature, which sits ON the staff). The
/// importer's cell detector sees that H-bar as ONE measure, so the imported
/// score is short by N-1 bars per collapsed run, and every measure after the
/// run is index-shifted relative to the uncollapsed source.
///
/// This pre-pass runs on the `ImportSystem` tree before assembly and rewrites
/// each detected mm-rest column into N measures: the original (now a plain
/// whole-measure rest) plus N-1 synthetic empty cells. It operates per system
/// with a whole-system consensus so every staff expands the same column by the
/// same N — mm-rests span all staves, so they stay measure-aligned.
extension PDFImporter {
    /// Expand every multi-measure-rest H-bar into its constituent measures.
    /// Idempotent-safe and conservative: only fires on a column that is empty
    /// (no noteheads) across ALL staves of the system AND carries an
    /// above-staff timeSig-digit count ≥ 2. Returns the systems unchanged when
    /// no such column exists (the common case).
    static func expandMultiMeasureRests(
        _ systems: [ImportSystem],
        diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)? = nil,
    ) -> [ImportSystem] {
        systems.enumerated().map { index, system in
            expandSystem(system, sysIndex: index, diagnostics: diagnostics)
        }
    }

    private static func expandSystem(
        _ system: ImportSystem,
        sysIndex: Int,
        diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?,
    ) -> ImportSystem {
        let allStaves = system.parts.flatMap(\.staves)
        // A column index only means the same measure across staves when every
        // staff has the same cell count. mm-rests share barlines across all
        // staves, so on a genuine mm-rest system this holds; when it doesn't,
        // skip rather than risk desynchronizing the staves.
        guard let cols = allStaves.first?.measures.count, cols > 0,
              allStaves.allSatisfy({ $0.measures.count == cols })
        else { return system }

        var colCount = [Int?](repeating: nil, count: cols)
        for c in 0 ..< cols {
            // Genuine synchronized mm-rest ⇒ every staff rests (no noteheads).
            guard allStaves.allSatisfy({ !hasNotehead($0.measures[c]) }) else { continue }
            let votes = allStaves.compactMap { mmRestCount(cell: $0.measures[c]) }
            guard let n = modeCount(votes) else { continue }
            colCount[c] = n
        }
        guard colCount.contains(where: { $0 != nil }) else { return system }

        var newSystem = system
        for pi in newSystem.parts.indices {
            for si in newSystem.parts[pi].staves.indices {
                newSystem.parts[pi].staves[si].measures = expandStaff(
                    newSystem.parts[pi].staves[si].measures, colCount: colCount,
                )
            }
        }
        if let diagnostics {
            let expanded = colCount.compactMap(\.self)
            diagnostics(PDFImportDiagnostic(
                severity: .info,
                location: "page \(system.pageIndex), system \(sysIndex)",
                message: "expanded \(expanded.count) multi-measure rest(s)",
                context: "counts=\(expanded)",
            ))
        }
        return newSystem
    }

    /// Rewrite one staff's cell list, replacing each mm-rest column with its
    /// N constituent measures (the bar itself + N-1 synthetic empties).
    private static func expandStaff(
        _ measures: [ImportMeasure], colCount: [Int?],
    ) -> [ImportMeasure] {
        var out: [ImportMeasure] = []
        out.reserveCapacity(measures.count)
        for (c, cell) in measures.enumerated() {
            guard let n = c < colCount.count ? colCount[c] : nil else {
                out.append(cell)
                continue
            }
            var bar = cell
            // Drop the above-staff count digits so `buildMeasures` cannot read
            // a spurious time signature off the collapsed bar; leave anything
            // on the staff (a genuine courtesy signature) intact.
            let cutoff = staffTopLine(cell.staffYLines) + countDigitMargin(cell.staffYLines)
            bar.glyphs = cell.glyphs.filter { g in
                if case .timeSignatureDigit = g.semantic, g.raw.origin.y > cutoff {
                    return false
                }
                return true
            }
            out.append(bar)
            for _ in 1 ..< n {
                out.append(ImportMeasure(
                    xRange: cell.xRange,
                    glyphs: [],
                    leadingBarline: nil,
                    trailingBarline: nil,
                    staffYLines: cell.staffYLines,
                ))
            }
        }
        return out
    }

    /// The multi-measure-rest count drawn above `cell`, or nil when the cell
    /// is not an mm-rest bar. The count is a run of SMuFL timeSig digits
    /// (U+E080–E089) positioned above the top staff line; a real time
    /// signature sits within the staff band and is excluded by the y-gate.
    private static func mmRestCount(cell: ImportMeasure) -> Int? {
        guard !hasNotehead(cell) else { return nil }
        let lines = cell.staffYLines
        guard lines.count >= 2 else { return nil }
        let cutoff = staffTopLine(lines) + countDigitMargin(lines)
        let digits = cell.glyphs.compactMap { g -> (x: CGFloat, d: Int)? in
            guard case let .timeSignatureDigit(d) = g.semantic,
                  g.raw.origin.y > cutoff else { return nil }
            return (g.raw.origin.x, d)
        }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        var value = 0
        for (_, d) in digits.sorted(by: { $0.x < $1.x }) {
            value = value * 10 + d
        }
        return value >= 2 ? value : nil
    }

    private static func hasNotehead(_ cell: ImportMeasure) -> Bool {
        cell.glyphs.contains { isNotehead($0.semantic) }
    }

    private static func staffTopLine(_ yLines: [CGFloat]) -> CGFloat {
        yLines.max() ?? 0
    }

    /// Half a staff-line spacing above the top line — a count digit clears
    /// this; a time-signature digit (on the staff) does not.
    private static func countDigitMargin(_ yLines: [CGFloat]) -> CGFloat {
        guard let lo = yLines.min(), let hi = yLines.max(), hi > lo else { return 3 }
        return (hi - lo) / CGFloat(max(yLines.count - 1, 1)) * 0.5
    }

    /// Most frequent value, or nil for an empty list. Ties resolve to the
    /// larger value (deterministic; a mis-detected small count should not win
    /// over the true larger count).
    private static func modeCount(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var freq: [Int: Int] = [:]
        for v in values {
            freq[v, default: 0] += 1
        }
        return freq.max { a, b in
            a.value != b.value ? a.value < b.value : a.key < b.key
        }?.key
    }
}
