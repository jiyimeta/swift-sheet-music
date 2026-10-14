#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutElementShape {
    /// `textRect(text:font:origin:anchor:)` for typeset runs: the block's typographic box — its advance width and its
    /// stack height — hung off `origin` by exactly the plain box's rule, so a one-font block reserves what its plain
    /// twin does. That holds for a centered lyric too: the box is centered by the advance, as the plain box is, while
    /// the ink and the runs are centered by the ink (`LayoutRichText.blockOrigin(at:anchor:)`).
    ///
    /// The box is unioned with the runs' ink. A line's metrics come from its text runs only, so a symbol taller than
    /// them — a segno or coda in a marker, a pedal mark after "senza" — would otherwise poke out of the box, and out of
    /// the hit rects navigation takes from it (`ScoreHitTester.navigationRects`).
    static func textRect(rich: LayoutRichText, origin: CGPoint, anchor: TextAnchorConvention) -> CGRect {
        let unit = switch anchor {
        case .leadingCenter: CGPoint(x: 0, y: 0.5)
        case .bottomLeading: CGPoint(x: 0, y: 1)
        case .center: CGPoint(x: 0.5, y: 0.5)
        }
        let box = CGRect(
            x: origin.x - unit.x * rich.size.width, y: origin.y - unit.y * rich.size.height,
            width: rich.size.width, height: rich.size.height,
        )
        return rich.inkRect(at: origin, anchor: unit).map { box.union($0) } ?? box
    }
}
