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
            guard let span = bracketSpan(
                digit: glyph, paths: paths, spatium: spatium, pageIndex: pageIndex,
            ) else { continue }
            marks.append(TupletMark(
                xRange: span,
                normal: ratio.normal, actual: ratio.actual,
                digitCenterX: glyph.bbox.midX,
                digitOrigin: glyph.origin,
                anchor: .bracket,
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
        guard let left = arms
            .filter({ $0.rect.maxX <= digit.bbox.minX + 0.5 })
            .max(by: { $0.rect.maxX < $1.rect.maxX }),
            let right = arms
                .filter({ $0.rect.minX >= digit.bbox.maxX - 0.5 })
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
