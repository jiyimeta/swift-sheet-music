import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum SpannerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.SpannerKind,
        from: CGPoint,
        to: CGPoint,
        continuesLeft: Bool,
        continuesRight: Bool,
        text: String,
        richText: LayoutRichText? = nil,
        lineDetail: LayoutLineDetail? = nil,
        metrics: StaffMetrics,
    ) {
        switch kind {
        case .slur:
            drawSlur(context: &context, from: from, to: to, metrics: metrics)
        case let .volta(endings):
            drawVolta(
                context: &context, from: from, to: to,
                endings: endings,
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                richText: richText,
                metrics: metrics,
            )
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                context: &context, from: from, to: to,
                open: kind == .hairpinOpen, richText: richText, endRichText: lineDetail?.endRichText,
                metrics: metrics,
            )
        case .pedal, .textLine, .palmMute, .letRing, .chordTextLine, .hairpinLine:
            drawTextLineBase(
                context: &context, kind: kind, from: from, to: to,
                richText: richText, lineDetail: lineDetail, metrics: metrics,
            )
        case let .ottava(subtype, numbersOnly):
            drawOttava(
                context: &context, from: from, to: to,
                subtype: subtype, numbersOnly: numbersOnly,
                metrics: metrics,
            )
        case let .vibrato(type):
            drawVibrato(
                context: &context, from: from, to: to,
                type: type, metrics: metrics,
            )
        case let .trill(type):
            drawTrill(
                context: &context, from: from, to: to,
                type: type, continuesLeft: continuesLeft,
                metrics: metrics,
            )
        case .gradualTempoChange:
            drawGradualTempoChange(
                context: &context, from: from, to: to, richText: richText, endRichText: lineDetail?.endRichText,
                metrics: metrics,
            )
        }
    }

    private static func drawTrill(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        type: TrillType, continuesLeft: Bool, metrics: StaffMetrics,
    ) {
        let symbols = SpannerGeometry.trillSymbols(
            type: type, continuesLeft: continuesLeft,
        )
        let font = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: metrics.glyphFontSize,
        )
        func advance(_ codepoint: UInt32) -> CGFloat {
            guard let scalar = UnicodeScalar(codepoint) else { return 0 }
            return FontMetrics.provider.typographicWidth(
                text: String(Character(scalar)), font: font,
            )
        }
        let run = SpannerGeometry.trillGlyphRun(
            from: from, to: to, symbols: symbols,
            startAdvance: advance(symbols.start),
            fillAdvance: advance(symbols.fill),
            endAdvance: symbols.end.map(advance) ?? 0,
        )
        for (codepoint, origin) in run {
            guard let scalar = UnicodeScalar(codepoint) else { continue }
            context.drawGlyph(
                Character(scalar), at: origin,
                size: metrics.glyphFontSize, anchor: .leading,
            )
        }
    }

    private static func drawSlur(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics,
    ) {
        let control = SpannerGeometry.slurControlPoint(
            from: from, to: to, sp: metrics.sp,
        )
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: control)
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * SpannerGeometry.strokeThicknessSp,
        )
    }

    private static func drawVolta(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        endings: [Int],
        continuesLeft: Bool, continuesRight: Bool,
        richText: LayoutRichText?,
        metrics: StaffMetrics,
    ) {
        let pts = SpannerGeometry.voltaBracketPoints(
            from: from, to: to,
            continuesLeft: continuesLeft,
            continuesRight: continuesRight,
            sp: metrics.sp,
        )
        var p = Path()
        if let first = pts.first {
            p.move(to: first)
            for pt in pts.dropFirst() {
                p.addLine(to: pt)
            }
        }
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * SpannerGeometry.strokeThicknessSp,
        )
        // The label is the segment's typeset text: authored, or the endings label layout synthesized. Only a segment
        // that carries none (hand-built) falls back to the endings here, and never in addition to authored text.
        if let richText {
            TextInkRenderer.drawRich(
                context: &context, richText: richText,
                origin: SpannerGeometry.voltaLabelOrigin(from: from, to: to, label: richText, sp: metrics.sp),
                anchor: LayoutRichText.anchor(for: .lineLabel), color: .primary,
            )
        } else if !continuesLeft, let text = SpannerGeometry.voltaLabelText(endings: endings) {
            context.drawExpressionText(
                text, at: SpannerGeometry.voltaLabelOrigin(from: from, to: to, sp: metrics.sp),
                size: metrics.sp * SpannerGeometry.voltaLabelSizeSp, italic: false,
            )
        }
    }

    private static func drawHairpin(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        open: Bool, richText: LayoutRichText?, endRichText: LayoutRichText?, metrics: StaffMetrics,
    ) {
        let wedge = SpannerGeometry.wedgeText(
            from: from, to: to, begin: richText, end: endRichText, sp: metrics.sp,
        )
        let anchor = LayoutRichText.anchor(for: .lineLabel)
        for case let (label?, origin?) in [(richText, wedge.beginOrigin), (endRichText, wedge.endOrigin)] {
            TextInkRenderer.drawRich(
                context: &context, richText: label, origin: origin, anchor: anchor, color: .primary,
            )
        }
        let segs = SpannerGeometry.hairpin(
            from: wedge.from, to: wedge.to, open: open, sp: metrics.sp,
        )
        var p = Path()
        p.move(to: segs.upperFrom)
        p.addLine(to: segs.upperTo)
        p.move(to: segs.lowerFrom)
        p.addLine(to: segs.lowerTo)
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * SpannerGeometry.strokeThicknessSp,
        )
    }

    private static func drawOttava(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        subtype: Spanner.OttavaPayload.Subtype,
        numbersOnly: Bool,
        metrics: StaffMetrics,
    ) {
        let parts = SpannerGeometry.ottava(
            from: from, to: to, sp: metrics.sp, subtype: subtype,
            numbersOnly: numbersOnly,
        )
        if let scalar = UnicodeScalar(parts.labelCodepoint) {
            context.drawGlyph(
                Character(scalar), at: parts.labelOrigin,
                size: metrics.glyphFontSize, anchor: .leading,
            )
        }
        var p = Path()
        p.move(to: parts.lineStart)
        p.addLine(to: parts.lineEnd)
        context.stroke(
            p, with: .color(.primary),
            style: StrokeStyle(
                lineWidth: metrics.sp * parts.lineThicknessSp,
                dash: parts.dashPattern,
            ),
        )
    }

    private static func drawVibrato(
        context: inout GraphicsContext,
        from: CGPoint, to: CGPoint,
        type: VibratoType,
        metrics: StaffMetrics,
    ) {
        // Compute the typographic advance of one vibrato glyph so
        // SpannerGeometry can calculate how many copies fit.
        let codepoint = SpannerGeometry.vibratoCodepoint(type: type)
        // swiftlint:disable:next force_unwrapping
        let ch = Character(UnicodeScalar(codepoint)!)
        let glyphFont = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: metrics.glyphFontSize,
        )
        let advance = FontMetrics.provider.typographicWidth(
            text: String(ch), font: glyphFont,
        )
        let run = SpannerGeometry.vibratoGlyphRun(
            from: from, to: to, type: type, sp: metrics.sp, advance: advance,
        )
        for origin in run.origins {
            context.drawGlyph(ch, at: origin, size: metrics.glyphFontSize, anchor: .leading)
        }
    }
}
