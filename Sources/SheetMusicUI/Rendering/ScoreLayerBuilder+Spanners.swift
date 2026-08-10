import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    // MARK: - Spanners

    static func drawSpanner(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint,
        continuesLeft: Bool, continuesRight: Bool,
        text: String, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        switch kind {
        case .slur:
            drawSlur(
                from: from, to: to,
                metrics: metrics, height: height, into: parent,
            )
        case let .volta(endings):
            drawVolta(
                from: from, to: to, endings: endings,
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                metrics: metrics, height: height, into: parent,
            )
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                from: from, to: to,
                open: kind == .hairpinOpen,
                metrics: metrics, height: height, into: parent,
            )
        case let .hairpinLine(crescendo):
            drawHairpinLine(
                from: from, to: to, crescendo: crescendo,
                metrics: metrics, height: height, into: parent,
            )
        case .pedal:
            drawPedal(
                from: from, to: to,
                metrics: metrics, height: height, into: parent,
            )
        case let .ottava(subtype):
            drawOttava(
                from: from, to: to, subtype: subtype,
                metrics: metrics, height: height, into: parent,
            )
        case .textLine:
            drawTextLine(
                from: from, to: to, text: text,
                metrics: metrics, height: height, into: parent,
            )
        case let .vibrato(type):
            drawVibrato(
                from: from, to: to, type: type,
                metrics: metrics, height: height, into: parent,
            )
        }
    }

    private static func drawSlur(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let control = SpannerGeometry.slurControlPoint(
            from: from, to: to, sp: metrics.sp,
        )
        let p = CGMutablePath()
        p.move(to: from)
        p.addQuadCurve(to: to, control: control)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * SpannerGeometry.strokeThicknessSp,
        ))
    }

    private static func drawVolta(
        from: CGPoint, to: CGPoint,
        endings: [Int],
        continuesLeft: Bool, continuesRight: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let pts = SpannerGeometry.voltaBracketPoints(
            from: from, to: to,
            continuesLeft: continuesLeft,
            continuesRight: continuesRight,
            sp: metrics.sp,
        )
        let p = CGMutablePath()
        if let first = pts.first {
            p.move(to: first)
            for pt in pts.dropFirst() {
                p.addLine(to: pt)
            }
        }
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * SpannerGeometry.strokeThicknessSp,
        ))
        if let label = SpannerGeometry.voltaLabel(
            from: from, to: to, endings: endings,
            continuesLeft: continuesLeft, sp: metrics.sp,
        ),
            let layer = textLayer(
                text: label.text,
                at: label.origin,
                size: metrics.sp * label.sizeSp, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height,
            )
        {
            parent.addSublayer(layer)
        }
    }

    private static func drawHairpin(
        from: CGPoint, to: CGPoint, open: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let segs = SpannerGeometry.hairpin(
            from: from, to: to, open: open, sp: metrics.sp,
        )
        let p = CGMutablePath()
        p.move(to: segs.upperFrom)
        p.addLine(to: segs.upperTo)
        p.move(to: segs.lowerFrom)
        p.addLine(to: segs.lowerTo)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * SpannerGeometry.strokeThicknessSp,
        ))
    }

    private static func drawHairpinLine(
        from: CGPoint, to: CGPoint, crescendo: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let parts = SpannerGeometry.hairpinLine(
            from: from, to: to, crescendo: crescendo, sp: metrics.sp,
        )
        if let layer = textLayer(
            text: parts.label, at: parts.labelOrigin,
            size: metrics.sp * parts.labelSizeSp, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height,
        ) {
            parent.addSublayer(layer)
        }
        guard parts.lineEnd.x > parts.lineStart.x else { return }
        let p = CGMutablePath()
        p.move(to: parts.lineStart)
        p.addLine(to: parts.lineEnd)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * parts.lineThicknessSp,
            dashPattern: parts.dashPattern.map { NSNumber(value: Double($0)) },
        ))
    }

    private static func drawPedal(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        // MuseScore pedal marks are SMuFL glyphs from the music
        // font: `keyboardPedalPed` (U+E650) and `keyboardPedalUp`
        // (U+E655), rendered at music-symbol size (1 em = 4 sp).
        let parts = SpannerGeometry.pedal(from: from, to: to)
        // swiftlint:disable:next force_unwrapping
        let down = Character(UnicodeScalar(parts.downCodepoint)!)
        // swiftlint:disable:next force_unwrapping
        let up = Character(UnicodeScalar(parts.upCodepoint)!)
        if let layer = glyphLayer(
            down, at: parts.downOrigin,
            size: metrics.glyphFontSize,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height,
        ) {
            parent.addSublayer(layer)
        }
        if let layer = glyphLayer(
            up, at: parts.upOrigin,
            size: metrics.glyphFontSize,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }

    private static func drawOttava(
        from: CGPoint, to: CGPoint,
        subtype: Spanner.OttavaPayload.Subtype,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let parts = SpannerGeometry.ottava(
            from: from, to: to, sp: metrics.sp, subtype: subtype,
        )
        if let layer = textLayer(
            text: parts.label, at: parts.labelOrigin,
            size: metrics.sp * parts.labelSizeSp, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height,
        ) {
            parent.addSublayer(layer)
        }
        let p = CGMutablePath()
        p.move(to: parts.lineStart)
        p.addLine(to: parts.lineEnd)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * parts.lineThicknessSp,
            dashPattern: parts.dashPattern.map { NSNumber(value: Double($0)) },
        ))
    }

    private static func drawVibrato(
        from: CGPoint, to: CGPoint,
        type: VibratoType,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
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
            if let layer = glyphLayer(
                ch, at: origin,
                size: metrics.glyphFontSize,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func drawTextLine(
        from: CGPoint, to: CGPoint, text: String,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let parts = SpannerGeometry.textLine(
            from: from, to: to, text: text, sp: metrics.sp,
        )
        if !parts.label.isEmpty,
           let layer = textLayer(
               text: parts.label, at: parts.labelOrigin,
               size: metrics.sp * parts.labelSizeSp, italic: true,
               anchor: CGPoint(x: 0, y: 0.5),
               height: height,
           )
        {
            parent.addSublayer(layer)
        }
        let p = CGMutablePath()
        p.move(to: parts.lineStart)
        p.addLine(to: parts.lineEnd)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * parts.lineThicknessSp,
        ))
    }

    // MARK: - Tie arc

    static func drawTieArc(
        from: CGPoint, to: CGPoint, above: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let headClearance = metrics.sp * 0.6
        let vertSign: CGFloat = above ? -1 : 1
        let startPt = CGPoint(
            x: from.x,
            y: from.y + headClearance * vertSign,
        )
        let endPt = CGPoint(
            x: to.x,
            y: to.y + headClearance * vertSign,
        )

        let minShoulder = metrics.sp * 0.3
        let maxShoulder = metrics.sp * 2.0
        let tieLen = abs(endPt.x - startPt.x)
        let tieLenSp = max(tieLen / metrics.sp, 1.0)
        let shoulderH: CGFloat = {
            let raw = minShoulder
                + metrics.sp * 0.3 * sqrt(tieLenSp - 1)
            return min(max(raw, minShoulder), maxShoulder)
        }()
        let midThickness = metrics.sp * 0.15

        let dx = endPt.x - startPt.x
        let dy = endPt.y - startPt.y
        let ctrl1 = CGPoint(
            x: startPt.x + dx * 0.2,
            y: startPt.y + dy * 0.2 + shoulderH * vertSign,
        )
        let ctrl2 = CGPoint(
            x: startPt.x + dx * 0.8,
            y: startPt.y + dy * 0.8 + shoulderH * vertSign,
        )
        let thickDy = midThickness * vertSign * -1

        let path = CGMutablePath()
        path.move(to: startPt)
        path.addCurve(
            to: endPt,
            control1: CGPoint(x: ctrl1.x, y: ctrl1.y - thickDy),
            control2: CGPoint(x: ctrl2.x, y: ctrl2.y - thickDy),
        )
        path.addCurve(
            to: startPt,
            control1: CGPoint(x: ctrl2.x, y: ctrl2.y + thickDy),
            control2: CGPoint(x: ctrl1.x, y: ctrl1.y + thickDy),
        )
        path.closeSubpath()
        parent.addSublayer(fillLayer(
            path: path, height: height,
        ))
    }

    // MARK: - Tremolo bars

    /// CALayer companion to `TremoloRenderer.draw`. Same geometry,
    /// rendered as stroked `CAShapeLayer`s instead of GraphicsContext
    /// paths.
    static func drawTremoloBars(
        anchor: TremoloAnchor, barCount: Int,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let bars = TremoloGeometry.bars(
            anchor: anchor, barCount: barCount, sp: metrics.sp,
        )
        guard !bars.isEmpty else { return }
        let thickness = TremoloGeometry.barThickness(sp: metrics.sp)
        for bar in bars {
            let path = CGMutablePath()
            path.move(to: bar.from)
            path.addLine(to: bar.to)
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: thickness,
            ))
        }
    }
}
