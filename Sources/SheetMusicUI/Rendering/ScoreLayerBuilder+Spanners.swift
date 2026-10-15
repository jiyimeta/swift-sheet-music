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
        text: String, richText: LayoutRichText? = nil, lineDetail: LayoutLineDetail? = nil, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        switch kind {
        case .pedal, .textLine, .palmMute, .letRing, .chordTextLine, .hairpinLine:
            drawTextLineBase(
                kind: kind, from: from, to: to, richText: richText, lineDetail: lineDetail,
                metrics: metrics, height: height, into: parent,
            )
        case .slur, .volta, .hairpinOpen, .hairpinClose, .ottava:
            drawMarkSpanner(
                kind: kind, from: from, to: to, continuesLeft: continuesLeft, continuesRight: continuesRight,
                richText: richText, lineDetail: lineDetail, metrics: metrics, height: height, into: parent,
            )
        case .vibrato, .trill, .gradualTempoChange:
            drawLineSpanner(
                kind: kind, from: from, to: to, continuesLeft: continuesLeft, text: text, richText: richText,
                metrics: metrics, height: height, into: parent,
            )
        }
    }

    /// The kinds drawn as a shape of their own: slur, volta, hairpins, pedal and ottava.
    private static func drawMarkSpanner(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint,
        continuesLeft: Bool, continuesRight: Bool,
        richText: LayoutRichText?, lineDetail: LayoutLineDetail?,
        metrics: StaffMetrics,
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
                richText: richText,
                metrics: metrics, height: height, into: parent,
            )
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                from: from, to: to,
                open: kind == .hairpinOpen,
                richText: richText, endRichText: lineDetail?.endRichText,
                metrics: metrics, height: height, into: parent,
            )
        case let .ottava(subtype, numbersOnly):
            drawOttava(
                from: from, to: to, subtype: subtype,
                numbersOnly: numbersOnly,
                metrics: metrics, height: height, into: parent,
            )
        case .pedal, .textLine, .palmMute, .letRing, .chordTextLine, .hairpinLine, .vibrato, .trill,
             .gradualTempoChange:
            break // `drawLineSpanner` and `drawTextLineBase`
        }
    }

    /// The kinds drawn along a line: vibrato, trill and the gradual tempo change.
    private static func drawLineSpanner(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint,
        continuesLeft: Bool,
        text: String, richText: LayoutRichText?, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        switch kind {
        case .slur, .volta, .hairpinOpen, .hairpinClose, .hairpinLine, .ottava,
             .pedal, .textLine, .palmMute, .letRing, .chordTextLine:
            break // `drawMarkSpanner` and `drawTextLineBase`
        case let .vibrato(type):
            drawVibrato(
                from: from, to: to, type: type,
                metrics: metrics, height: height, into: parent,
            )
        case let .trill(type):
            drawTrill(
                from: from, to: to, type: type,
                continuesLeft: continuesLeft,
                metrics: metrics, height: height, into: parent,
            )
        case .gradualTempoChange:
            drawGradualTempoChange(
                from: from, to: to, richText: richText, metrics: metrics, height: height, into: parent,
            )
        }
    }

    private static func drawTrill(
        from: CGPoint, to: CGPoint, type: TrillType,
        continuesLeft: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
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
            guard let scalar = UnicodeScalar(codepoint),
                  let layer = glyphLayer(
                      Character(scalar), at: origin,
                      size: metrics.glyphFontSize,
                      anchor: CGPoint(x: 0, y: 0.5),
                      height: height,
                  )
            else { continue }
            parent.addSublayer(layer)
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
        richText: LayoutRichText?,
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
        let origin = SpannerGeometry.voltaLabelOrigin(from: from, to: to, sp: metrics.sp)
        let anchor = CGPoint(x: 0, y: 0.5)
        // The label is the segment's typeset text: authored, or the endings label layout synthesized. Only a segment
        // that carries none (hand-built) falls back to the endings here, and never in addition to authored text.
        let layer: CAShapeLayer? = if let richText {
            richTextLayer(richText, at: origin, anchor: anchor, color: inkColor, height: height)
        } else if !continuesLeft, let text = SpannerGeometry.voltaLabelText(endings: endings) {
            textLayer(
                text: text, at: origin, size: metrics.sp * SpannerGeometry.voltaLabelSizeSp, italic: false,
                anchor: anchor, height: height,
            )
        } else {
            nil
        }
        if let layer { parent.addSublayer(layer) }
    }

    private static func drawHairpin(
        from: CGPoint, to: CGPoint, open: Bool, richText: LayoutRichText?, endRichText: LayoutRichText?,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let wedge = SpannerGeometry.wedgeText(
            from: from, to: to, begin: richText, end: endRichText, sp: metrics.sp,
        )
        let anchor = LayoutRichText.anchor(for: .lineLabel)
        for case let (label?, origin?) in [(richText, wedge.beginOrigin), (endRichText, wedge.endOrigin)] {
            if let layer = richTextLayer(label, at: origin, anchor: anchor, color: inkColor, height: height) {
                parent.addSublayer(layer)
            }
        }
        let segs = SpannerGeometry.hairpin(
            from: wedge.from, to: wedge.to, open: open, sp: metrics.sp,
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

    private static func drawOttava(
        from: CGPoint, to: CGPoint,
        subtype: Spanner.OttavaPayload.Subtype,
        numbersOnly: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let parts = SpannerGeometry.ottava(
            from: from, to: to, sp: metrics.sp, subtype: subtype,
            numbersOnly: numbersOnly,
        )
        if let scalar = UnicodeScalar(parts.labelCodepoint),
           let layer = glyphLayer(
               Character(scalar), at: parts.labelOrigin,
               size: metrics.glyphFontSize,
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
}
