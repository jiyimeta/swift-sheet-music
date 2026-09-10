#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Text geometry shared by selection, document bounds, and renderers. Anchors use the
/// whole typographic line stack vertically and the actual ink band horizontally.
public enum TextInkGeometry {
    public static func font(
        for style: TextStyleType, overrides: TextProperties = TextProperties(), metrics: StaffMetrics,
    ) -> LayoutFont {
        let resolved = overrides.resolved(against: style)
        return FontMetrics.provider.renderingTextFont(LayoutFont(
            face: resolved.face, pointSize: TextRoleStyle.fontSize(defaults: resolved, sp: metrics.sp),
            weight: resolved.style.contains(.bold) ? .bold : .regular,
            isItalic: resolved.style.contains(.italic),
        ))
    }

    public static func typographicSize(text: String, font: LayoutFont) -> CGSize {
        let provider = FontMetrics.provider
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let height = provider.ascent(font: font) + provider.descent(font: font)
        return CGSize(
            width: lines.reduce(0) { max($0, provider.typographicWidth(text: String($1), font: font)) },
            height: height + CGFloat(max(0, lines.count - 1)) * (height + provider.leading(font: font)),
        )
    }

    /// Translation applied after flipping Y-up font paths into Y-down coordinates.
    /// `anchor` follows UnitPoint: leading-center = (0, .5), bottom-leading = (0, 1).
    public static func baselineOrigin(
        text: String, font: LayoutFont, origin: CGPoint, anchor: CGPoint,
    ) -> CGPoint {
        let ink = FontMetrics.provider.textInkBounds(text: text, font: font)
        return CGPoint(
            x: origin.x - (ink?.minX ?? 0) - anchor.x * (ink?.width ?? 0),
            y: origin.y + FontMetrics.provider.ascent(font: font)
                - anchor.y * typographicSize(text: text, font: font).height,
        )
    }

    public static func rect(text: String, font: LayoutFont, origin: CGPoint, anchor: CGPoint) -> CGRect? {
        guard let ink = FontMetrics.provider.textInkBounds(text: text, font: font) else { return nil }
        let baseline = baselineOrigin(text: text, font: font, origin: origin, anchor: anchor)
        return CGRect(x: baseline.x + ink.minX, y: baseline.y - ink.maxY, width: ink.width, height: ink.height)
    }

    public static func rehearsalBox(text: String, font: LayoutFont, origin: CGPoint, sp: CGFloat) -> CGRect {
        let size = typographicSize(text: text, font: font)
        return RehearsalMarkFrame.boxRect(
            textWidth: max(size.width, font.pointSize * 0.5), textHeight: size.height,
            origin: origin, pad: RehearsalMarkFrame.paddingSp(sp: sp),
        )
    }

    /// The same frame for rendering, hit bounds, and skyline. Circle clearance is measured
    /// from the actual positioned ink to the inner stroke, including all lines of text.
    public static func rehearsalFrame(
        text: String, font: LayoutFont, origin: CGPoint, sp: CGFloat, frame: TextFrameType,
    ) -> RehearsalMarkFrame.Shape {
        let pad = RehearsalMarkFrame.paddingSp(sp: sp)
        let ink = rect(
            text: text, font: font, origin: CGPoint(x: origin.x + pad, y: origin.y - pad),
            anchor: CGPoint(x: 0, y: 1),
        )
        return RehearsalMarkFrame.shape(
            for: frame, around: rehearsalBox(text: text, font: font, origin: origin, sp: sp),
            enclosing: ink, clearance: pad + RehearsalMarkFrame.strokeWidthSp(sp: sp) / 2,
        )
    }

    /// Element-local Y-down rectangles. Nil means unsupported; an empty array means supported
    /// but no painted ink, so callers must not substitute an anchor-sized fallback.
    public static func rects(for element: LayoutElement, metrics: StaffMetrics) -> [CGRect]? {
        switch element {
        case let .textMark(.lyrics, text, origin):
            return rect(
                text: text,
                font: font(for: .lyricsOdd, metrics: metrics),
                origin: origin,
                anchor: CGPoint(x: 0.5, y: 0.5),
            ).map { [$0] } ?? []
        case let .staffText(text, origin, _, style, _, _):
            return rect(
                text: text,
                font: font(for: style, metrics: metrics),
                origin: origin,
                anchor: CGPoint(x: 0, y: 1),
            ).map { [$0] } ?? []
        case let .rehearsalMark(text, origin, frame, _, _, _):
            return rehearsalRects(text: text, origin: origin, frame: frame, metrics: metrics)
        case let .harmony(harmony):
            return harmonyRects(harmony, metrics: metrics)
        default: return labelRects(for: element, metrics: metrics)
        }
    }

    private static func rehearsalRects(
        text: String, origin: CGPoint, frame: RehearsalMark.FrameKind, metrics: StaffMetrics,
    ) -> [CGRect] {
        guard !text.isEmpty else { return [] }
        let font = font(for: .rehearsalMark, metrics: metrics)
        let pad = RehearsalMarkFrame.paddingSp(sp: metrics.sp)
        var result = rect(
            text: text,
            font: font,
            origin: CGPoint(x: origin.x + pad, y: origin.y - pad),
            anchor: CGPoint(x: 0, y: 1),
        ).map { [$0] } ?? []
        switch rehearsalFrame(text: text, font: font, origin: origin, sp: metrics.sp, frame: frame) {
        case .none: break
        case let .rectangle(rect), let .ellipse(rect):
            let halfStroke = RehearsalMarkFrame.strokeWidthSp(sp: metrics.sp) / 2
            result.append(rect.insetBy(dx: -halfStroke, dy: -halfStroke))
        }
        return result
    }

    private static func harmonyRects(_ harmony: LayoutHarmony, metrics: StaffMetrics) -> [CGRect] {
        harmony.runs.compactMap { run in
            let text: String
            let font: LayoutFont
            switch run.kind {
            case .text:
                text = run.content
                font = self.font(
                    for: harmony.harmony.styleType,
                    overrides: harmony.harmony.properties,
                    metrics: metrics,
                )
            case let .accidental(accidental):
                text = String(accidental.codepoint)
                font = LayoutFont(
                    face: SMuFLFamily.bravura,
                    pointSize: HarmonyRendering.glyphPointSize(for: harmony.harmony, metrics: metrics),
                )
            }
            return rect(
                text: text,
                font: font,
                origin: CGPoint(x: CGFloat(harmony.anchorX + run.x), y: CGFloat(harmony.y)),
                anchor: CGPoint(x: 0, y: 0.5),
            )
        }
    }
}
