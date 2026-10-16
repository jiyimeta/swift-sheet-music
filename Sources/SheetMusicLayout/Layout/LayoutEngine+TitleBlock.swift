#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// `minHeight` is a floor in points on top of the rules below — the lowest bottom of the title's pictures
    /// (`buildTitleBlock`); 0 leaves the height exactly as it was.
    static func buildTitleFrame(
        source: ScoreFrame,
        style: ScoreStyle,
        metrics: StaffMetrics,
        docWidth: CGFloat,
        minHeight: CGFloat = 0,
    ) -> LayoutTitleFrame {
        // MuseScore stores offsets for the title-block styles in
        // millimetres (`OffsetType::ABS` — see `styledef.cpp`).
        // Conversion to typographic points: 72 pt ÷ 25.4 mm.  We use
        // the same conversion for both the per-text override
        // (`<offset>` in `.mscx`) and the styledef defaults (e.g.
        // `subTitleOffset = PointF(0, 10)` ⇒ 10 mm below VBox top).
        let mmToPt: CGFloat = 72.0 / 25.4

        // MuseScore's `<height>` is in spatium units. We use it as a
        // *minimum* — never shrink — but if the declared VBox is too
        // small to fit its own top-anchored texts (typical when the
        // user hand-edits `<height>` shorter than the subtitle stack
        // needs), grow the frame to keep them from being clipped by
        // the renderer's canvas. Bottom-anchored texts (composer /
        // lyricist) follow the resolved bottom edge.
        // SwiftUI `Text` resolved by `GraphicsContext.resolve` uses
        // the system font's natural line height (~1.2 × point size);
        // 1.3 leaves a small breathing margin above the next system.
        let textHeightFactor: CGFloat = 1.3
        var requiredFromTopAnchors: CGFloat = 0
        for (idx, t) in source.texts.enumerated() {
            let layout = titleBlockLayout(
                for: t.style, idx: idx, style: style,
                override: t.align, mmToPt: mmToPt,
            )
            // Bottom-anchored texts grow downward from the frame
            // bottom — they don't constrain how *tall* the frame
            // needs to be.
            guard layout.align.vertical == .top else { continue }
            let fontSize = CGFloat(t.fontSize ?? Double(layout.fontSize))
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            let bottom = layout.topOffset + dy + lastLineOffset(of: t, fontSize: fontSize)
                + fontSize * textHeightFactor
            if bottom > requiredFromTopAnchors {
                requiredFromTopAnchors = bottom
            }
        }
        let frameHeight = max(
            metrics.sp * 4,
            source.heightSp * metrics.sp,
            requiredFromTopAnchors,
            minHeight,
        )

        var laidOut: [LayoutFrameText] = []
        for (idx, t) in source.texts.enumerated() {
            let layout = titleBlockLayout(
                for: t.style, idx: idx, style: style,
                override: t.align, mmToPt: mmToPt,
            )
            let baseX = baseX(for: layout.align, docWidth: docWidth)
            let baseY: CGFloat = layout.align.vertical == .top
                ? layout.topOffset
                : frameHeight
            let dx = (t.offsetMm?.x ?? 0) * mmToPt
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            // Per-element `<size>` overrides the styledef default.
            // Used by scores that hand-tune font sizes — e.g.
            // test-platinum.mscx ships `<size>7</size>` on its
            // three Lyricist columns to tighten each verse block.
            let fontSize = CGFloat(t.fontSize ?? Double(layout.fontSize))
            laidOut.append(LayoutFrameText(
                text: t.text,
                style: t.style,
                position: CGPoint(x: baseX + dx, y: baseY + dy),
                fontSize: fontSize,
                anchor: anchor(for: layout.align),
                richText: t.richText.map { titleRichText($0, style: t.style, fontSize: fontSize) },
            ))
        }
        return LayoutTitleFrame(
            height: frameHeight, texts: laidOut,
        )
    }

    /// How far below its first line's top a title-block text's last line starts: 0 for a one-line text, so only a text
    /// broken over lines (`<br/>`, or a newline in a plain one) grows the frame. Measured by the placement the
    /// renderers draw from (`LayoutTitleFrame.placedLines`), so the frame holds every line they draw.
    private static func lastLineOffset(of text: FrameText, fontSize: CGFloat) -> CGFloat {
        let entry = LayoutFrameText(
            text: text.text, style: text.style, position: CGPoint(x: 0, y: 0), fontSize: fontSize,
            anchor: .topLeading,
            richText: text.richText.map { titleRichText($0, style: text.style, fontSize: fontSize) },
        )
        return LayoutTitleFrame(height: 0, texts: [entry]).placedLines().last?.position.y ?? 0
    }

    /// A title-block text's runs, in the face the block is set in (`LayoutTitleFrame.font(size:)`). Title-block styles
    /// are not spatium dependent, so a `<font size>` is literal points; symbols take the style's musical-symbol size.
    static func titleRichText(
        _ richText: RichText, style: FrameText.Style, fontSize: CGFloat,
    ) -> LayoutRichText {
        let textStyle: TextStyleType = switch style {
        case .title: .title
        case .subtitle: .subtitle
        case .composer: .composer
        case .lyricist: .lyricist
        case .other: .staffText
        }
        return LayoutRichText(
            richText,
            baseFont: FontMetrics.provider.renderingTextFont(LayoutTitleFrame.font(size: fontSize)),
            pointScale: 1,
            symbolPointSize: LayoutRichText.musicalSymbolSize(for: textStyle),
        )
    }

    /// Resolved layout properties for a title-block text style.
    /// `align` picks horizontal/vertical anchor, `topOffset` is the
    /// styledef vertical offset applied when `align.vertical == .top`
    /// (e.g. subtitle's 10 mm), `fontSize` is the styledef default.
    struct TitleBlockLayout {
        let align: TextAlign
        let topOffset: CGFloat
        let fontSize: CGFloat
    }

    /// Defaults sourced from MuseScore's `engraving/style/styledef.cpp`:
    ///   Title    — Align(HCENTER, TOP),    offset (0,  0) mm, font 22pt
    ///   Subtitle — Align(HCENTER, TOP),    offset (0, 10) mm, font 14pt
    ///   Composer — Align(RIGHT,   BOTTOM), offset (0,  0) mm, font 10pt
    ///   Lyricist — Align(LEFT,    BOTTOM), offset (0,  0) mm, font 10pt
    /// Per-style align overrides on `ScoreStyle` (e.g.
    /// `<lyricistAlign>center,bottom</lyricistAlign>`) replace the
    /// styledef horizontal/vertical pair while leaving the offset
    /// and font size unchanged.
    static func titleBlockLayout(
        for textStyle: FrameText.Style,
        idx: Int,
        style scoreStyle: ScoreStyle,
        override: TextAlign?,
        mmToPt: CGFloat,
    ) -> TitleBlockLayout {
        // Per-element `<align>` overrides both the styledef default
        // and any `<{role}Align>` style-wide override — MuseScore's
        // `read460/tread.cpp` writes `<align>` only when the element
        // diverges from the resolved style, so when present it is the
        // final word.
        let base = switch textStyle {
        case .title:
            TitleBlockLayout(
                align: scoreStyle.titleAlign
                    ?? TextAlign(horizontal: .center, vertical: .top),
                topOffset: 0,
                fontSize: 22,
            )
        case .subtitle:
            TitleBlockLayout(
                align: scoreStyle.subtitleAlign
                    ?? TextAlign(horizontal: .center, vertical: .top),
                topOffset: 10 * mmToPt,
                fontSize: 14,
            )
        case .composer:
            TitleBlockLayout(
                align: scoreStyle.composerAlign
                    ?? TextAlign(horizontal: .right, vertical: .bottom),
                topOffset: 0,
                fontSize: 10,
            )
        case .lyricist:
            TitleBlockLayout(
                align: scoreStyle.lyricistAlign
                    ?? TextAlign(horizontal: .left, vertical: .bottom),
                topOffset: 0,
                fontSize: 10,
            )
        case .other:
            TitleBlockLayout(
                align: TextAlign(horizontal: .center, vertical: .top),
                topOffset: 10 * mmToPt + CGFloat(idx) * 4 * mmToPt,
                fontSize: 10,
            )
        }
        guard let override else { return base }
        return TitleBlockLayout(
            align: override,
            // Switching a default-bottom role (composer / lyricist)
            // to a top anchor brings the text up to the frame top
            // edge — keep the styledef `topOffset` so titles in a
            // mixed top stack don't all collapse to y=0.
            topOffset: base.topOffset,
            fontSize: base.fontSize,
        )
    }

    static func baseX(
        for align: TextAlign, docWidth: CGFloat,
    ) -> CGFloat {
        switch align.horizontal {
        case .left: 0
        case .center: docWidth / 2
        case .right: docWidth
        }
    }

    /// `LayoutFrameText.Anchor` only models the six rectangular
    /// corners. Vertical `.center` / `.baseline` (rare for title
    /// roles) collapse to the top-side anchor of the same horizontal
    /// axis — adequate for the cases that actually appear in MSCX
    /// title blocks.
    static func anchor(
        for align: TextAlign,
    ) -> LayoutFrameText.Anchor {
        switch (align.horizontal, align.vertical) {
        case (.left, .bottom): return .bottomLeading
        case (.center, .bottom): return .bottom
        case (.right, .bottom): return .bottomTrailing
        case (.left, _): return .topLeading
        case (.center, _): return .top
        case (.right, _): return .topTrailing
        }
    }
}
