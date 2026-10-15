#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Where an element's `origin` sits relative to its rendered ink.
/// Migrated (and extended) from the retired
/// `LayoutEngine+Extents.AboveStaffAnchor`; each case matches the
/// anchor the SwiftUI / CALayer / Android renderers pass to their
/// draw call.
enum TextAnchorConvention {
    /// SwiftUI `.leading` — origin at the left edge, vertical centre.
    case leadingCenter
    /// SwiftUI `.bottomLeading` — origin at the lower-left corner.
    case bottomLeading
    /// SwiftUI `.center` — origin at the centre of both axes.
    case center
}

extension LayoutElementShape {
    /// Conservative typographic rect of `text`, positioned per the rendered block anchor.
    ///
    /// `text` may carry literal newlines — MuseScore writes multi-line
    /// `<StaffText>` payloads that way, and
    /// `ScoreLayerBuilder+Helpers.textPath` stacks them, drawing line
    /// *i* one `lineHeight` below line *i-1*. Handing the raw string to
    /// `typographicWidth` would lay every line out on one `CTLine`, so
    /// the box would come out as wide as the concatenation and only one
    /// line tall. Measure per line instead: width is the widest line,
    /// height covers the whole stack.
    static func textRect(
        text: String, font: LayoutFont,
        origin: CGPoint, anchor: TextAnchorConvention,
    ) -> CGRect {
        let provider = FontMetrics.provider
        let lines = text.components(separatedBy: "\n")
        let width = lines.reduce(CGFloat.zero) {
            max($0, provider.typographicWidth(text: $1, font: font))
        }
        let ascent = provider.ascent(font: font)
        let descent = provider.descent(font: font)
        let firstLineHeight = ascent + descent
        // Extra stack below line 0's box. Zero for single-line text, so
        // every rect below reduces to the pre-multi-line geometry.
        let extraLines = CGFloat(lines.count - 1)
            * (firstLineHeight + provider.leading(font: font))
        let height = firstLineHeight + extraLines
        switch anchor {
        case .leadingCenter:
            return CGRect(
                x: origin.x, y: origin.y - height / 2,
                width: width, height: height,
            )
        case .bottomLeading:
            // The renderer anchors the whole stack, including empty lines.
            return CGRect(
                x: origin.x, y: origin.y - height,
                width: width, height: height,
            )
        case .center:
            return CGRect(
                x: origin.x - width / 2,
                y: origin.y - height / 2,
                width: width, height: height,
            )
        }
    }

    /// Vertical ink extent of a SMuFL glyph run, in points relative to
    /// the run's baseline: `(top, bottom)` in layout (Y-down) space,
    /// or `nil` when no glyph in the run has a measurable path.
    ///
    /// A `textRect` on a SMuFL face is catastrophically wrong for the
    /// skyline: Bravura's typographic ascent and descent are each 2 em
    /// so that staff-relative glyphs fit inside a single line box, so
    /// its em box is 4 em tall — 112 pt at the 4 sp dynamics size,
    /// against ~8 pt of actual `mf` ink. Measuring the glyph paths
    /// instead keeps a dynamic from occupying 16 sp of skyline.
    ///
    /// Probing at `pointSize` 4 makes 1 em = 4 pt, so a bbox unit is
    /// one staff space; scale by `pointSize / 4` to reach the run's
    /// own size. Mirrors `smuflGlyphRect`'s convention.
    static func smuflRunInkExtent(
        glyphs: String, pointSize: CGFloat,
    ) -> (top: CGFloat, bottom: CGFloat)? {
        let provider = FontMetrics.provider
        let em = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        for scalar in glyphs.unicodeScalars {
            guard let bbox = provider.glyphPathBoundingBox(
                font: em,
                codepoint: UInt16(truncatingIfNeeded: scalar.value),
            ), bbox.height > 0 else { continue }
            minY = min(minY, bbox.minY)
            maxY = max(maxY, bbox.maxY)
        }
        guard minY.isFinite, maxY > minY else { return nil }
        let scale = pointSize / 4
        // Font Y is up from the baseline, layout Y is down.
        return (top: -maxY * scale, bottom: -minY * scale)
    }

    /// Baseline Y of a run typeset in `font` and positioned by
    /// `anchor` at `origin`. Mirrors `textRect`'s box placement.
    static func baselineY(
        font: LayoutFont, originY: CGFloat,
        anchor: TextAnchorConvention,
    ) -> CGFloat {
        let provider = FontMetrics.provider
        let ascent = provider.ascent(font: font)
        let descent = provider.descent(font: font)
        switch anchor {
        case .leadingCenter, .center:
            return originY + (ascent - descent) / 2
        case .bottomLeading:
            return originY - descent
        }
    }

    /// Font used to render each autoplaced text kind, matching the
    /// renderers' `ResolvedTextStyle` / `NotationTextStyle` choices.
    static func font(
        for kind: ShapeItemKind, metrics: StaffMetrics,
    ) -> LayoutFont {
        let sp = metrics.sp
        switch kind {
        case .lyrics:
            return styleFont(.lyricsOdd, sp: sp)
        case .tempo:
            return styleFont(.tempo, sp: sp)
        case .staffText, .systemText:
            return styleFont(.staffText, sp: sp)
        case .rehearsalMark:
            return styleFont(.rehearsalMark, sp: sp)
        case .harmony:
            return styleFont(.chordSymbolA, sp: sp)
        case .dynamics:
            return styleFont(.dynamics, sp: sp)
        case .measureNumber:
            return LayoutFont(
                face: "Edwin",
                pointSize: NotationTextStyle.fontSize(
                    for: .measureNumber, sp: sp,
                ),
            )
        default:
            return styleFont(.staffText, sp: sp)
        }
    }

    /// `overrides` is an element's authored font; an empty one resolves to exactly the style's font.
    private static func styleFont(
        _ style: TextStyleType, overrides: TextProperties = TextProperties(), sp: CGFloat,
    ) -> LayoutFont {
        TextInkGeometry.font(for: style, overrides: overrides, metrics: StaffMetrics(staffSize: sp * 4))
    }

    /// Rects for the elements the skyline pass is allowed to move.
    static func autoplacedRects( // swiftlint:disable:this cyclomatic_complexity
        for element: LayoutElement,
        kind: ShapeItemKind, metrics: StaffMetrics,
    ) -> [CGRect] {
        let sp = metrics.sp
        switch element {
        case let .textMark(markKind, text, origin, richText):
            return [textMarkRect(
                markKind: markKind, text: text, origin: origin,
                kind: kind, metrics: metrics, rich: richText,
            )]
        case let .staffText(text, origin, _, style, _, _, properties, _, richText):
            return [richText.map { textRect(rich: $0, origin: origin, kind: .staffText) } ?? textRect(
                text: text, font: TextInkGeometry.font(for: style, overrides: properties, metrics: metrics),
                origin: origin, anchor: .bottomLeading,
            )]
        case let .measureNumber(text, origin):
            return [textRect(
                text: text, font: font(for: kind, metrics: metrics),
                origin: origin, anchor: .bottomLeading,
            )]
        case .marker, .jump:
            return navigationLabelRect(for: element).map { [$0] } ?? []
        case let .rehearsalMark(text, origin, frame, _, _, _, properties, richText):
            return [rehearsalMarkRect(
                text: text, origin: origin, frame: frame, properties: properties,
                metrics: metrics, rich: richText,
            )]
        case let .harmony(lh):
            let f = font(for: .harmony, metrics: metrics)
            let provider = FontMetrics.provider
            let height = provider.ascent(font: f)
                + provider.descent(font: f)
            var box = CGRect(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y) - height / 2,
                width: max(CGFloat(lh.width), sp),
                height: height,
            )
            for ink in TextInkGeometry.rects(for: element, metrics: metrics) ?? [] {
                box = box.union(ink)
            }
            return [box]
        case let .lyricsMelisma(from, to, _), let .lyricHyphen(from, to, _):
            return [spanRect(from, to, thickness: sp * 0.3)]
        case let .spannerSegment(.pedal, from, to, _, _, _, _, _):
            return PedalInkGeometry.rects(from: from, to: to, metrics: metrics)
        case let .spannerSegment(.gradualTempoChange, from, to, _, _, _, _, richText):
            return [SpannerGeometry.gradualTempoChangeInk(from: from, to: to, label: richText, sp: sp)]
        case let .spannerSegment(spannerKind, from, to, _, _, _, _, _):
            return [spannerRect(
                kind: spannerKind, from: from, to: to, sp: sp,
            )]
        case let .figure(_, figure, _, _):
            return figure.ink.isEmpty ? [] : [figure.ink]
        default:
            return []
        }
    }

    private static func textMarkRect(
        markKind: LayoutElement.TextMarkKind, text: String,
        origin: CGPoint, kind: ShapeItemKind, metrics: StaffMetrics, rich: LayoutRichText?,
    ) -> CGRect {
        switch markKind {
        case let .lyrics(_, _, _, _, properties):
            if let rich { return textRect(rich: rich, origin: origin, kind: .lyric) }
            return textRect(
                text: text,
                font: properties.hasFontOverride
                    ? styleFont(.lyricsOdd, overrides: properties, sp: metrics.sp)
                    : font(for: kind, metrics: metrics),
                origin: origin, anchor: .center,
            )
        case .dynamic:
            if let rich { return textRect(rich: rich, origin: origin, kind: .dynamic) }
            // Standard dynamics render as Bravura glyphs at 4 sp
            // (`TextMarkRenderer.drawDynamic`); custom text falls back
            // to the Edwin dynamics style.
            if let glyphs = DynamicSymbolMap.glyphString(for: text) {
                let f = LayoutFont(
                    face: SMuFLFamily.bravura,
                    pointSize: metrics.sp * 4,
                )
                return smuflRunRect(
                    glyphs: glyphs, font: f, origin: origin,
                )
            }
            return textRect(
                text: text, font: font(for: kind, metrics: metrics),
                origin: origin, anchor: .leadingCenter,
            )
        case let .tempo(_, _, properties):
            return textRect(
                rich: rich ?? LayoutRichText.tempoText(text, properties: properties, metrics: metrics),
                origin: origin, kind: .tempo,
            )
        }
    }

    /// Ink rect of a SMuFL glyph run drawn with a `.leadingCenter`
    /// anchor at `origin`: the typographic width (advances are right),
    /// but the glyph paths' vertical extent (the em box is not).
    ///
    /// Falls back to the em box only when *no* glyph in the run has a
    /// measurable path — an unmapped codepoint, not a platform. Both
    /// non-Apple providers return a box: `StubFontMetricsProvider` a fixed
    /// `pointSize × 0.7·pointSize` rect, and the `FontMetricsTable`
    /// provider genuine Bravura bboxes. The table provider also serves
    /// Bravura's own `ascent`/`descent` (SMFT v3), so `baselineY` lands
    /// where CoreText puts it; only the stub still answers with its
    /// 0.85 / 0.25 em formula, which sets the ink band ~1.2 sp lower than
    /// on Apple. That remaining gap is the spec's declared "text metrics
    /// out of scope" boundary for hosts that install no table.
    private static func smuflRunRect(
        glyphs: String, font: LayoutFont, origin: CGPoint,
    ) -> CGRect {
        let width = FontMetrics.provider
            .typographicWidth(text: glyphs, font: font)
        guard let ink = smuflRunInkExtent(
            glyphs: glyphs, pointSize: font.pointSize,
        ) else {
            return textRect(
                text: glyphs, font: font,
                origin: origin, anchor: .leadingCenter,
            )
        }
        let baseline = baselineY(
            font: font, originY: origin.y, anchor: .leadingCenter,
        )
        return CGRect(
            x: origin.x, y: baseline + ink.top,
            width: width, height: max(0, ink.bottom - ink.top),
        )
    }

    private static func rehearsalMarkRect(
        text: String, origin: CGPoint,
        frame: TextFrameType, properties: TextProperties, metrics: StaffMetrics, rich: LayoutRichText?,
    ) -> CGRect {
        let f = styleFont(.rehearsalMark, overrides: properties, sp: metrics.sp)
        let pad = RehearsalMarkFrame.paddingSp(sp: metrics.sp)
        let innerOrigin = CGPoint(x: origin.x + pad, y: origin.y - pad)
        let inner = rich.map { textRect(rich: $0, origin: innerOrigin, kind: .rehearsalMark) }
            ?? textRect(text: text, font: f, origin: innerOrigin, anchor: .bottomLeading)
        guard frame != .none else { return inner }
        let stroke = RehearsalMarkFrame.strokeWidthSp(sp: metrics.sp) / 2
        switch TextInkGeometry.rehearsalFrame(
            text: text, font: f, origin: origin, sp: metrics.sp, frame: frame, rich: rich,
        ) {
        case .none: return inner
        case let .rectangle(rect), let .ellipse(rect): return rect.insetBy(dx: -stroke, dy: -stroke)
        }
    }

    private static func spannerRect(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint, sp: CGFloat,
    ) -> CGRect {
        spanRect(
            from, to,
            thickness: SpannerGeometry.segmentThickness(
                kind: kind, sp: sp,
            ),
        )
    }
}
