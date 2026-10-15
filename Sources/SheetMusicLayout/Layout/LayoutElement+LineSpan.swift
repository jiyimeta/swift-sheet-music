#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutElement {
    /// The X span between a line-like element's two ends, in the coordinates its origins are in, or `nil` for an
    /// element that is not drawn between two ends.
    ///
    /// Spanner segments, ties, glissandi and lyric lines are drawn from one end to the other — a slur's control
    /// points stay inside its ends — so this bounds where they can be seen or hit, apart from a label at the start
    /// or a hook at the end. What uses it to skip elements (`ScoreHitTester`, the renderer's partial mounting) adds
    /// its own allowance for those.
    public var lineSpanX: ClosedRange<CGFloat>? {
        let ends: (CGPoint, CGPoint)
        switch self {
        case let .spannerSegment(_, from, to, _, _, _, _, _, _): ends = (from, to)
        case let .tieArc(from, to, _, _): ends = (from, to)
        case let .glissandoLine(from, to, _, _, _): ends = (from, to)
        case let .lyricsMelisma(from, to, _): ends = (from, to)
        case let .lyricHyphen(from, to, _): ends = (from, to)
        default: return nil
        }
        return min(ends.0.x, ends.1.x) ... max(ends.0.x, ends.1.x)
    }
}
