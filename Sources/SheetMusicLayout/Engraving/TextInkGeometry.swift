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
        rehearsalBox(size: typographicSize(text: text, font: font), font: font, origin: origin, sp: sp)
    }

    /// The frame box around a text block of `size` — plain text's typographic size, or a rich text's (its advance
    /// width, like the plain size's).
    static func rehearsalBox(size: CGSize, font: LayoutFont, origin: CGPoint, sp: CGFloat) -> CGRect {
        RehearsalMarkFrame.boxRect(
            textWidth: max(size.width, font.pointSize * 0.5), textHeight: size.height,
            origin: origin, pad: RehearsalMarkFrame.paddingSp(sp: sp),
        )
    }

    /// The same frame for rendering, hit bounds, and skyline. Circle clearance is measured
    /// from the actual positioned ink to the inner stroke, including all lines of text. `rich` is the mark's typeset
    /// runs, when it has them: the box and the ink are then theirs.
    public static func rehearsalFrame(
        text: String, font: LayoutFont, origin: CGPoint, sp: CGFloat, frame: TextFrameType,
        rich: LayoutRichText? = nil,
    ) -> RehearsalMarkFrame.Shape {
        let pad = RehearsalMarkFrame.paddingSp(sp: sp)
        let inkOrigin = CGPoint(x: origin.x + pad, y: origin.y - pad)
        let ink = rich.map { $0.inkRect(at: inkOrigin, anchor: CGPoint(x: 0, y: 1)) }
            ?? rect(text: text, font: font, origin: inkOrigin, anchor: CGPoint(x: 0, y: 1))
        let box = rich.map { rehearsalBox(size: $0.size, font: font, origin: origin, sp: sp) }
            ?? rehearsalBox(text: text, font: font, origin: origin, sp: sp)
        return RehearsalMarkFrame.shape(
            for: frame, around: box, enclosing: ink, clearance: pad + RehearsalMarkFrame.strokeWidthSp(sp: sp) / 2,
        )
    }

    /// Element-local Y-down rectangles. Nil means unsupported; an empty array means supported
    /// but no painted ink, so callers must not substitute an anchor-sized fallback.
    public static func rects(for element: LayoutElement, metrics: StaffMetrics) -> [CGRect]? {
        switch element {
        case let .textMark(.lyrics(_, _, _, _, properties), text, origin, richText):
            if let richText {
                return richText.inkRect(at: origin, anchor: CGPoint(x: 0.5, y: 0.5)).map { [$0] } ?? []
            }
            return rect(
                text: text,
                font: font(for: .lyricsOdd, overrides: properties, metrics: metrics),
                origin: origin,
                anchor: CGPoint(x: 0.5, y: 0.5),
            ).map { [$0] } ?? []
        case let .staffText(text, origin, _, style, _, _, properties, _, richText):
            if let richText {
                return richText.inkRect(at: origin, anchor: CGPoint(x: 0, y: 1)).map { [$0] } ?? []
            }
            return rect(
                text: text,
                font: font(for: style, overrides: properties, metrics: metrics),
                origin: origin,
                anchor: CGPoint(x: 0, y: 1),
            ).map { [$0] } ?? []
        case let .rehearsalMark(text, origin, frame, _, _, _, properties, richText):
            return rehearsalRects(
                text: text, origin: origin, frame: frame, properties: properties, metrics: metrics, rich: richText,
            )
        case let .harmony(harmony):
            return harmonyRects(harmony, metrics: metrics)
        default: return labelRects(for: element, metrics: metrics)
        }
    }

    private static func rehearsalRects(
        text: String, origin: CGPoint, frame: TextFrameType, properties: TextProperties,
        metrics: StaffMetrics, rich: LayoutRichText?,
    ) -> [CGRect] {
        guard !text.isEmpty || rich != nil else { return [] }
        let font = font(for: .rehearsalMark, overrides: properties, metrics: metrics)
        let pad = RehearsalMarkFrame.paddingSp(sp: metrics.sp)
        let inkOrigin = CGPoint(x: origin.x + pad, y: origin.y - pad)
        let ink = rich.map { $0.inkRect(at: inkOrigin, anchor: CGPoint(x: 0, y: 1)) }
            ?? rect(text: text, font: font, origin: inkOrigin, anchor: CGPoint(x: 0, y: 1))
        var result = ink.map { [$0] } ?? []
        switch rehearsalFrame(text: text, font: font, origin: origin, sp: metrics.sp, frame: frame, rich: rich) {
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
