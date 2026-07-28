#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// TUPLET REPAIR — the tuplet-aware fallback of the metric-sum
// reconciliation pass (PDFImporter+RhythmReconcile). Split out of that
// file to keep each under the SwiftLint length cap.
//
// Why a separate pass: this is the FALLBACK for tuplets whose engraved
// mark could not be read. `PDFImporter+TupletMark` handles the normal
// case — MuseScore does emit the tuplet number as ordinary text and its
// bracket as ordinary paths, contrary to what this comment used to claim
// (measured 2026-07-28: `pdftotext` recovers all 8 tuplet numbers in
// Now_is_the_time.pdf, and the bracket arms and hooks appear as
// `.horizontal` / `.vertical` segments). This pass stays for documents
// where the number is missing, suppressed, or unreadable: it infers a
// tuplet from rhythm alone — a contiguous run of equal beamed notes whose
// straight reading over-fills the bar but whose 2/3-scaled reading makes
// the voice sum EXACTLY to the bar length and shows the tight-spacing
// boundary signature of a real tuplet.
//
// GATING (zero risk to a balanced score, e.g. ギブス which has no
// tuplets and whose voices already sum to the bar): this runs only after
// the single-note straight repair fails, and only when the run's scaling
// hits the bar length exactly AND the run's geometry matches a tuplet —
// so a balanced voice never reaches it and a straight rhythm is never
// re-read as a tuplet.

extension PDFImporter {
    // MARK: - Tuplet repair (metric + geometry gated)

    /// Allowed tuplet member counts and their `normalNotes/actualNotes`
    /// ratio (the per-member duration scale). A triplet is 3 notes in the
    /// time of 2 (scale 2/3); a sextuplet is 6 in the time of 4 (also 2/3).
    /// The corpus's tuplets are all `<actualNotes>3</actualNotes>` triplets;
    /// 6 is admitted because it shares the 2/3 scale and the same metric
    /// gate. Higher / irregular tuplets (5, 7) and nested tuplets are NOT
    /// attempted — they are left unchanged (and flagged) by the caller.
    static let tupletRatios: [(count: Int, normal: Int, actual: Int)] = [
        (3, 2, 3),
        (6, 4, 6),
    ]

    /// A run qualifies as a tuplet only when the gap to the FOLLOWING note
    /// (the next beat's onset) is at least this multiple of the run's own
    /// internal note-to-note gap. A real triplet packs N notes into the
    /// space of N-1, so its members sit closer together than the surrounding
    /// straight notes; the boundary gap to the next beat is therefore
    /// noticeably wider. A "run" that is really part of a LONGER even straight
    /// beam has `afterGap ≈ inGap` (ratio ≈ 1) and is rejected — this is the
    /// signal that stops the metric-sum gate from over-firing on dense
    /// straight rhythms (without it, 群青日和 created 36 `1/12` notes against
    /// A's 18, re-reading straight eighths as triplets and regressing dur%).
    /// Threshold 1.35 sits well below a true triplet's ~2× boundary gap and
    /// well above a straight even run's ~1×.
    static let tupletBoundaryGapRatio: CGFloat = 1.35

    /// Maximum relative spread (max-gap ÷ min-gap) the run's internal
    /// note-to-note gaps may show. MuseScore engraves a tuplet's members
    /// EVENLY, so a real tuplet's internal gaps are near-uniform (ratio ≈ 1).
    /// A run whose gaps alternate widely (observed: 13.1 / 16.4 in a
    /// would-be sextuplet) is a beam-grouping artifact over a straight
    /// rhythm, not a tuplet — rejected. 1.5 admits ordinary engraving jitter
    /// (and the natural slight widening at an accidental) while excluding the
    /// 2-cluster alternation of a mis-grouped straight run.
    static let tupletMaxInternalSpread: CGFloat = 1.5

    /// Minimum mean internal note-gap a VOICE-ENDING run must have to be
    /// auto-accepted on the metric + uniformity gates alone (it has no
    /// following note to supply a boundary-gap signal), expressed in SPATIA.
    /// Below this — very tight spacing — the run-end auto-accept is unreliable
    /// (3 equal tight notes that close the bar by coincidence look identical to
    /// a real tuplet without a boundary), so we instead require a real
    /// following-gap.
    ///
    /// Was an absolute 8pt, which is spatium-DEPENDENT: カゲロウ's real
    /// sixteenth-triplets (~6pt on its small spatium ≈ 3.3pt → ~1.8sp) were
    /// wrongly rejected while 群青's sextuplets (~9–14pt on spatium ≈ 5pt →
    /// ~1.8–2.8sp) passed — the SAME relative spacing treated differently. A
    /// spatium-relative 1.5sp threshold admits both the カゲロウ triplets and
    /// the 群青 sextuplets, while still rejecting a genuinely too-tight run
    /// (< 1.5sp) whose voice-ending auto-accept can't be trusted. Verified
    /// zero-regression across the 6-score corpus (only カゲロウ dur moved, +6).
    static let tupletRunEndMinGapSpatia: CGFloat = 1.5

    /// Try to repair an unbalanced voice by re-reading one contiguous run of
    /// equal beamed notes as a tuplet. Scans every candidate run; applies the
    /// FIRST whose 2/3-scaling both (a) makes the whole voice sum EXACTLY to
    /// the bar length AND (b) shows the compressed-spacing boundary signature
    /// of a real tuplet. Returns true (mutating `elements`) on a repair.
    ///
    /// Each scaled member's duration is stored as the SAME `.fraction` form
    /// the mscx ground truth carries (a triplet eighth = `1/8 × 2/3` → reduced
    /// `1/12`; a triplet quarter → `1/6`; a triplet sixteenth → `1/24`), so a
    /// recovered member is byte-identical to Score A's value.
    ///
    /// Gate rationale (zero risk to a balanced score):
    ///   * Only reached when no single-note straight repair fit — so a
    ///     straight rhythm the proven single-note pass can fix is never
    ///     re-interpreted as a tuplet.
    ///   * The run must be ≥3 ADJACENT note-bearing chords (rests break a
    ///     run) of EQUAL power-of-two duration — the visual signature of a
    ///     beamed tuplet. A run already carrying `.fraction` values (a prior
    ///     tuplet) is skipped.
    ///   * The scaled voice must hit the bar length to the exact `Fraction`.
    ///   * The run's spacing must match a tuplet (`runHasTupletSpacing`).
    static func tupletRepair(
        indices: [Int],
        barLength: Fraction,
        currentSum: Fraction,
        spatium: CGFloat,
        elements: inout [RhythmElement],
        location: String = "",
    ) -> Bool {
        // Note-bearing indices in x-onset order (rests included so they break
        // adjacency, but only chords are scaled).
        let ordered = indices.sorted { elements[$0].x < elements[$1].x }
        for spec in tupletRatios {
            guard let run = firstEqualNoteRun(
                length: spec.count, ordered: ordered, elements: elements,
            ) else { continue }
            // Base duration shared by the run (validated equal + power-of-two
            // in `firstEqualNoteRun`).
            let base = elements[run[0]].chord.duration.asFraction
            let scaled = Fraction(
                numerator: base.numerator * spec.normal,
                denominator: base.denominator * spec.actual,
            )
            // New voice sum = currentSum - (run straight sum) + (run scaled).
            let straightRun = Fraction(
                numerator: base.numerator * spec.count,
                denominator: base.denominator,
            )
            let scaledRun = Fraction(
                numerator: scaled.numerator * spec.count,
                denominator: scaled.denominator,
            )
            let newSum = currentSum - straightRun + scaledRun
            guard newSum == barLength else { continue }
            guard runHasTupletSpacing(
                run: run, ordered: ordered, elements: elements, spatium: spatium,
            ) else { continue }
            debugTupletFire(
                spec: spec, base: base, scaled: scaled,
                run: run, location: location, elements: elements,
            )
            for idx in run {
                elements[idx].chord.duration = .fraction(scaled)
                elements[idx].lowConfidenceDuration = false
            }
            return true
        }
        return false
    }

    /// Whether `run`'s x-spacing carries the tuplet compression signature:
    ///   1. Its internal note-to-note gaps are near-uniform (even engraving)
    ///      — `max/min ≤ tupletMaxInternalSpread`.
    ///   2. The gap to the next note is ≥ `tupletBoundaryGapRatio` × the run's
    ///      mean internal gap — the compression boundary. A run that is really
    ///      part of a longer even straight beam fails #2 (boundary gap ≈
    ///      internal gap). A VOICE-ENDING run (no following note) is accepted
    ///      on the metric + uniformity gates ONLY when its spacing is wide
    ///      enough (`≥ tupletRunEndMinGap`) for those gates to be trustworthy.
    private static func runHasTupletSpacing(
        run: [Int], ordered: [Int], elements: [RhythmElement], spatium: CGFloat,
    ) -> Bool {
        guard run.count >= 2 else { return false }
        let runXs = run.map { elements[$0].x }
        let inGaps = zip(runXs.dropFirst(), runXs).map { $0 - $1 }
        let meanIn = inGaps.reduce(0, +) / CGFloat(inGaps.count)
        guard meanIn > 0.5 else { return false }
        // #1 internal uniformity.
        if let lo = inGaps.min(), let hi = inGaps.max(),
           lo > 0.5, hi / lo > tupletMaxInternalSpread
        {
            return false
        }
        // #2 boundary gap.
        guard let lastPos = ordered.firstIndex(of: run[run.count - 1])
        else { return false }
        let afterPos = lastPos + 1
        // Voice-ending run: accept only if its spacing is wide enough that the
        // metric + uniformity gates are trustworthy without a boundary signal.
        guard afterPos < ordered.count else {
            return meanIn >= tupletRunEndMinGapSpatia * spatium
        }
        let afterGap = elements[ordered[afterPos]].x - (runXs.last ?? 0)
        return afterGap >= tupletBoundaryGapRatio * meanIn
    }

    /// The first contiguous run of `length` adjacent note-bearing chords (no
    /// rest between them) that all share the SAME power-of-two duration.
    /// Returns the run's indices (into `elements`) or nil. A run containing a
    /// rest, a `.fraction`/`.measure` duration, or unequal values is rejected
    /// — only a clean beamed group of equal straight notes qualifies.
    private static func firstEqualNoteRun(
        length: Int,
        ordered: [Int],
        elements: [RhythmElement],
    ) -> [Int]? {
        guard ordered.count >= length else { return nil }
        var run: [Int] = []
        var runDur: NoteDuration?
        for idx in ordered {
            if elements[idx].isRest {
                run.removeAll(); runDur = nil; continue
            }
            let d = elements[idx].chord.duration
            guard isPowerOfTwoValue(d) else {
                run.removeAll(); runDur = nil; continue
            }
            if let rd = runDur, rd == d {
                run.append(idx)
            } else {
                run = [idx]
                runDur = d
            }
            if run.count == length { return run }
        }
        return nil
    }

    /// Whether a duration is a plain power-of-two value (whole…64th) — the
    /// only durations a tuplet run may scale. Dotted (`.fraction`),
    /// already-tupleted (`.fraction`), and `.measure` are excluded.
    private static func isPowerOfTwoValue(_ d: NoteDuration) -> Bool {
        switch d {
        case .whole, .half, .quarter, .eighth,
             .sixteenth, .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            return true
        default:
            return false
        }
    }

    /// SPIKE diagnostic — print one applied tuplet repair (count, base /
    /// scaled value, internal gaps, measure location) when
    /// `PDF_TUPLET_DEBUG=1`. No-op otherwise. Lets the corpus harness localize
    /// every fire to a page / system / measure for false-positive auditing.
    private static func debugTupletFire(
        spec: (count: Int, normal: Int, actual: Int),
        base: Fraction, scaled: Fraction,
        run: [Int], location: String, elements: [RhythmElement],
    ) {
        guard ProcessInfo.processInfo.environment["PDF_TUPLET_DEBUG"] == "1"
        else { return }
        let runXs = run.map { elements[$0].x }
        let inGaps = zip(runXs.dropFirst(), runXs).map { $0 - $1 }
        let meanIn = inGaps.isEmpty
            ? 0 : inGaps.reduce(0, +) / CGFloat(inGaps.count)
        print(String(
            format: "[TUPFIRE] cnt=%d base=%d/%d scaled=%d/%d inGaps=%@ "
                + "meanIn=%.1f x0=%.1f @ %@",
            spec.count, base.numerator, base.denominator,
            scaled.numerator, scaled.denominator,
            inGaps.map { String(format: "%.1f", $0) }.joined(separator: ","),
            meanIn, runXs.first ?? -1, location,
        ))
    }
}
