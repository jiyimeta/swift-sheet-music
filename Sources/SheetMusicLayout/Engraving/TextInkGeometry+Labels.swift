#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension TextInkGeometry {
    static func labelRects(for element: LayoutElement, metrics: StaffMetrics) -> [CGRect]? {
        switch element {
        case let .textMark(.dynamic, text, origin):
            let glyphs = DynamicSymbolMap.glyphString(for: text)
            let font = glyphs == nil ? font(for: .dynamics, metrics: metrics)
                : LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.sp * 4)
            return rect(
                text: glyphs ?? text,
                font: font,
                origin: origin,
                anchor: CGPoint(x: 0, y: 0.5),
            ).map { [$0] } ?? []
        case let .textMark(.tempo, text, origin):
            return tempoRects(text: text, origin: origin, metrics: metrics)
        case let .measureNumber(text, origin):
            return notationRects(text: text, role: .measureNumber, origin: origin, metrics: metrics)
        case let .staffName(text, origin):
            return notationRects(text: text, role: .staffName, origin: origin, metrics: metrics)
        case let .jump(text, origin, _):
            return notationRects(text: text, role: .jump, origin: origin, metrics: metrics)
        case let .marker(kind, text, origin, _):
            guard case let .text(label) = MarkerGlyph.variant(for: kind, text: text) else { return nil }
            return notationRects(text: label, role: .markerText, origin: origin, metrics: metrics)
        default: return nil
        }
    }

    private static func notationRects(
        text: String, role: NotationTextStyle.Role, origin: CGPoint, metrics: StaffMetrics,
    ) -> [CGRect] {
        let font = FontMetrics.provider.renderingTextFont(LayoutFont(
            face: "Edwin", pointSize: NotationTextStyle.fontSize(for: role, sp: metrics.sp),
            isItalic: NotationTextStyle.isItalic(for: role),
        ))
        let anchor = switch NotationTextStyle.anchor(for: role) {
        case .leadingCenter: CGPoint(x: 0, y: 0.5)
        case .bottomLeading: CGPoint(x: 0, y: 1)
        case .trailingCenter: CGPoint(x: 1, y: 0.5)
        }
        return rect(text: text, font: font, origin: origin, anchor: anchor).map { [$0] } ?? []
    }

    /// Tempo's music runs are ink-centered; its text runs use the typographic center.
    /// Leading spaces between runs survive the otherwise ink-leading horizontal anchor.
    private static func tempoRects(text: String, origin: CGPoint, metrics: StaffMetrics) -> [CGRect] {
        let provider = FontMetrics.provider
        let textFont = font(for: .tempo, metrics: metrics)
        let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: textFont.pointSize)
        var pen = origin.x
        var result: [CGRect] = []
        for (index, run) in MusicTextRuns.runs(in: text).enumerated() {
            var text = run.text
            switch run.kind {
            case .musicSymbol:
                if let ink = provider.textInkBounds(text: text, font: glyphFont) {
                    result.append(CGRect(x: pen, y: origin.y - ink.height / 2, width: ink.width, height: ink.height))
                    pen += provider.typographicWidth(text: text, font: glyphFont)
                }
            case .text:
                if index > 0 {
                    let spaces = text.prefix { $0 == " " }
                    pen += provider.typographicWidth(text: String(spaces), font: textFont)
                    text.removeFirst(spaces.count)
                }
                if let ink = rect(
                    text: text,
                    font: textFont,
                    origin: CGPoint(x: pen, y: origin.y),
                    anchor: CGPoint(x: 0, y: 0.5),
                ) {
                    result.append(ink)
                    pen += provider.typographicWidth(text: text, font: textFont)
                }
            }
        }
        return result
    }
}
