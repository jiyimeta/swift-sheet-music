import CoreGraphics
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    /// Draws a rectangular outline around every staff × time region
    /// that contains a selected item (note or rest) on this system.
    /// Called when `selection.drawRangeBox` is true.
    ///
    /// The box is sized to the covered x-range of selected items
    /// and the full vertical span of the involved staves (topmost
    /// staff top → bottommost staff bottom), with a small pad so it
    /// does not clip glyphs that overflow slightly.
    ///
    /// **Horizontally the box covers the TIME the selection occupies,
    /// not the ink it happens to be drawn with.** Both edges are read
    /// off `LayoutMeasure.tickColumns` — the cross-staff tick → x map
    /// placement already produced — rather than from notehead origins
    /// alone:
    ///
    /// - The right edge runs to just before the next onset column, or
    ///   to the measure's trailing barline when the last selected
    ///   element ends the bar. Stopping at the last notehead's own x
    ///   drew a box that ended in the middle of the note it was
    ///   supposed to contain, and said nothing about that note's
    ///   duration.
    /// - A whole-measure rest (`NoteDuration.measure`) contributes the
    ///   bar's FIRST beat as its left edge, not its own origin:
    ///   placement centers that glyph in the measure
    ///   (`LayoutEngine+Placement.swift`), so a box measured from the
    ///   ink started halfway through a bar the selection covers whole.
    ///   Its right edge is the barline for the same reason.
    ///
    /// Both edges are floored by what the old ink-only measurement
    /// produced (`maxX + xPad`), so the box can only ever grow: a
    /// notehead nudged right of its own column — a second, an
    /// accidental's chord shift — can never pull an edge in past the
    /// glyph it is drawn around.
    ///
    /// Both vertical edges come from the end staves' own
    /// `StaffLineGeometry.barLineSpanY(sp:)`, the way the system's
    /// left-edge barline does. `StaffMetrics.staffHeight` is the
    /// five-line reference height every staff reports, so measuring the
    /// bottom with it overshot a three-line staff by 2 sp and left a
    /// one-line staff's box hanging entirely below its single line.
    static func drawRangeBoxes(
        system: LayoutSystem,
        selection: SelectionRenderState,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let span = horizontalSpan(system: system, selection: selection)
        guard !span.staves.isEmpty else { return }

        // Each involved staff's own origin AND line geometry: the end staves' spans are what the box's two edges
        // are measured from, so the flat index has to survive the min/max rather than being discarded with it.
        let staves = span.staves.compactMap { address -> (y: CGFloat, geometry: StaffLineGeometry)? in
            guard let idx = system.flatIndex(for: address) else { return nil }
            return (system.staffOrigins[idx].y, system.geometry(atFlatIndex: idx))
        }
        guard let top = staves.min(by: { $0.y < $1.y }),
              let bottom = staves.max(by: { $0.y < $1.y })
        else { return }

        let xPad = metrics.sp * 1.4
        let yPad = metrics.sp
        let topEdge = top.y + top.geometry.barLineSpanY(sp: metrics.sp).top - yPad
        let bottomEdge = bottom.y + bottom.geometry.barLineSpanY(sp: metrics.sp).bottom + yPad
        let leftEdge = span.minX - xPad
        let rightEdge = max(span.maxEndX - xPad, span.maxX + xPad)
        let rect = CGRect(
            x: leftEdge,
            y: topEdge,
            width: max(0, rightEdge - leftEdge),
            height: bottomEdge - topEdge,
        )

        let path = CGPath(rect: rect, transform: nil)
        #if os(macOS)
            // LayoutEngine emits Y-down; macOS CALayer is Y-up. Flip
            // around `height` to match the other layers built in the
            // same tree (see `ScoreLayerBuilder.flipForPlatform`).
            var flip = CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height,
            )
            let drawPath = path.copy(using: &flip) ?? path
        #else
            let drawPath = path
        #endif
        let layer = CAShapeLayer()
        layer.path = drawPath
        layer.strokeColor = selection.rangeBoxColor
        layer.fillColor = nil
        layer.lineWidth = metrics.staffLineThickness * 2
        layer.masksToBounds = false
        parent.addSublayer(layer)
    }

    /// What the selected elements of this system span horizontally, and
    /// which staves they sit on.
    ///
    /// `minX` / `maxX` are the selected INK's own bounds — the pair the
    /// box was measured from before this pass, and now only the floor
    /// under `maxEndX`, which is where the selection's last element
    /// stops being sounded.
    private static func horizontalSpan(
        system: LayoutSystem,
        selection: SelectionRenderState,
    ) -> (minX: CGFloat, maxX: CGFloat, maxEndX: CGFloat, staves: Set<StaffAddress>) {
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxEndX = -CGFloat.infinity
        var staves: Set<StaffAddress> = []
        for measure in system.measures {
            for el in measure.elements {
                switch el {
                case let .chord(notes, _, _, _, _, _, _, _, _, _, _):
                    for n in notes
                        where selection.selectedIDs.contains(.note(n.noteID))
                    {
                        let ax = measure.origin.x + n.origin.x
                        minX = min(minX, ax)
                        maxX = max(maxX, ax)
                        maxEndX = max(
                            maxEndX,
                            nextOnsetX(after: n.origin.x, in: measure),
                        )
                        staves.insert(n.noteID.staff)
                    }
                case let .rest(duration, origin, _, rid, _)
                    where selection.selectedIDs.contains(.rest(rid)):
                    let ax = measure.origin.x + origin.x
                    let isMeasureRest = duration == .measure
                    minX = min(
                        minX,
                        isMeasureRest ? firstBeatX(of: measure) ?? ax : ax,
                    )
                    maxX = max(maxX, ax)
                    maxEndX = max(
                        maxEndX,
                        isMeasureRest
                            ? trailingBarLineX(of: measure)
                            : nextOnsetX(after: origin.x, in: measure),
                    )
                    staves.insert(rid.staff)
                default:
                    break
                }
            }
        }
        return (minX, maxX, maxEndX, staves)
    }

    /// Where the measure's first beat sits, in system coordinates —
    /// `tickColumns`' tick-0 entry, which placement puts at
    /// `contentStartX + sp` whatever the bar happens to contain.
    ///
    /// `nil` only for a measure with no timed content at all
    /// (`tickColumns` is empty for those, and for a multi-measure
    /// rest), which the caller answers by falling back to the ink.
    private static func firstBeatX(of measure: LayoutMeasure) -> CGFloat? {
        guard let first = measure.tickColumns[0]
            ?? measure.tickColumns.values.min()
        else { return nil }
        return measure.origin.x + first
    }

    /// The next onset column strictly right of `localX` (a
    /// measure-local x), in system coordinates — or the measure's
    /// trailing barline when nothing onsets after it.
    ///
    /// `tickColumns` is cross-staff aggregated, so this stops at the
    /// next thing that starts anywhere in the system, which is what
    /// makes it a segment boundary rather than one voice's next note.
    private static func nextOnsetX(
        after localX: CGFloat, in measure: LayoutMeasure,
    ) -> CGFloat {
        guard let next = measure.tickColumns.values
            .filter({ $0 > localX })
            .min()
        else { return trailingBarLineX(of: measure) }
        return measure.origin.x + next
    }

    /// The measure's closing barline, in system coordinates. Read off
    /// the rightmost `.barLine` element rather than computed as
    /// `origin.x + width` so the box lands on the drawn line — and so
    /// a bar that opens with a start-repeat barline is not measured
    /// from that one. Falls back to the measure's right edge when no
    /// barline was emitted at all.
    private static func trailingBarLineX(of measure: LayoutMeasure) -> CGFloat {
        var localX: CGFloat?
        for case let .barLine(_, origin, _) in measure.elements {
            localX = max(localX ?? origin.x, origin.x)
        }
        return measure.origin.x + (localX ?? measure.width)
    }
}
