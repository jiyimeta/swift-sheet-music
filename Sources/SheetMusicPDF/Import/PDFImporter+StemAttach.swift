import CoreGraphics
import Foundation
import SheetMusicCore

// Stem attachment (notehead → stem): resolve which vertical a notehead
// belongs to, via a joint geometric cost (x-offset + y-distance + side +
// legality). Split out of PDFImporter+BeamGroups for file length; the
// beam-membership / grouping / level logic lives there.

extension PDFImporter {
    /// Penalty (pt) added when a notehead is on the wrong side of a stem.
    /// Sized to break a near-tie between an own-stem and a neighbour without
    /// overriding a clearly-closer stem.
    static let sideMismatchPenalty: CGFloat = 4.0

    /// Max distance (pt) a real attachment's stem may sit to the LEFT of the
    /// notehead's (left-edge) origin. A stem-down stem sits at the origin
    /// (delta ≈ 0), a stem-up stem ~4–8pt to its right (delta ≥ +4); measured
    /// across the 6-score corpus, no legit attachment (up or down, any font)
    /// falls below −0.5. A stem more than this far left of the origin is
    /// geometrically a NEIGHBOUR's stem the ±7pt x-window happened to reach.
    static let stemLegalityLeftSlop: CGFloat = 1.5

    /// Large additive cost for a geometrically-illegal (too-far-left) stem
    /// candidate — deprioritizes it below ANY legal stem while (unlike a hard
    /// veto) still letting a note whose ONLY candidate is such a stem fall
    /// back to it. Far larger than any real in-cell geometric cost (x-offset
    /// ≤ 7pt + y-distance ≤ ~2 staff-heights).
    static let stemIllegalPenalty: CGFloat = 1000

    /// The stem abutting a notehead at (`x`, `noteY`), with its index in
    /// `stems`. A stem sits ~4–6pt to the side of the notehead (its right
    /// edge for stem-up, left for stem-down), so candidates are verticals
    /// within ~7pt in x — under the ~10pt note-to-note spacing, so a
    /// neighbour can't be grabbed.
    ///
    /// Among the x-candidates, pick the stem minimizing a COMBINED distance
    /// (`stemCost`): x-offset + the notehead's distance from the stem's
    /// vertical span + a wrong-side penalty. A note's own stem abuts its
    /// notehead — close in x AND starting at the notehead's y, on the
    /// correct side — so the joint cost robustly resolves the correct stem
    /// when two stems share (or nearly share) an x: a second voice / octave
    /// stem at the same x is far in y; a y-coincidental neighbour from
    /// another voice is farther in x (and on the wrong side). Using x alone
    /// mis-routed a note to a y-coincidental stem in the wrong beam group
    /// (interior eighth read as a quarter); using y alone re-routed a note
    /// off its own (x-abutting) stem onto a y-overlapping neighbour
    /// (trailing note over-read as a sixteenth).
    static func nearestStem(
        toX x: CGFloat, noteY: CGFloat, stems: [PathSegment],
    ) -> (stem: PathSegment, index: Int)? {
        let candidates = stems.enumerated().filter {
            abs($0.element.rect.midX - x) <= 7
        }
        guard let best = candidates.min(by: { a, b in
            stemCost(a.element, x: x, noteY: noteY)
                < stemCost(b.element, x: x, noteY: noteY)
        }) else { return nil }
        return (best.element, best.offset)
    }

    /// Joint stem-attachment cost: x-offset from the notehead, the
    /// notehead's y-distance from the stem's vertical span, plus a SIDE
    /// penalty when the notehead sits on the geometrically wrong side of the
    /// stem. A stem extends AWAY from its notehead: a stem-up stem (span
    /// above the notehead) attaches at the notehead's RIGHT (so the notehead
    /// is to the stem's left, `x < stemX`); a stem-down stem attaches at the
    /// left. In a dense run, a note's own (correct-side) stem and a
    /// neighbour's (wrong-side) stem can be near-equal in raw x-distance; the
    /// side penalty tips the choice to the correct-side stem so a note isn't
    /// routed onto a neighbour's higher beam level (8 over-read as 16).
    static func stemCost(
        _ stem: PathSegment, x: CGFloat, noteY: CGFloat,
    ) -> CGFloat {
        let base = abs(stem.rect.midX - x) + stemYDistance(stem, noteY: noteY)
        let stemUp = stem.rect.midY > noteY
        // Correct side: stem-up ⇒ notehead left of stem (x < stemX);
        // stem-down ⇒ notehead right of stem (x > stemX).
        let onWrongSide = stemUp ? (x > stem.rect.midX) : (x < stem.rect.midX)
        // Geometric legality (Fix D): the weak midY-based side tip above
        // MISCLASSIFIES when a notehead's y sits near a NEIGHBOUR stem's
        // midpoint, letting a hi-hat / note attach to that neighbour's stem
        // (wrong voice + wrong beam level → drum voice-order + 8→q errors). A
        // real attachment never has its stem more than `stemLegalityLeftSlop`
        // left of the notehead's origin; a candidate that does is a neighbour's
        // stem, penalized decisively so any legal stem wins.
        let illegalLeft = stem.rect.midX < x - stemLegalityLeftSlop
        return base
            + (onWrongSide ? sideMismatchPenalty : 0)
            + (illegalLeft ? stemIllegalPenalty : 0)
    }

    /// Distance from `noteY` to a stem's vertical span (0 when inside).
    static func stemYDistance(
        _ stem: PathSegment, noteY: CGFloat,
    ) -> CGFloat {
        if noteY < stem.rect.minY { return stem.rect.minY - noteY }
        if noteY > stem.rect.maxY { return noteY - stem.rect.maxY }
        return 0
    }
}
