import CoreGraphics
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    /// Draws a rectangular outline around every staff × time region
    /// that contains a selected item (note or rest) on this system.
    /// Called when `selection.drawRangeBox` is true.
    ///
    /// The box is sized to the bounding x-range of selected items
    /// and the full vertical span of the involved staves (topmost
    /// staff top → bottommost staff bottom), with a small pad so it
    /// does not clip glyphs that overflow slightly.
    static func drawRangeBoxes(
        system: LayoutSystem,
        selection: SelectionRenderState,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var staffIndices: Set<Int> = []
        for measure in system.measures {
            for el in measure.elements {
                switch el {
                case .chord(let notes, _, _, _, _, _, _, _):
                    for n in notes
                    where selection.selectedIDs.contains(.note(n.noteID)) {
                        let ax = measure.origin.x + n.origin.x
                        minX = min(minX, ax)
                        maxX = max(maxX, ax)
                        staffIndices.insert(n.noteID.staffIndex)
                    }
                case let .rest(_, origin, _, rid, _)
                    where selection.selectedIDs.contains(.rest(rid)):
                    let ax = measure.origin.x + origin.x
                    minX = min(minX, ax)
                    maxX = max(maxX, ax)
                    staffIndices.insert(rid.staffIndex)
                default:
                    break
                }
            }
        }
        guard !staffIndices.isEmpty else { return }

        let staffYs = staffIndices.compactMap { idx -> CGFloat? in
            idx < system.staffOrigins.count
                ? system.staffOrigins[idx].y : nil
        }
        guard let topY = staffYs.min(),
              let botY = staffYs.max()
        else { return }

        let xPad = metrics.sp * 1.4
        let yPad = metrics.sp
        let rect = CGRect(
            x: minX - xPad,
            y: topY - yPad,
            width: max(0, maxX - minX) + xPad * 2,
            height: (botY - topY) + metrics.staffHeight + yPad * 2)

        let path = CGPath(rect: rect, transform: nil)
        #if os(macOS)
        // LayoutEngine emits Y-down; macOS CALayer is Y-up. Flip
        // around `height` to match the other layers built in the
        // same tree (see `ScoreLayerBuilder.flipForPlatform`).
        var flip = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
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
