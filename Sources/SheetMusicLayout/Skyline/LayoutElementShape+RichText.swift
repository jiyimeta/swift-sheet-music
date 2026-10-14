#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutElementShape {
    /// `textRect(text:font:origin:anchor:)` for typeset runs: the block's typographic box — its advance width and its
    /// stack height — hung off `origin` by exactly the plain box's rule, so a one-font block reserves what its plain
    /// twin does. That holds for a centered lyric too: the box is centered by the advance, as the plain box is, while
    /// the ink and the runs are centered by the ink (`LayoutRichText.blockOrigin(at:anchor:)`). The anchor is the one
    /// the element's kind is drawn at (`LayoutRichText.anchor(for:)`).
    ///
    /// The box is unioned with the runs' ink. A line's metrics come from its text runs only, so a symbol taller than
    /// them — a segno or coda in a marker, a pedal mark after "senza" — would otherwise poke out of the box, and out of
    /// the hit rects navigation takes from it (`ScoreHitTester.navigationRects`).
    static func textRect(rich: LayoutRichText, origin: CGPoint, kind: LayoutRichText.ElementKind) -> CGRect {
        let unit = LayoutRichText.anchor(for: kind)
        let box = CGRect(
            x: origin.x - unit.x * rich.size.width, y: origin.y - unit.y * rich.size.height,
            width: rich.size.width, height: rich.size.height,
        )
        return rich.inkRect(at: origin, anchor: unit).map { box.union($0) } ?? box
    }

    /// A marker's or jump's skyline box: its runs' box (`textRect(rich:origin:kind:)`), hung by the anchor its kind is
    /// drawn at. Every marker draws its runs — a segno or coda is a symbol run of its text, as in MuseScore — so the
    /// marker's kind only decides which end of its bar it hangs from. `nil` for one without runs — no rich text, or
    /// rich text whose lines hold none — which draws nothing.
    static func navigationLabelRect(for element: LayoutElement) -> CGRect? {
        switch element {
        case let .marker(kind, _, origin, _, rich?) where hasRuns(rich):
            textRect(rich: rich, origin: origin, kind: .forMarker(kind))
        case let .jump(_, origin, _, rich?) where hasRuns(rich):
            textRect(rich: rich, origin: origin, kind: .jump)
        default:
            nil
        }
    }

    private static func hasRuns(_ rich: LayoutRichText) -> Bool {
        rich.lines.contains { !$0.runs.isEmpty }
    }
}
