// swiftlint:disable file_length
import CoreText
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
    // MARK: - Fermata

    static func drawFermata(
        subtype: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let codepoint = FermataGlyph.codepoint(forSubtype: subtype)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Breath

    static func drawBreath(
        kind: Breath.Kind, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let codepoint = BreathGlyph.codepoint(forKind: kind)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Articulation

    static func drawArticulation(
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let glyph = ArticulationRenderer.glyph(
            kind: kind, isAbove: isAbove,
        )
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Measure repeat

    static func drawMeasureRepeat(
        count: Int, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let codepoint = MeasureRepeatGlyph.codepoint(forCount: count)
        // swiftlint:disable:next force_unwrapping
        let glyph = Character(UnicodeScalar(codepoint)!)
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Multi-measure rest

    /// Draws the multi-measure-rest H-bar glyph (SMuFL `restHBar`) at
    /// the supplied origin (horizontal center of the measure, vertical
    /// middle of the top staff) plus the run-length count rendered as
    /// bold tempo-style text directly above. v1 uses a single
    /// `restHBar` glyph at native size; future tuning may scale or
    /// stack multiple glyphs to fill wider bars.
    static func drawMultiMeasureRest(
        count: Int, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        if let bar = glyphLayer(
            SMuFLGlyph.restHBar, at: origin,
            size: metrics.glyphFontSize,
            height: height,
        ) {
            parent.addSublayer(bar)
        }
        // count == 0 means "draw the bar glyph only, no count number".
        // Lower staves in a multi-staff system use this to get the H-bar
        // without duplicating the run-length label above each staff.
        guard count > 0 else { return }
        let style = ResolvedTextStyle.resolve(
            .tempo, metrics: metrics,
        )
        let countOrigin = CGPoint(
            x: origin.x,
            y: origin.y - metrics.sp * 2.5,
        )
        if let text = textLayer(
            text: String(count),
            at: countOrigin,
            size: style.pointSize,
            italic: style.isItalic,
            anchor: CGPoint(x: 0.5, y: 0.5),
            font: style.ctFont,
            height: height,
        ) {
            parent.addSublayer(text)
        }
    }

    // MARK: - Arpeggio

    static func drawArpeggio(
        top: CGPoint, bottom: CGPoint, subtype: String?,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        // SMuFL wiggle/arrow glyphs are drawn horizontally; vertical
        // arpeggios rotate each segment -90° around its anchor.
        // Mirrors MuseScore's `Arpeggio::draw` (`painter->rotate(-90)`).
        let rotation: CGFloat = -.pi / 2
        let segments = ArpeggioGeometry.segments(
            top: top, bottom: bottom,
            subtype: subtype, sp: metrics.sp,
        )
        for segment in segments {
            // swiftlint:disable:next force_unwrapping
            let glyph = Character(UnicodeScalar(segment.codepoint)!)
            if let layer = glyphLayer(
                glyph,
                at: segment.origin,
                size: metrics.glyphFontSize,
                rotation: rotation,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Tuplet

    static func drawTuplet( // swiftlint:disable:this function_body_length
        from: CGPoint, to: CGPoint, text: String,
        hasBracket: Bool, isAbove: Bool,
        tupletID: TupletID?,
        metrics: StaffMetrics, height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer,
    ) {
        let fontSize = metrics.sp * 2
        let labelX = (from.x + to.x) / 2
        let labelY = (from.y + to.y) / 2
        if let layer = textLayer(
            text: text,
            at: CGPoint(x: labelX, y: labelY),
            size: fontSize, italic: true,
            anchor: CGPoint(x: 0.5, y: 0.5),
            height: height,
        ) {
            parent.addSublayer(layer)
            if let tid = tupletID {
                context.attach(layer, to: .tuplet(tid))
            }
        }
        guard hasBracket else { return }
        let labelHalfWidth = fontSize * 0.4
        let hook = metrics.sp * 0.8
        let hookSign: CGFloat = isAbove ? 1 : -1
        let hookDy = hook * hookSign
        let lineWidth = metrics.sp * 0.12

        for endpoint in [from, to] {
            let p = CGMutablePath()
            p.move(to: CGPoint(
                x: endpoint.x,
                y: endpoint.y + hookDy,
            ))
            p.addLine(to: endpoint)
            let layer = strokeLayer(
                path: p, height: height, lineWidth: lineWidth,
            )
            parent.addSublayer(layer)
            if let tid = tupletID {
                context.attach(layer, to: .tuplet(tid))
            }
        }
        let leftSeg = CGMutablePath()
        leftSeg.move(to: from)
        leftSeg.addLine(to: CGPoint(
            x: labelX - labelHalfWidth,
            y: interpY(
                from: from, to: to,
                x: labelX - labelHalfWidth,
            ),
        ))
        let leftLayer = strokeLayer(
            path: leftSeg, height: height, lineWidth: lineWidth,
        )
        parent.addSublayer(leftLayer)
        if let tid = tupletID {
            context.attach(leftLayer, to: .tuplet(tid))
        }
        let rightSeg = CGMutablePath()
        rightSeg.move(to: CGPoint(
            x: labelX + labelHalfWidth,
            y: interpY(
                from: from, to: to,
                x: labelX + labelHalfWidth,
            ),
        ))
        rightSeg.addLine(to: to)
        let rightLayer = strokeLayer(
            path: rightSeg, height: height, lineWidth: lineWidth,
        )
        parent.addSublayer(rightLayer)
        if let tid = tupletID {
            context.attach(rightLayer, to: .tuplet(tid))
        }
    }

    private static func interpY(
        from: CGPoint, to: CGPoint, x: CGFloat,
    ) -> CGFloat {
        let span = to.x - from.x
        guard abs(span) > 0.01 else { return from.y }
        let t = (x - from.x) / span
        return from.y + (to.y - from.y) * t
    }

    // MARK: - Marker

    static func drawMarker(
        kind: Marker.Kind, text: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        switch MarkerGlyph.variant(for: kind, text: text) {
        case let .glyph(codepoint):
            // swiftlint:disable:next force_unwrapping
            let glyph = Character(UnicodeScalar(codepoint)!)
            if let layer = glyphLayer(
                glyph, at: origin,
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        case let .text(label):
            if let layer = textLayer(
                text: label, at: origin,
                size: NotationTextStyle.fontSize(
                    for: .markerText, sp: metrics.sp,
                ),
                italic: NotationTextStyle.isItalic(for: .markerText),
                anchor: CGPoint(x: 0, y: 0.5),
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Rehearsal mark

    static func drawRehearsalMark( // swiftlint:disable:this function_body_length
        text: String, origin: CGPoint,
        frame: TextFrameType, color: CGColor,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        guard !text.isEmpty else { return }
        // MuseScore `Sid::rehearsalMarkFontSize` = 14 pt with
        // `FontSpatiumDependent = true`; resolved through
        // `TextStyleType.rehearsalMark` (Edwin 14 pt bold).
        let style = ResolvedTextStyle.resolve(
            .rehearsalMark, metrics: metrics,
        )
        let textSize = style.pointSize
        let font = style.ctFont

        // Measure the text via CTLine so we know the frame's
        // typographic bounds. Bounding the path's ink would clip the
        // descender on letters like "g", and CJK glyphs (e.g. "サビ")
        // exceed any single-row ascent/descent estimate.
        let attr = NSAttributedString(
            string: text, attributes: [.font: font],
        )
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(
            line, &ascent, &descent, &leading,
        ))
        let textWidth = max(advance, textSize * 0.5)
        let textHeight = ascent + descent

        let pad = RehearsalMarkFrame.paddingSp(sp: metrics.sp)
        let textOrigin = CGPoint(
            x: origin.x + pad, y: origin.y - pad,
        )

        if let layer = textLayer(
            text: text, at: textOrigin,
            size: textSize, italic: style.isItalic,
            anchor: CGPoint(x: 0, y: 1),
            color: color,
            font: font,
            height: height,
        ) {
            parent.addSublayer(layer)
        }

        let boxRect = RehearsalMarkFrame.boxRect(
            textWidth: textWidth, textHeight: textHeight,
            origin: origin, pad: pad,
        )
        let lineWidth = RehearsalMarkFrame.strokeWidthSp(sp: metrics.sp)
        let framePath: CGPath?
        switch RehearsalMarkFrame.shape(for: frame, around: boxRect) {
        case .none:
            framePath = nil
        case let .rectangle(rect):
            framePath = CGPath(rect: rect, transform: nil)
        case let .ellipse(rect):
            framePath = CGPath(ellipseIn: rect, transform: nil)
        }
        if let fp = framePath {
            parent.addSublayer(strokeLayer(
                path: fp, height: height,
                lineWidth: lineWidth, color: color,
            ))
        }
    }
}
