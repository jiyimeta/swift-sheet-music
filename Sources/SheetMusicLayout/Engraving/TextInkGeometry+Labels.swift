#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension TextInkGeometry {
    static func labelRects(for element: LayoutElement, metrics: StaffMetrics) -> [CGRect]? {
        switch element {
        case let .textMark(.dynamic, text, origin, _):
            let glyphs = DynamicSymbolMap.glyphString(for: text)
            let font = glyphs == nil ? font(for: .dynamics, metrics: metrics)
                : LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.sp * 4)
            return rect(
                text: glyphs ?? text,
                font: font,
                origin: origin,
                anchor: CGPoint(x: 0, y: 0.5),
            ).map { [$0] } ?? []
        case let .textMark(.tempo(_, _, properties), text, origin, richText):
            return richRects(
                richText ?? LayoutRichText.tempoText(text, properties: properties, metrics: metrics),
                origin: origin, kind: .tempo,
            )
        case let .measureNumber(text, origin):
            return notationRects(text: text, role: .measureNumber, origin: origin, metrics: metrics)
        case let .staffName(text, origin):
            return notationRects(text: text, role: .staffName, origin: origin, metrics: metrics)
        // A marker or jump is its runs, which layout always sets; without them it has no ink.
        case let .jump(_, origin, _, richText):
            return richRects(richText, origin: origin, kind: .jump) ?? []
        case let .marker(kind, _, origin, _, richText):
            return richRects(richText, origin: origin, kind: .forMarker(kind)) ?? []
        default: return nil
        }
    }

    private static func notationRects(
        text: String, role: NotationTextStyle.Role, origin: CGPoint, metrics: StaffMetrics,
    ) -> [CGRect] {
        let font = NotationTextStyle.font(for: role, sp: metrics.sp)
        let anchor = NotationTextStyle.anchorPoint(for: role)
        return rect(text: text, font: font, origin: origin, anchor: anchor).map { [$0] } ?? []
    }

    /// A navigation label's typeset runs, placed by its kind's anchor; `nil` for a plain label.
    private static func richRects(
        _ rich: LayoutRichText?, origin: CGPoint, kind: LayoutRichText.ElementKind,
    ) -> [CGRect]? {
        rich.map { $0.inkRect(at: origin, anchor: LayoutRichText.anchor(for: kind)).map { [$0] } ?? [] }
    }
}
