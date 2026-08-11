#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Which glyphs belong to which staff.
///
/// Split out of `PDFImporter+Layout` to keep that file under the 400-line
/// cap, the same way `systemBarlineUnion` was — these two functions are one
/// decision (a staff's vertical capture band, and the clamp that stops it
/// reaching a neighbour) and read better together than either did beside the
/// measure-splitting code.
extension PDFImporter {
    /// Vertical clamp bounds for a staff's glyph-capture band: the midpoint to
    /// the nearest staff below (`lower`) and above (`upper`). `±infinity` when
    /// there is no neighbour on that side. On a well-spaced ensemble the
    /// midpoint is farther than the ±3-line band, so clamping is a no-op; on a
    /// tight grand staff it stops the band from crossing into the sibling
    /// staff and double-capturing its noteheads.
    static func neighborBandClamp(
        top: CGFloat, bottom: CGFloat, bands: [(lo: CGFloat, hi: CGFloat)],
    ) -> (lower: CGFloat, upper: CGFloat) {
        var lower = -CGFloat.greatestFiniteMagnitude
        var upper = CGFloat.greatestFiniteMagnitude
        for b in bands {
            if b.hi < bottom - 0.5 {
                lower = max(lower, (bottom + b.hi) / 2)
            } else if b.lo > top + 0.5 {
                upper = min(upper, (top + b.lo) / 2)
            }
        }
        return (lower, upper)
    }

    static func filterGlyphs(
        classified: [ClassifiedGlyph], staff: Staff, lo: CGFloat, hi: CGFloat,
        clamp: (lower: CGFloat, upper: CGFloat) = (
            -CGFloat.greatestFiniteMagnitude, CGFloat.greatestFiniteMagnitude,
        ),
    ) -> [ClassifiedGlyph] {
        // Vertical capture band around the staff. A fixed ±30pt band
        // bled into the NEIGHBOURING staff on dense vocal scores where
        // staves sit only ~27pt apart center-to-center — every notehead of
        // the staff above/below was double-counted and decoded with the
        // wrong clef anchor (observed: parts 1-4 inflated to 450-566 notes
        // with impossible pitches up to MIDI 104). Scale the band to the
        // staff's own line spacing instead.
        //
        // FIVE spaces, not three. Three is inside the range real music
        // writes: a piano bass octave's lower note sits further out and, with
        // no neighbour to claim it either, was dropped outright — measured on
        // `疑事無功_piano`, 25 of one page's 271 noteheads were captured by NO
        // staff, all 3.0–4.5 spaces past the nearest band. The symptom looked
        // like a chord bug (octave dyads arriving as `[47]` instead of
        // `[35, 47]`) and was not one.
        //
        // Widening is safe for a reason that post-dates the narrowing:
        // `clamp` cuts the band at the MIDPOINT to an adjacent staff, so this
        // number can no longer reach a neighbour. It binds only where there
        // IS no neighbour — a system's outermost staff — and there the
        // nearest ink is the next system, further off than the gap inside one
        // (~8.9 spaces vs ~6.7 on that score). Corpus: 38 scores better, 1
        // worse, net +154 metric points — see the commit for the breakdown.
        let bottom = staff.yLines.first ?? 0
        let top = staff.yLines.last ?? 0
        let lineSpacing = staff.yLines.count >= 2
            ? (top - bottom) / CGFloat(staff.yLines.count - 1)
            : 5
        let band = max(lineSpacing * 5, 6)
        // Flag glyphs (E240–E24F) carry NO pitch — they only subdivide a
        // note's duration — so a wider capture band cannot corrupt pitch.
        // Drum flags in particular render ~10–13pt (≈0.75 staff-height)
        // beyond the outer lines, PAST the ±3-line pitch band, and were being
        // dropped: bare stems then read as quarters (地球儀 drums 16→q:19,
        // 君と kick 8→q). Admit flags out to ~6 line-spacings (still short of
        // the ~3-staff-height neighbour spacing); applyFlags' own staff-band
        // + x-gate contain any bleed this admits.
        let flagBand = max(lineSpacing * 6, 12)
        return classified.filter {
            guard $0.geometry.pageIndex == staff.pageIndex,
                  lo <= $0.geometry.origin.x,
                  $0.geometry.origin.x < hi
            else { return false }
            // Flags carry no pitch (they only subdivide a note's duration) and
            // render far from the staff, so their wide band must NOT be clamped
            // — clamping cut legitimate drum flags on tightly-spaced staves and
            // dropped their duration. Only the pitch-bearing band is clamped at
            // the midpoint to an adjacent staff, so a tight grand staff's
            // sibling noteheads aren't double-captured.
            if isFlag($0.semantic) {
                return (bottom - flagBand) <= $0.geometry.origin.y
                    && $0.geometry.origin.y <= (top + flagBand)
            }
            let low = max(bottom - band, clamp.lower)
            let high = min(top + band, clamp.upper)
            return low <= $0.geometry.origin.y && $0.geometry.origin.y <= high
        }
    }
}
