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

    /// A marker's or jump's skyline box: its runs' box when it draws them, else the plain label's, hung leading-center.
    ///
    /// A marker whose kind draws a glyph — a segno or coda (`MarkerGlyph.variant`) — draws that glyph whatever its
    /// markup says, so its runs size nothing here, just as `TextInkGeometry.labelRects` takes no ink from them.
    static func navigationLabelRect(
        for element: LayoutElement, kind: ShapeItemKind, metrics: StaffMetrics,
    ) -> CGRect? {
        let text: String
        let origin: CGPoint
        let rich: LayoutRichText?
        let richKind: LayoutRichText.ElementKind
        switch element {
        case let .marker(markerKind, markerText, markerOrigin, _, richText):
            text = markerText
            origin = markerOrigin
            if case .text = MarkerGlyph.variant(for: markerKind, text: markerText) {
                rich = richText
            } else {
                rich = nil
            }
            richKind = .marker
        case let .jump(jumpText, jumpOrigin, _, richText):
            text = jumpText
            origin = jumpOrigin
            rich = richText
            richKind = .jump
        default:
            return nil
        }
        if let rich {
            return textRect(rich: rich, origin: origin, kind: richKind)
        }
        return textRect(text: text, font: font(for: kind, metrics: metrics), origin: origin, anchor: .leadingCenter)
    }
}
