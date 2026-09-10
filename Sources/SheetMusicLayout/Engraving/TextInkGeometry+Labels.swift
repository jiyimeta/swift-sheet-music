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
        let font = NotationTextStyle.font(for: role, sp: metrics.sp)
        let anchor = NotationTextStyle.anchorPoint(for: role)
        return rect(text: text, font: font, origin: origin, anchor: anchor).map { [$0] } ?? []
    }

    package struct PositionedRun {
        package let text: String
        package let font: LayoutFont
        package let baseline: CGPoint
    }

    private static func tempoRects(text: String, origin: CGPoint, metrics: StaffMetrics) -> [CGRect] {
        tempoRuns(text: text, origin: origin, metrics: metrics).compactMap { run in
            guard let ink = FontMetrics.provider.textInkBounds(text: run.text, font: run.font) else { return nil }
            return CGRect(
                x: run.baseline.x + ink.minX,
                y: run.baseline.y - ink.maxY,
                width: ink.width,
                height: ink.height,
            )
        }
    }

    /// Tempo text is typographically centered; music is ink-centered. Preserve
    /// spaces between runs before applying their individual ink-leading anchors.
    package static func tempoRuns(text: String, origin: CGPoint, metrics: StaffMetrics) -> [PositionedRun] {
        let provider = FontMetrics.provider
        let textFont = font(for: .tempo, metrics: metrics)
        let glyphFont = LayoutFont(face: SMuFLFamily.bravura, pointSize: textFont.pointSize)
        var pen = origin.x
        var result: [PositionedRun] = []
        for (index, run) in MusicTextRuns.runs(in: text).enumerated() {
            var text = run.text
            let font = run.kind == .musicSymbol ? glyphFont : textFont
            if run.kind == .text, index > 0 {
                let spaces = text.prefix { $0 == " " }
                pen += provider.typographicWidth(text: String(spaces), font: font)
                text.removeFirst(spaces.count)
            }
            guard let ink = provider.textInkBounds(text: text, font: font) else { continue }
            let baseline = run.kind == .musicSymbol
                ? CGPoint(x: pen - ink.minX, y: origin.y + ink.midY)
                : baselineOrigin(
                    text: text,
                    font: font,
                    origin: CGPoint(x: pen, y: origin.y),
                    anchor: CGPoint(x: 0, y: 0.5),
                )
            result.append(PositionedRun(text: text, font: font, baseline: baseline))
            pen += typographicSize(text: text, font: font).width
        }
        return result
    }
}
