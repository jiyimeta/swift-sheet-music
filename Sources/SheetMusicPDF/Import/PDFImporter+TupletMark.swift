#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// TUPLET MARK DETECTION. MuseScore engraves a tuplet as a NUMBER, plus a
// BRACKET whenever the members are not all beamed together (a triplet
// quarter + eighth cannot be beamed, so it always gets one). Both are in
// the PDF: the number arrives as a `TextGlyph`, the bracket as two short
// `.horizontal` arms with `.vertical` hooks at their outer ends.
//
// The digit alone is not enough to act on — a measure number and a page
// number are bare digits too. What separates a tuplet number from those is
// STRUCTURE: only a tuplet number has a bracket or a beam group directly
// under (or over) it. Requiring that anchor is this pass's primary
// false-positive defence, and it also decides WHICH STAFF owns the mark: a
// number drawn above a lower staff's beam sits inside the upper staff's
// lyric band, so proximity alone would attach it to the wrong staff.

extension PDFImporter {
    /// One detected tuplet mark: the x-span its members occupy, the ratio
    /// its digit names, and how the span was anchored.
    struct TupletMark: Equatable {
        enum Anchor { case bracket, beam }
        /// For `.bracket` this is the authoritative member span (the outer
        /// edges of the two arms). For `.beam` it is a SEARCH WINDOW —
        /// `applyTupletMarks` picks the member run inside it, because a
        /// primary beam is routinely longer than the tuplet it contains.
        var xRange: ClosedRange<CGFloat>
        var normal: Int
        var actual: Int
        var digitCenterX: CGFloat
        var digitOrigin: CGPoint
        var anchor: Anchor
    }

    /// How far outside the staff (in spatia) a tuplet number may sit.
    ///
    /// Measured: `君とParadiso` p0 m0's bracket sits at y 518.7, 7.0pt
    /// (2.09sp at that page's spatium 3.35) above the staff's top line
    /// (511.7). `3` gives ~0.9sp of headroom over that one measurement —
    /// a deliberately loose bound (design doc: "~3sp"), not a tight fit to
    /// it; there is no corpus survey behind the exact value 3.
    static let tupletMarkBandSpatia: CGFloat = 3

    /// Widest a bracket arm may be, in spatia. A staff line spans the whole
    /// measure cell; an arm is a short stub.
    ///
    /// Measured: `君とParadiso` p0 m0's two arms are 10.9pt each (178.2–189.1,
    /// 195.5–206.4), ≈3.25sp at spatium 3.35. `12` is a chosen ceiling with
    /// roughly 4x headroom over that one measurement, not a derived or
    /// corpus-fit bound — its job is only to keep a full staff line
    /// (which spans the whole measure cell) from being mistaken for an arm.
    static let tupletBracketArmMaxSpatia: CGFloat = 12

    /// How far apart (in spatia) the two arms' y may be and still count as
    /// one bracket.
    ///
    /// Measured: `君とParadiso` p0 m0's two arms sit at the SAME y (both
    /// 518.7 — zero measured difference). `0.3` is chosen headroom for
    /// engraving / PDF-writer noise on a value that was observed to be
    /// exactly 0 in the one example measured, not a corpus-derived
    /// tolerance.
    static let tupletBracketArmYTolSpatia: CGFloat = 0.3

    /// How far from the digit's y (in spatia) a bracket's arms may sit.
    ///
    /// Chosen as a loose bound, not measured: the design doc records the
    /// digit's own bbox height (6.0pt, ≈1.8sp at `君とParadiso`'s spatium
    /// 3.35) but no measured digit-y-to-arm-y offset for any corpus
    /// example. `1.5` was picked to comfortably clear a digit vertically
    /// centred on the arm within its own height, with no tighter
    /// measurement behind the exact value.
    static let tupletBracketDigitYTolSpatia: CGFloat = 1.5

    /// Width of one engraved digit as a fraction of the page-space em.
    ///
    /// MEASURED, not guessed. Ground truth from `pdftotext -bbox`, against
    /// the em this importer records as `TextGlyph.renderedSize`:
    ///
    /// | glyph                        | em     | ink width | ratio  |
    /// |------------------------------|--------|-----------|--------|
    /// | 君とParadiso tuplet "3" (F9)  | 6.000  | 3.306     | 0.5510 |
    /// | Now_is_the_time tuplet "3"(F9)| 5.200  | 2.865     | 0.5510 |
    /// | 君とParadiso page no. "3"(F13)| 11.000 | 6.259     | 0.5690 |
    ///
    /// The two tuplet digits agree to four decimals, so 0.551 is the digit
    /// advance of the numeral face MuseScore engraves tuplets in. The page
    /// number is a different face and 3% wider — well inside the slack both
    /// anchor tests carry, so one constant covers both.
    static let tupletDigitWidthPerEm: CGFloat = 0.551

    /// The digit's horizontal extent in PAGE space.
    ///
    /// WHY THIS EXISTS: `TextGlyph.bbox` is `.zero` at its only construction
    /// site (`PDFImporter+ContentStream+TextShow.swift`, `emitTextGlyph`) and
    /// is never assigned, so reading it yields an empty rect at the page
    /// origin — which silently pinned every digit's x to 0 and stopped this
    /// detector from ever matching a beam or a bracket. The other readers
    /// still living with that defect are `PDFImporter+Structure.swift` lines
    /// 118, 178, 274 and 286 (rehearsal-mark / volta detection); populating
    /// `bbox` properly is deferred to its own branch because it changes those
    /// detectors' output and needs its own corpus gate. This helper is the
    /// workaround for a known defect, not a stylistic preference — when
    /// `bbox` is fixed, this should go away.
    ///
    /// Built from `origin.x` and `renderedSize`.
    ///
    /// `origin.x` is the pen position at the START of the glyph's run, i.e.
    /// the left edge of its ink. That is only true because the Type0 / CMap
    /// show loop captures the origin before advancing the text matrix; it
    /// previously recorded the position AFTER the run, putting every digit
    /// one approximate advance (3.0pt on 君とParadiso) to the right and
    /// defeating both anchor tests. See `PendingTextRun`.
    ///
    /// The size comes from `renderedSize`, NOT `fontSize`: `fontSize` is the raw text-space `Tf`
    /// operand with the CTM unapplied, and the CTM is not constant even
    /// within this corpus (0.2 for five curated scores, 0.06 for ロビンソン),
    /// so a `fontSize`-derived width would be 3.3x too wide on that score.
    static func digitExtent(_ glyph: TextGlyph) -> ClosedRange<CGFloat> {
        let width = glyph.renderedSize * tupletDigitWidthPerEm
        return glyph.origin.x ... (glyph.origin.x + max(width, 0))
    }

    /// Horizontal centre of `glyph`'s ink, in page space. See `digitExtent`.
    static func digitCenterX(_ glyph: TextGlyph) -> CGFloat {
        let extent = digitExtent(glyph)
        return (extent.lowerBound + extent.upperBound) / 2
    }

    /// The ratio a tuplet digit names, or nil for digits we do not handle.
    ///
    /// `normal` is the largest power of two at or below the digit — the
    /// convention MuseScore writes when only a number is engraved, and the
    /// one the two original entries (3 -> 2, 6 -> 4) already followed.
    ///
    /// 5, 7 and 9 were missing, and a digit that returns nil is not a
    /// partial read — the whole mark is dropped and every note under it is
    /// composed at its plain value. Measured on the eval corpus before this
    /// was added: 165 quintuplet sixteenths (`1/20`) short against 190
    /// sixteenths over-produced, and 252 septuplet sixteenths (`1/28`)
    /// short against 227 thirty-seconds over — 428 notes across 18 renders,
    /// while triplets were short by 11. The arithmetic confirms the ratios
    /// rather than assuming them: 5 in the time of 4 sixteenths is
    /// (4/5)x(1/16) = 1/20, and 7 in the time of 4 sixteenths is
    /// (4/7)x(1/16) = 1/28, which is exactly what the authored scores hold.
    ///
    /// 2 and 4 are deliberately absent. A duplet or quadruplet borrows from
    /// COMPOUND time and inverts the ratio (2 in the time of 3), so it
    /// cannot be read from the digit alone — it needs the prevailing time
    /// signature, which this function does not see. Guessing (2, 3) for a
    /// "2" would also put the importer one mis-detected digit away from
    /// re-timing a bar around a time signature's numeral.
    static func tupletRatio(forDigit text: String) -> (normal: Int, actual: Int)? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "3": (2, 3)
        case "5": (4, 5)
        case "6": (4, 6)
        case "7": (4, 7)
        case "9": (8, 9)
        default: nil
        }
    }

    /// Every tuplet mark whose digit falls in this measure cell and which
    /// has a bracket or beam anchoring it. Digits without an anchor are
    /// omitted, leaving them available to `attachLyrics`.
    static func detectTupletMarks(
        texts: [TextGlyph],
        paths: [PathSegment],
        staffYLines: [CGFloat],
        xRange: ClosedRange<CGFloat>,
        pageIndex: Int,
    ) -> [TupletMark] {
        guard let bottomY = staffYLines.min(), let topY = staffYLines.max(),
              topY > bottomY
        else { return [] }
        let spatium = staffSpatium(staffYLines)
        let band = tupletMarkBandSpatia * spatium
        var marks: [TupletMark] = []
        for glyph in texts where glyph.pageIndex == pageIndex {
            guard let ratio = tupletRatio(forDigit: glyph.text) else { continue }
            let y = glyph.origin.y
            // Outside the five lines, but not far outside.
            guard (y > topY && y <= topY + band)
                || (y < bottomY && y >= bottomY - band) else { continue }
            guard xRange.contains(glyph.origin.x) else { continue }
            let bracket = bracketSpan(
                digit: glyph, paths: paths, spatium: spatium, pageIndex: pageIndex,
            )
            let anchor: TupletMark.Anchor = bracket == nil ? .beam : .bracket
            guard let span = bracket ?? beamWindow(
                digit: glyph, paths: paths, spatium: spatium, pageIndex: pageIndex,
            ) else { continue }
            marks.append(TupletMark(
                xRange: span,
                normal: ratio.normal, actual: ratio.actual,
                digitCenterX: digitCenterX(glyph),
                digitOrigin: glyph.origin,
                anchor: anchor,
            ))
        }
        return marks.sorted { $0.xRange.lowerBound < $1.xRange.lowerBound }
    }

    /// The outer x-span of the bracket straddling `digit`, or nil.
    ///
    /// A bracket is two short horizontal arms at a common y, one ending
    /// left of the digit and one starting right of it, each with a short
    /// vertical hook at its OUTER end. The digit sits in the gap between
    /// them — that gap is why MuseScore splits the arm in two, and it is
    /// what makes the pattern unmistakable.
    private static func bracketSpan(
        digit: TextGlyph, paths: [PathSegment],
        spatium: CGFloat, pageIndex: Int,
    ) -> ClosedRange<CGFloat>? {
        let digitY = digit.origin.y
        let arms = paths.filter {
            $0.kind == .horizontal
                && $0.pageIndex == pageIndex
                && abs($0.rect.midY - digitY)
                <= tupletBracketDigitYTolSpatia * spatium
                && $0.rect.width <= tupletBracketArmMaxSpatia * spatium
                && $0.rect.width >= 0.5 * spatium
        }
        let extent = digitExtent(digit)
        guard let left = arms
            .filter({ $0.rect.maxX <= extent.lowerBound + 0.5 })
            .max(by: { $0.rect.maxX < $1.rect.maxX }),
            let right = arms
                .filter({ $0.rect.minX >= extent.upperBound - 0.5 })
                .min(by: { $0.rect.minX < $1.rect.minX }),
                abs(left.rect.midY - right.rect.midY)
                <= tupletBracketArmYTolSpatia * spatium
        else { return nil }
        let lo = left.rect.minX
        let hi = right.rect.maxX
        guard hi > lo, hasHook(
            paths,
            atX: lo,
            armY: left.rect.midY,
            spatium: spatium,
            pageIndex: pageIndex,
        ),
            hasHook(
                paths,
                atX: hi,
                armY: right.rect.midY,
                spatium: spatium,
                pageIndex: pageIndex,
            )
        else { return nil }
        return lo ... hi
    }

    /// How far (in spatia) a beam's y may be from the digit's y and still
    /// count as the beam that number labels.
    ///
    /// Chosen as a loose bound, not measured: the design doc's one worked
    /// beam example (`Now_is_the_time` p4 m91) documents the beam's x-span
    /// and the digit's x-centre in detail but not a measured digit-y-to-
    /// beam-y offset. `3` mirrors `tupletMarkBandSpatia`'s magnitude
    /// (same "outside the staff, but not far outside" shape of tolerance)
    /// rather than being fit to a specific measurement.
    static let tupletBeamDigitYTolSpatia: CGFloat = 3

    /// The NARROWEST beam whose x-range contains the digit's x, as a search
    /// window for the member run.
    ///
    /// Narrowest, not nearest: a primary beam routinely spans more notes
    /// than the tuplet inside it. Measured on Now_is_the_time p4 m91, the
    /// primary runs 457.3..480.1 over five stems while the secondary runs
    /// 457.3..467.9 over exactly the triplet's three; taking the primary
    /// would let `applyTupletMarks` choose a three-note run straddling the
    /// tuplet's edge. The window is only a bound — the run inside it is
    /// chosen by the clean-sum gate plus the digit's own centre.
    ///
    /// The range is read through `beamMemberSpan`, i.e. with the same
    /// `beamEndpointPad` every other consumer of a beam's x-range applies —
    /// see that function for why reading it raw was wrong.
    private static func beamWindow(
        digit: TextGlyph, paths: [PathSegment],
        spatium: CGFloat, pageIndex: Int,
    ) -> ClosedRange<CGFloat>? {
        let digitX = digitCenterX(digit)
        let digitY = digit.origin.y
        let candidates = paths.filter { p in
            guard p.kind == .beam, p.pageIndex == pageIndex else { return false }
            guard beamMemberSpan(p).contains(digitX) else { return false }
            return abs(p.rect.midY - digitY)
                <= tupletBeamDigitYTolSpatia * spatium
        }
        return candidates
            .map(beamMemberSpan)
            .min { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
    }

    /// A beam's x-range as a MEMBERSHIP window — padded by
    /// `beamEndpointPad`, exactly as `fullBeamSpans` pads it.
    ///
    /// `beamEndpointPad` exists because a beam's drawn endpoints coincide
    /// with its outermost stems only in a VECTOR PDF. `beamWindow` used to
    /// be the one place that read the same range RAW, and it hands its
    /// result straight to `applyTupletMarks` as the member-run window —
    /// where the upper bound gets no slack at all, precisely on the
    /// assumption that "the rightmost true member's stem sits at or inside
    /// the mark's right edge already". A raster beam breaks that
    /// assumption: a fitted slab cannot include the columns where its own
    /// outermost stems stand (beam + stem ink merges there and lands on no
    /// ladder rung), so its range stops INSIDE them even after
    /// `RasterPage.extendedSpan` walks it back out.
    ///
    /// The consequence was not a truncated run but usually no tuplet at
    /// all: drop one end note of a triplet and the remaining two sum to
    /// 1/8 × 2/3 = 1/12, which `cleanScale` refuses, so the mark is
    /// discarded and the whole bar is left to rhythm reconciliation.
    ///
    /// MEASURED, v2-eval, 32 renders (2026-08-27). The beam oracle's whole
    /// remaining advantage was this one range:
    ///
    ///     mode                      durP50  durMean
    ///     detected, raw range         85.5     74.5
    ///     detected, padded (this)     88.0     76.4
    ///     truthBeams (oracle)         88.0     76.6
    ///
    /// with 10 renders improved and none regressed. The three components
    /// of the oracle's beams were priced separately
    /// (`OMRHybridFrontEnd.Mode`): its x-ranges are worth +2.5 durP50, its
    /// 574 fewer false positives −0.1 durMean, and its 31 extra beams
    /// exactly zero. The ledger agrees — over the 11 renders the oracle
    /// improved, its beams differ by 5 lost and 4 gained LEVELS in total,
    /// against 370 stem inclusions lost to the unpadded range
    /// (`[beamdiag] windowDrop`), and only 14 of 5042 matched beam ends
    /// stop more than the pad short.
    static func beamMemberSpan(_ beam: PathSegment) -> ClosedRange<CGFloat> {
        let raw = beam.quad?.xRange ?? (beam.rect.minX ... beam.rect.maxX)
        return (raw.lowerBound - beamEndpointPad)
            ... (raw.upperBound + beamEndpointPad)
    }

    /// Whether a short vertical hook stands at `x` next to the arm's y.
    private static func hasHook(
        _ paths: [PathSegment], atX x: CGFloat, armY: CGFloat,
        spatium: CGFloat, pageIndex: Int,
    ) -> Bool {
        paths.contains {
            $0.kind == .vertical
                && $0.pageIndex == pageIndex
                && abs($0.rect.midX - x) <= 0.3 * spatium
                && $0.rect.height <= 2 * spatium
                && $0.rect.minY <= armY + 0.5 * spatium
                && $0.rect.maxY >= armY - 0.5 * spatium
        }
    }
}
