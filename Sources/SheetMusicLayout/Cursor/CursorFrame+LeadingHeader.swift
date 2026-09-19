#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutDocument {
    /// Approximate right edge of a measure's leading clef / key sig /
    /// time sig column, in measure-local coords. Mirrors the
    /// `HeaderSchedule.contentStartX` the layout engine derived when
    /// placing the measure — the `sp * 2` `clefX` baseline plus each
    /// column's own width. Used by `beatXInMeasure`'s no-anchors
    /// fallback so the cursor doesn't sit on the leading glyphs.
    ///
    /// Mid-measure clef / key changes land in `elements` too, but only
    /// after a chord — and a measure with any chord never reaches this
    /// fallback, so widening the floor with them is a no-op.
    ///
    /// **A COURTESY signature is the exception, and it is why this only
    /// looks at the measure's left half.** A key change at a system break
    /// is announced at the END of the bar before it, and that bar can
    /// perfectly well be an empty one — which is exactly the case this
    /// fallback serves. Taking the maximum over every signature in the
    /// measure then pushed `rightEdge` out to the courtesy glyphs at the
    /// right margin, leaving no body to spread the beats across, and the
    /// cursor sat on the system's right edge for the whole bar before
    /// snapping back on the next one (reported 2026-09-19).
    ///
    /// The left half is the whole of what "leading" can mean here: the
    /// header is drawn from the measure's left edge, and a header wide
    /// enough to fill half a bar has already left the cursor nowhere
    /// sensible to start.
    func leadingHeaderRightEdge(in measure: LayoutMeasure) -> CGFloat {
        let sp = metrics.sp
        var rightEdge: CGFloat = sp * 2
        let leadingLimit = measure.width / 2
        for el in measure.elements {
            switch el {
            case let .clef(_, origin, _) where origin.x <= leadingLimit:
                rightEdge = max(rightEdge, origin.x + sp * 2)
            case let .keySignature(sharps, flats, _, naturals, origin, _) where origin.x <= leadingLimit:
                let glyphs = max(sharps, flats, naturals.count)
                rightEdge = max(rightEdge, LayoutEngine.keySignatureColumnEnd(
                    anchorX: origin.x, glyphCount: glyphs, sp: sp,
                ))
            case let .timeSignature(_, _, _, origin, _) where origin.x <= leadingLimit:
                rightEdge = max(rightEdge, origin.x + sp * 3.5)
            default:
                break
            }
        }
        return rightEdge
    }
}
