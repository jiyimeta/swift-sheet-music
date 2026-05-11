// swiftlint:disable function_body_length file_length
import CoreText
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    // MARK: - Fermata

    static func drawFermata(
        subtype: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let below = subtype.hasPrefix("fermataBelow")
        let glyph = below
            ? SMuFLGlyph.fermataBelow
            : SMuFLGlyph.fermataAbove
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
        let glyph: Character
        switch count {
        case 1: glyph = SMuFLGlyph.repeat1Bar
        case 2: glyph = SMuFLGlyph.repeat2Bars
        case 4: glyph = SMuFLGlyph.repeat4Bars
        default: glyph = SMuFLGlyph.repeat1Bar
        }
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
        let x = top.x - metrics.sp * 1.5
        var y = top.y
        while y <= bottom.y {
            if let layer = glyphLayer(
                SMuFLGlyph.arpeggioWiggle,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
                rotation: rotation,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
            y += metrics.sp
        }
        switch subtype {
        case "up":
            if let layer = glyphLayer(
                SMuFLGlyph.arpeggioUpArrow,
                at: CGPoint(x: x, y: top.y - metrics.sp),
                size: metrics.glyphFontSize,
                rotation: rotation,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        case "down":
            if let layer = glyphLayer(
                SMuFLGlyph.arpeggioDownArrow,
                at: CGPoint(x: x, y: bottom.y + metrics.sp),
                size: metrics.glyphFontSize,
                rotation: rotation,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        default:
            break
        }
    }

    // MARK: - Tuplet

    static func drawTuplet(
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
        switch kind {
        case .segno, .varsegno:
            if let layer = glyphLayer(
                SMuFLGlyph.segno, at: origin,
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        case .coda, .varcoda, .codetta, .toCodaSym:
            if let layer = glyphLayer(
                SMuFLGlyph.coda, at: origin,
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        case .fine, .toCoda, .daCapo, .dalSegno, .other:
            let label = text.isEmpty
                ? fallbackMarkerLabel(for: kind) : text
            if let layer = textLayer(
                text: label, at: origin,
                size: metrics.sp * 2.5, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Rehearsal mark

    static func drawRehearsalMark(
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

        // MuseScore `Sid::rehearsalMarkFramePadding` = 0.5 sp inside
        // the box on every side; `Sid::rehearsalMarkFrameWidth` =
        // 0.16 sp stroke.
        let pad = metrics.sp * 0.5
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

        // Frame box around the text. y grows downward in layout
        // coords, so the box's top is `origin.y - 2*pad - textHeight`
        // and its bottom is `origin.y`.
        let boxRect = CGRect(
            x: origin.x,
            y: origin.y - 2 * pad - textHeight,
            width: textWidth + 2 * pad,
            height: textHeight + 2 * pad,
        )
        let lineWidth = metrics.sp * 0.16
        let framePath: CGPath?
        switch frame {
        case .none:
            framePath = nil
        case .rectangle:
            framePath = CGPath(rect: boxRect, transform: nil)
        case .circle:
            // Inscribe the text in a circle whose diameter matches
            // the larger of the box's two sides — letterbox-friendly
            // for short labels ("A") and short-and-wide ("1サビ")
            // alike.
            let diameter = max(boxRect.width, boxRect.height)
            let cx = boxRect.midX
            let cy = boxRect.midY
            framePath = CGPath(
                ellipseIn: CGRect(
                    x: cx - diameter / 2,
                    y: cy - diameter / 2,
                    width: diameter,
                    height: diameter,
                ),
                transform: nil,
            )
        }
        if let fp = framePath {
            parent.addSublayer(strokeLayer(
                path: fp, height: height,
                lineWidth: lineWidth, color: color,
            ))
        }
    }

    private static func fallbackMarkerLabel(
        for kind: Marker.Kind,
    ) -> String {
        switch kind {
        case .fine: "Fine"
        case .toCoda: "To Coda"
        case .daCapo: "D.C."
        case .dalSegno: "D.S."
        case .other: ""
        default: ""
        }
    }
}
