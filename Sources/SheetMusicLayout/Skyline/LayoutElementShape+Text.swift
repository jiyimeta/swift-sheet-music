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
    /// Ink rect of `text` typeset in `font`, positioned per `anchor`.
    static func textRect(
        text: String, font: LayoutFont,
        origin: CGPoint, anchor: TextAnchorConvention,
    ) -> CGRect {
        let provider = FontMetrics.provider
        let width = provider.typographicWidth(text: text, font: font)
        let height = provider.ascent(font: font)
            + provider.descent(font: font)
        switch anchor {
        case .leadingCenter:
            return CGRect(
                x: origin.x, y: origin.y - height / 2,
                width: width, height: height,
            )
        case .bottomLeading:
            return CGRect(
                x: origin.x, y: origin.y - height,
                width: width, height: height,
            )
        case .center:
            return CGRect(
                x: origin.x - width / 2, y: origin.y - height / 2,
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
        case .marker:
            return LayoutFont(
                face: "Edwin",
                pointSize: NotationTextStyle.fontSize(
                    for: .markerText, sp: sp,
                ),
            )
        case .jump:
            return LayoutFont(
                face: "Edwin",
                pointSize: NotationTextStyle.fontSize(for: .jump, sp: sp),
            )
        default:
            return styleFont(.staffText, sp: sp)
        }
    }

    private static func styleFont(
        _ style: TextStyleType, sp: CGFloat,
    ) -> LayoutFont {
        LayoutFont(
            face: style.museScoreDefault.face,
            pointSize: TextRoleStyle.fontSize(for: style, sp: sp),
        )
    }

    /// Rects for the elements the skyline pass is allowed to move.
    static func autoplacedRects( // swiftlint:disable:this cyclomatic_complexity
        for element: LayoutElement,
        kind: ShapeItemKind, metrics: StaffMetrics,
    ) -> [CGRect] {
        let sp = metrics.sp
        switch element {
        case let .textMark(markKind, text, origin):
            return [textMarkRect(
                markKind: markKind, text: text, origin: origin,
                kind: kind, metrics: metrics,
            )]
        case let .staffText(text, origin, _, _):
            return [textRect(
                text: text, font: font(for: kind, metrics: metrics),
                origin: origin, anchor: .bottomLeading,
            )]
        case let .measureNumber(text, origin):
            return [textRect(
                text: text, font: font(for: kind, metrics: metrics),
                origin: origin, anchor: .bottomLeading,
            )]
        case let .marker(_, text, origin), let .jump(text, origin):
            return [textRect(
                text: text, font: font(for: kind, metrics: metrics),
                origin: origin, anchor: .leadingCenter,
            )]
        case let .rehearsalMark(text, origin, frame, _):
            return [rehearsalMarkRect(
                text: text, origin: origin, frame: frame,
                metrics: metrics,
            )]
        case let .harmony(lh):
            let f = font(for: .harmony, metrics: metrics)
            let provider = FontMetrics.provider
            let height = provider.ascent(font: f)
                + provider.descent(font: f)
            return [CGRect(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y) - height / 2,
                width: max(CGFloat(lh.width), sp),
                height: height,
            )]
        case let .lyricsMelisma(from, to), let .lyricHyphen(from, to):
            return [spanRect(from, to, thickness: sp * 0.3)]
        case let .spannerSegment(spannerKind, from, to, _, _, _):
            return [spannerRect(
                kind: spannerKind, from: from, to: to, sp: sp,
            )]
        default:
            return []
        }
    }

    private static func textMarkRect(
        markKind: LayoutElement.TextMarkKind, text: String,
        origin: CGPoint, kind: ShapeItemKind, metrics: StaffMetrics,
    ) -> CGRect {
        switch markKind {
        case .lyrics:
            return textRect(
                text: text, font: font(for: kind, metrics: metrics),
                origin: origin, anchor: .center,
            )
        case .dynamic:
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
        case .tempo:
            return tempoRect(
                text: text, origin: origin, metrics: metrics,
            )
        }
    }

    /// Ink rect of a SMuFL glyph run drawn with a `.leadingCenter`
    /// anchor at `origin`: the typographic width (advances are right),
    /// but the glyph paths' vertical extent (the em box is not).
    ///
    /// Falls back to the em box only when *no* glyph in the run has a
    /// measurable path — an unmapped codepoint, not a platform. Both
    /// Android providers return a box: `StubFontMetricsProvider` a fixed
    /// `pointSize × 0.7·pointSize` rect, and the JNI
    /// `SMuFLMetricsTable` provider genuine Bravura bboxes. What Android
    /// *does* get wrong is the baseline, not the extent: both providers
    /// take `ascent`/`descent` from the stub (0.85 / 0.25 em), so
    /// `baselineY` returns `originY + 0.3 · pointSize` and the ink band
    /// sits ~1.2 sp lower than on Apple. That is the spec's declared
    /// "Android text metrics out of scope" boundary.
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

    /// Tempo is a mixed Bravura + Edwin run list; sum the run widths
    /// the way the renderers advance their cursor.
    ///
    /// Mirrors `ScoreLayerBuilder+Element`'s CALayer tempo path — the
    /// one `ScoreView` actually renders through — which draws the beat
    /// glyph via `bravuraInkCenteredLayer`, i.e. with the glyph's **ink
    /// box centred on `origin.y`**. It deliberately does *not* mirror
    /// `TextMarkRenderer.drawTempo`, whose Canvas path anchors every run
    /// `.leading` on `origin.y`; the two renderers disagree on the beat
    /// glyph's Y and the CALayer one is production.
    private static func tempoRect(
        text: String, origin: CGPoint, metrics: StaffMetrics,
    ) -> CGRect {
        let textFont = font(for: .tempo, metrics: metrics)
        let glyphFont = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: textFont.pointSize,
        )
        let provider = FontMetrics.provider
        let runs = MusicTextRuns.runs(in: text)
        var width: CGFloat = 0
        for run in runs {
            let f = run.kind == .musicSymbol ? glyphFont : textFont
            width += provider.typographicWidth(text: run.text, font: f)
        }
        // Edwin's em box is a fair stand-in for its own ink, so the
        // text half of the run keeps it. The Bravura half must NOT —
        // its em box is 4 em (see `smuflRunInkExtent`), which at the
        // tempo size is 68 pt of skyline against ~14 pt of metronome
        // glyph. Union the text box with the glyphs' measured ink,
        // centred on `origin.y` exactly as the CALayer renderer draws
        // it. Offsetting the ink by the *Edwin* baseline (as an earlier
        // revision did) drops the band ~0.57 sp — more than the pass's
        // whole 0.5 sp `minVerticalDistance` budget.
        let textHeight = provider.ascent(font: textFont)
            + provider.descent(font: textFont)
        var top = origin.y - textHeight / 2
        var bottom = origin.y + textHeight / 2
        let glyphs = runs
            .filter { $0.kind == .musicSymbol }
            .map(\.text).joined()
        if let ink = smuflRunInkExtent(
            glyphs: glyphs, pointSize: glyphFont.pointSize,
        ) {
            let inkHeight = max(0, ink.bottom - ink.top)
            top = min(top, origin.y - inkHeight / 2)
            bottom = max(bottom, origin.y + inkHeight / 2)
        }
        return CGRect(
            x: origin.x, y: top,
            width: width, height: max(0, bottom - top),
        )
    }

    private static func rehearsalMarkRect(
        text: String, origin: CGPoint,
        frame: RehearsalMark.FrameKind, metrics: StaffMetrics,
    ) -> CGRect {
        let f = font(for: .rehearsalMark, metrics: metrics)
        let inner = textRect(
            text: text, font: f, origin: origin, anchor: .bottomLeading,
        )
        guard frame != .none else { return inner }
        let pad = RehearsalMarkFrame.paddingSp(sp: metrics.sp)
            + RehearsalMarkFrame.strokeWidthSp(sp: metrics.sp)
        return CGRect(
            x: inner.minX - pad, y: inner.minY - pad,
            width: inner.width + pad * 2,
            height: inner.height + pad * 2,
        )
    }

    private static func spannerRect(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint, sp: CGFloat,
    ) -> CGRect {
        let thickness: CGFloat
        switch kind {
        case .hairpinOpen, .hairpinClose:
            thickness = sp * 1.4
        case .volta:
            thickness = sp * SpannerGeometry.voltaLabelSizeSp
        case .ottava:
            thickness = sp * SpannerGeometry.ottavaLabelSizeSp
        case .textLine:
            thickness = sp * SpannerGeometry.textLineLabelSizeSp
        case .pedal:
            thickness = sp * 1.5
        case .slur, .vibrato:
            thickness = sp
        }
        return spanRect(from, to, thickness: thickness)
    }
}
