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
    /// The box is sized to the bounding x-range of selected items
    /// and the full vertical span of the involved staves (topmost
    /// staff top → bottommost staff bottom), with a small pad so it
    /// does not clip glyphs that overflow slightly.
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
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var staffAddressSet: Set<StaffAddress> = []
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
                        staffAddressSet.insert(n.noteID.staff)
                    }
                case let .rest(_, origin, _, rid, _)
                    where selection.selectedIDs.contains(.rest(rid)):
                    let ax = measure.origin.x + origin.x
                    minX = min(minX, ax)
                    maxX = max(maxX, ax)
                    staffAddressSet.insert(rid.staff)
                default:
                    break
                }
            }
        }
        guard !staffAddressSet.isEmpty else { return }

        // Each involved staff's own origin AND line geometry: the end staves' spans are what the box's two edges
        // are measured from, so the flat index has to survive the min/max rather than being discarded with it.
        let staves = staffAddressSet.compactMap { address -> (y: CGFloat, geometry: StaffLineGeometry)? in
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
        let rect = CGRect(
            x: minX - xPad,
            y: topEdge,
            width: max(0, maxX - minX) + xPad * 2,
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
}
