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
    static let tupletMarkBandSpatia: CGFloat = 3

    /// Widest a bracket arm may be, in spatia. A staff line spans the whole
    /// measure cell; an arm is a short stub.
    static let tupletBracketArmMaxSpatia: CGFloat = 12

    /// How far apart (in spatia) the two arms' y may be and still count as
    /// one bracket.
    static let tupletBracketArmYTolSpatia: CGFloat = 0.3

    /// How far from the digit's y (in spatia) a bracket's arms may sit.
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
    /// Built from `origin.x` (the pen position = the glyph's left edge) and
    /// `renderedSize`, NOT `fontSize`: `fontSize` is the raw text-space `Tf`
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
    static func tupletRatio(forDigit text: String) -> (normal: Int, actual: Int)? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "3": (2, 3)
        case "6": (4, 6)
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
    private static func beamWindow(
        digit: TextGlyph, paths: [PathSegment],
        spatium: CGFloat, pageIndex: Int,
    ) -> ClosedRange<CGFloat>? {
        let digitX = digitCenterX(digit)
        let digitY = digit.origin.y
        let candidates = paths.filter { p in
            guard p.kind == .beam, p.pageIndex == pageIndex else { return false }
            let span = p.quad?.xRange ?? (p.rect.minX ... p.rect.maxX)
            guard span.contains(digitX) else { return false }
            return abs(p.rect.midY - digitY)
                <= tupletBeamDigitYTolSpatia * spatium
        }
        return candidates
            .map { $0.quad?.xRange ?? ($0.rect.minX ... $0.rect.maxX) }
            .min { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
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
