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
                metrics: metrics,
            )
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                context: &context, from: from, to: to,
                open: kind == .hairpinOpen, metrics: metrics,
            )
        case .pedal:
            drawPedal(
                context: &context, from: from, to: to, metrics: metrics,
            )
        case .ottava:
            drawOttava(
                context: &context, from: from, to: to,
                metrics: metrics,
            )
        case .textLine:
            drawTextLine(
                context: &context, from: from, to: to,
                text: text, metrics: metrics,
            )
        case let .vibrato(type):
            drawVibrato(
                context: &context, from: from, to: to,
                type: type, metrics: metrics,
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
        if let label = SpannerGeometry.voltaLabel(
            from: from, to: to, endings: endings,
            continuesLeft: continuesLeft, sp: metrics.sp,
        ) {
            context.drawExpressionText(
                label.text,
                at: label.origin,
                size: metrics.sp * label.sizeSp,
                italic: false,
            )
        }
    }

    private static func drawHairpin(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        open: Bool, metrics: StaffMetrics,
    ) {
        let segs = SpannerGeometry.hairpin(
            from: from, to: to, open: open, sp: metrics.sp,
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

    private static func drawPedal(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics,
    ) {
        // MuseScore renders pedal marks as SMuFL glyphs from the
        // music font: `keyboardPedalPed` (U+E650) for the "Ped."
        // sigil and `keyboardPedalUp` (U+E655) for the closing
        // "*" / asterisk.
        let parts = SpannerGeometry.pedal(from: from, to: to)
        // swiftlint:disable:next force_unwrapping
        let down = Character(UnicodeScalar(parts.downCodepoint)!)
        // swiftlint:disable:next force_unwrapping
        let up = Character(UnicodeScalar(parts.upCodepoint)!)
        context.drawGlyph(
            down, at: parts.downOrigin,
            size: metrics.glyphFontSize, anchor: .leading,
        )
        context.drawGlyph(
            up, at: parts.upOrigin,
            size: metrics.glyphFontSize, anchor: .leading,
        )
    }

    private static func drawOttava(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics,
    ) {
        let parts = SpannerGeometry.ottava(
            from: from, to: to, sp: metrics.sp,
        )
        context.drawExpressionText(
            parts.label, at: parts.labelOrigin,
            size: metrics.sp * parts.labelSizeSp, italic: true,
        )
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

    private static func drawTextLine(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        text: String, metrics: StaffMetrics,
    ) {
        let parts = SpannerGeometry.textLine(
            from: from, to: to, text: text, sp: metrics.sp,
        )
        if !parts.label.isEmpty {
            context.drawExpressionText(
                parts.label, at: parts.labelOrigin,
                size: metrics.sp * parts.labelSizeSp, italic: true,
            )
        }
        var p = Path()
        p.move(to: parts.lineStart)
        p.addLine(to: parts.lineEnd)
        context.stroke(
            p, with: .color(.primary),
            lineWidth: metrics.sp * parts.lineThicknessSp,
        )
    }
}
