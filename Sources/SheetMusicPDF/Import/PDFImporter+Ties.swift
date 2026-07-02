import CoreGraphics
import Foundation
import SheetMusicCore

// Tie detection. MuseScore renders a tie as a short, flat, filled
// Bezier lens connecting two SAME-pitch noteheads at adjacent x (within
// a measure or across a barline). The content-stream walker captures
// these as `CurveArc`s. A tie is distinguished from a slur by being
// short and joining two noteheads on the SAME staff line (same y, hence
// same pitch); slurs span different pitches and / or much wider gaps.
//
// We pair tie arcs to noteheads by geometry alone (no MIDI needed: two
// tied noteheads sit on the same line, so equal y ⇒ equal pitch). The
// result is a pair of notehead-identity sets — one carrying a forward
// tie (the earlier note), one a back tie (the later note) — which the
// assembler stamps onto the matching `Note`s as it builds measures.

extension PDFImporter {
    /// Stable identity of a notehead by its page + rounded origin. Two
    /// passes (tie detection here, note construction in assembly) derive
    /// the same key from the same `RawGlyph`, so they line up.
    struct NoteheadID: Hashable {
        var page: Int
        var x: Int
        var y: Int

        init(_ raw: RawGlyph) {
            page = raw.pageIndex
            x = Int(raw.origin.x.rounded())
            y = Int(raw.origin.y.rounded())
        }
    }

    struct TieMarks {
        var forward: Set<NoteheadID> = []
        var back: Set<NoteheadID> = []
    }

    /// Build the forward / back tie sets from curve arcs and noteheads.
    static func detectTies(
        curves: [CurveArc],
        noteheads: [ClassifiedGlyph],
    ) -> TieMarks {
        var marks = TieMarks()
        // Index noteheads by page for a quick local search.
        var byPage: [Int: [ClassifiedGlyph]] = [:]
        for g in noteheads where isNotehead(g.semantic) {
            byPage[g.raw.pageIndex, default: []].append(g)
        }
        // Endpoint-pairing tolerances. A tie's gap to its noteheads is a
        // constant page-point offset PLUS a staff-space-proportional drop,
        // so neither a pure absolute nor a pure spatium tolerance fits all
        // staff sizes: a fixed `6pt` was too tight on the large-staff score
        // (群青, ~5pt/sp ⇒ ties just past the cutoff, recall 35%), while a
        // pure spatium tolerance is too tight on the small-staff scores
        // (地球儀, ~3.3pt/sp). `max(floor, sp × spatia)` keeps the proven
        // generous floor for the observed range and scales up for any
        // larger staff. See `pageStaffSpace`.
        let sp = pageStaffSpace(noteheads)
        let yTol = max(Self.tieYToleranceFloor, sp * Self.tieYToleranceSpatia)
        let xTol = max(Self.tieXToleranceFloor, sp * Self.tieXToleranceSpatia)
        for arc in curves {
            guard isTieShaped(arc) else { continue }
            guard let page = byPage[arc.pageIndex] else { continue }
            guard let (left, right) = pairEndpoints(
                arc: arc, noteheads: page, yTol: yTol, xTol: xTol,
            ) else { continue }
            marks.forward.insert(NoteheadID(left.raw))
            marks.back.insert(NoteheadID(right.raw))
        }
        return marks
    }

    /// Tie endpoint-pairing tolerances. The floor (page points) covers the
    /// constant rendering offset that dominates on small staves; the
    /// spatia term scales the bound up on larger staves. `max(floor, sp ×
    /// spatia)` so the larger of the two wins. The same-line guard in
    /// `pairEndpoints` still rejects cross-pitch matches, keeping precision
    /// at 100% across the corpus.
    private static let tieYToleranceFloor: CGFloat = 9
    private static let tieYToleranceSpatia: CGFloat = 1.8
    private static let tieXToleranceFloor: CGFloat = 10
    private static let tieXToleranceSpatia: CGFloat = 2.0

    /// RIGHT-endpoint gap as a fraction of arc width. Measured full ties
    /// (same line, dy = 0) place the right notehead 10.1–15.8pt past the
    /// arc's right point — the tie's right-side inset scales with arc
    /// width (gap / width ≈ 0.21–0.23), so a fixed `xTol` loses the
    /// anchor on wide arcs. `pairEndpoints` widens the RIGHT search to
    /// `max(xTol, width × ratio)`; left insets are tight, so the LEFT
    /// search keeps the plain `xTol`.
    private static let tieRightGapWidthRatio: CGFloat = 0.24

    /// Width cap for the normal tie band. Real ties in the corpus stay
    /// flat (bbox height ≤ ~7.3pt) even at widths up to ~163pt, so the
    /// old 70pt cap silently dropped every wide tie. 180pt keeps
    /// headroom above the widest observed tie; precision is still
    /// protected because a wide arc only becomes a tie if BOTH endpoints
    /// anchor to two distinct SAME-line noteheads in `pairEndpoints`.
    private static let tieWidthMax: CGFloat = 180

    /// Narrow flat-arc band. Dense 16th-note ties render as flat curves
    /// only 3.3–5.9pt wide (bbox height 1.6–2.6pt) — under the normal
    /// ≥6pt floor. Admit sub-6pt arcs only when clearly FLAT: round
    /// augmentation / staccato dots have height ≈ width and fail the
    /// `height ≤ 0.7 × width` discriminator. Internal (not private)
    /// because the capture gate in `emitCurveArc`
    /// (`PDFImporter+ContentStream.swift`) applies the same band, so
    /// both stages admit identical narrow arcs.
    static let tieNarrowWidthMin: CGFloat = 3
    static let tieNarrowFlatnessRatio: CGFloat = 0.7

    /// Median page-space staff space (one spatium in page points) from the
    /// full noteheads' `renderedSize` (SMuFL design metric: staff space =
    /// glyph size / 4). Falls back to a default when no rendered size is
    /// recorded so the tolerances stay finite.
    static func pageStaffSpace(_ noteheads: [ClassifiedGlyph]) -> CGFloat {
        let sizes = noteheads
            .filter { isNotehead($0.semantic) }
            .map(\.raw.renderedSize)
            .filter { $0 > 0 }
            .sorted()
        guard !sizes.isEmpty else { return 4 }
        return sizes[sizes.count / 2] / 4
    }

    /// A tie arc is nearly horizontal and flat. The height cap rejects
    /// steep slurs and phrase marks; the width cap (`tieWidthMax`) only
    /// needs to reject extreme spans because the two-anchor same-line
    /// pairing in `pairEndpoints` is what actually separates wide ties
    /// from slurs. A second, narrow band admits dense 16th-note ties
    /// (see `tieNarrowWidthMin`).
    private static func isTieShaped(_ arc: CurveArc) -> Bool {
        let w = arc.bbox.width
        let h = arc.bbox.height
        // Normal band: flat, from the ~6pt dot floor up to `tieWidthMax`.
        if w >= 6, w <= Self.tieWidthMax, h <= 8 { return true }
        // Narrow band: sub-6pt arcs survive capture only when clearly
        // flat (`emitCurveArc`); mirror the same discriminator here so
        // dense 16th-note ties reach endpoint pairing.
        return w >= Self.tieNarrowWidthMin && w < 6
            && h <= Self.tieNarrowFlatnessRatio * w
    }

    /// Find the same-line noteheads nearest the arc's left and right
    /// endpoints. The two must share a y (same staff position ⇒ same
    /// pitch) and bracket the arc horizontally. Returns nil when no such
    /// pair exists (e.g. the arc is a slur between different pitches).
    private static func pairEndpoints(
        arc: CurveArc,
        noteheads: [ClassifiedGlyph],
        yTol: CGFloat,
        xTol: CGFloat,
    ) -> (left: ClassifiedGlyph, right: ClassifiedGlyph)? {
        // A tie sits just below / above its two noteheads, slightly inset.
        // Search noteheads whose x is near the arc's x-extent and whose y
        // is within ~1.8 staff spaces of the arc's vertical midpoint.
        let arcY = arc.bbox.midY
        let left = nearestNotehead(
            toX: arc.leftPoint.x, nearY: arcY,
            noteheads: noteheads, xTol: xTol, yTol: yTol,
        )
        // The RIGHT notehead sits 10.1–15.8pt past the arc's right point
        // on measured full ties — the gap grows with arc width (≈ 0.21–
        // 0.23 × width) and outruns the fixed `xTol` on wide arcs, so the
        // right search widens proportionally (`tieRightGapWidthRatio`).
        let rightXTol = max(xTol, Self.tieRightGapWidthRatio * arc.bbox.width)
        let right = nearestNotehead(
            toX: arc.rightPoint.x, nearY: arcY,
            noteheads: noteheads, xTol: rightXTol, yTol: yTol,
        )
        guard let left, let right else { return nil }
        // Must be two DISTINCT noteheads on the SAME line, left before
        // right. Same line ⇒ |dy| ≤ ~1pt (a tie joins identical pitches).
        guard left.raw.origin.x < right.raw.origin.x,
              abs(left.raw.origin.y - right.raw.origin.y) <= 2
        else { return nil }
        return (left, right)
    }

    private static func nearestNotehead(
        toX x: CGFloat,
        nearY y: CGFloat,
        noteheads: [ClassifiedGlyph],
        xTol: CGFloat,
        yTol: CGFloat,
    ) -> ClassifiedGlyph? {
        var best: (g: ClassifiedGlyph, d: CGFloat)?
        for g in noteheads {
            let dx = abs(g.raw.origin.x - x)
            guard dx <= xTol else { continue }
            let dy = abs(g.raw.origin.y - y)
            guard dy <= yTol else { continue }
            let d = dx + dy
            if let cur = best {
                if d < cur.d { best = (g, d) }
            } else {
                best = (g, d)
            }
        }
        return best?.g
    }
}
