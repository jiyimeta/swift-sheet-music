import Foundation
import SheetMusicCore
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Per-element encoders for the time-signature and key-signature
/// branches of `LayoutBridge.encodeElement`. Split out of the main file
/// only to keep the bridge under the per-file length cap; the helpers
/// remain `internal` and are not part of any public API.
extension LayoutBridge {
    /// Points to millimetres scale factor — same constant as
    /// `LayoutBridge.ptToMM`, re-declared here to avoid widening that
    /// constant's visibility just for this split.
    static let ptToMMScale = 25.4 / 72.0

    /// Emit a text element honoring the role's MuseScore anchor.
    /// Splits the string into Bravura-glyph runs (SMuFL PUA codepoints)
    /// and Edwin-text runs via `MusicTextRuns.runs`, advancing X across
    /// each run. The first run anchors at `originX` (adjusted by anchor
    /// offset using the total width).
    static func emitText(
        text: String,
        style: TextStyleType,
        originX: Double,
        originY: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        let textPt = TextRoleStyle.fontSize(for: style, sp: CGFloat(sp))
        // Inline music symbols (e.g. metNoteQuarterUp in a tempo) render
        // at the surrounding text's point size, NOT at the SMuFL 1-em
        // staff size — MuseScore styles them as inline glyphs so they
        // sit proportionate to the text characters.
        let glyphPt = textPt
        let runs = MusicTextRuns.runs(in: text)
        // Total advance across runs so the anchor offset is correct.
        var totalWidth: CGFloat = 0
        let measured: [(run: MusicTextRuns.Run, width: CGFloat)] = runs.map { run in
            let width = FontMetrics.provider.typographicWidth(
                text: run.text,
                font: fontFor(run: run, textPt: textPt, glyphPt: glyphPt),
            )
            totalWidth += width
            return (run, width)
        }
        let anchor = TextRoleStyle.horizontalAnchor(for: style)
        let anchorDx: Double = switch anchor {
        case .leading: 0
        case .center: -Double(totalWidth) / 2
        case .trailing: -Double(totalWidth)
        }
        var cursorX = originX + anchorDx
        for (run, width) in measured {
            switch run.kind {
            case .musicSymbol:
                out.append(.text(
                    run.text,
                    x: cursorX * ptToMMScale,
                    y: originY * ptToMMScale,
                    size: Double(glyphPt) * ptToMMScale,
                    fontId: .smufl,
                ))
            case .text:
                out.append(.text(
                    run.text,
                    x: cursorX * ptToMMScale,
                    y: originY * ptToMMScale,
                    size: Double(textPt) * ptToMMScale,
                    fontId: .textRoman,
                ))
            }
            cursorX += Double(width)
        }
    }

    private static func fontFor(
        run: MusicTextRuns.Run, textPt: CGFloat, glyphPt: CGFloat,
    ) -> LayoutFont {
        switch run.kind {
        case .musicSymbol:
            return LayoutFont(face: "Bravura", pointSize: glyphPt)
        case .text:
            return LayoutFont(face: "Edwin", pointSize: textPt)
        }
    }

    /// Emit a SMuFL glyph whose position was computed assuming Apple's
    /// `.center` anchor (typographic frame centre at `(cxPt, cyPt)`).
    /// `Canvas.drawText` on Android anchors at the baseline-leading
    /// corner; the offset comes from the glyph's typographic metrics
    /// (advance, ascent, descent) via `GlyphAnchor.centerToBaselineLeading`.
    static func emitCenterAnchoredGlyph(
        codepoint: UInt32,
        cxPt: Double,
        cyPt: Double,
        sizePt: Double,
        into out: inout [DrawCommand],
    ) {
        let font = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: CGFloat(sizePt),
        )
        guard let scalar = UnicodeScalar(codepoint) else { return }
        let advance = FontMetrics.provider.typographicWidth(
            text: String(scalar), font: font,
        )
        let (dx, dy) = GlyphAnchor.centerToBaselineLeading(advance: advance)
        out.append(.glyph(
            codepoint: codepoint,
            x: (cxPt + Double(dx)) * ptToMMScale,
            y: (cyPt + Double(dy)) * ptToMMScale,
            size: sizePt * ptToMMScale,
            fontId: .smufl,
        ))
    }

    // swiftlint:disable:next function_parameter_count
    static func encodeTimeSignature(
        numerator: Int,
        denominator: Int,
        originX: Double,
        originY: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        let advance = TimeSignatureLayout.digitAdvance(sp: CGFloat(sp))
        let (numDx, denDx, _) = TimeSignatureLayout.rowOffsets(
            numerator: numerator, denominator: denominator,
            sp: CGFloat(sp),
        )
        let numY = originY
            + Double(TimeSignatureLayout.numeratorDy(sp: CGFloat(sp)))
        let denY = originY
            + Double(TimeSignatureLayout.denominatorDy(sp: CGFloat(sp)))
        emitTimeSigRow(
            value: numerator,
            rowOriginX: originX + Double(numDx),
            rowY: numY,
            advance: Double(advance),
            glyphSize: glyphSize,
            into: &out,
        )
        emitTimeSigRow(
            value: denominator,
            rowOriginX: originX + Double(denDx),
            rowY: denY,
            advance: Double(advance),
            glyphSize: glyphSize,
            into: &out,
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func emitTimeSigRow(
        value: Int,
        rowOriginX: Double,
        rowY: Double,
        advance: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        for (i, ch) in String(value).enumerated() {
            let digit = Int(String(ch)) ?? 0
            emitCenterAnchoredGlyph(
                codepoint: SMuFLCodepoint.timeSigDigit(digit),
                cxPt: rowOriginX + Double(i) * advance,
                cyPt: rowY,
                sizePt: glyphSize,
                into: &out,
            )
        }
    }

    // MARK: - Tie arc (tessellated)

    // Approximate a tie's cubic Bezier with a 16-segment polyline so
    // the Compose wire format (which has no curve opcode) can render
    // it. Geometry shared with Apple via `TieArcGeometry`.
    // swiftlint:disable:next function_parameter_count
    static func encodeTieArc(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        above: Bool,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        // Apple's TieRenderer scales the shoulder with sqrt(tieLength)
        // up to ~2 sp; for the cross-platform helper we use a fixed
        // 1 sp shoulder. Good enough for v1 — refinement is a
        // follow-up.
        let pts = TieArcGeometry.controlPoints(
            from: CGPoint(x: CGFloat(fromX), y: CGFloat(fromY)),
            to: CGPoint(x: CGFloat(toX), y: CGFloat(toY)),
            above: above,
            heightSp: 1,
            sp: CGFloat(sp),
        )
        let steps = 16
        var prevX = Double(pts.p0.x)
        var prevY = Double(pts.p0.y)
        out.append(.moveTo(x: prevX * ptToMMScale, y: prevY * ptToMMScale))
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let pt = bezierPoint(
                t: t,
                p0: pts.p0, p1: pts.p1, p2: pts.p2, p3: pts.p3,
            )
            prevX = Double(pt.x)
            prevY = Double(pt.y)
            out.append(.lineTo(x: prevX * ptToMMScale, y: prevY * ptToMMScale))
        }
        out.append(.stroke(width: sp * 0.13 * ptToMMScale))
    }

    private static func bezierPoint(
        t: Double, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
    ) -> CGPoint {
        let u = 1 - t
        let coef0 = u * u * u
        let coef1 = 3 * u * u * t
        let coef2 = 3 * u * t * t
        let coef3 = t * t * t
        let x = coef0 * Double(p0.x) + coef1 * Double(p1.x)
            + coef2 * Double(p2.x) + coef3 * Double(p3.x)
        let y = coef0 * Double(p0.y) + coef1 * Double(p1.y)
            + coef2 * Double(p2.y) + coef3 * Double(p3.y)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    // MARK: - Tuplet bracket

    // swiftlint:disable:next function_parameter_count
    static func encodeTupletBracket(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        text: String,
        hasBracket: Bool,
        isAbove: Bool,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        let segments = TupletBracketGeometry.segments(
            from: CGPoint(x: CGFloat(fromX), y: CGFloat(fromY)),
            to: CGPoint(x: CGFloat(toX), y: CGFloat(toY)),
            isAbove: isAbove,
            sp: CGFloat(sp),
        )
        let fontSize = Double(TupletBracketGeometry.labelFontSizeSp) * sp
        // Label — emit as centred Edwin italic. The bridge's wire
        // format has no italic bit yet; falls back to the default
        // text style, matching Apple's "looks slightly off but
        // recognisable" behaviour for tuplet digits.
        let labelFont = LayoutFont(
            face: "Edwin", pointSize: CGFloat(fontSize),
        )
        let labelWidth = Double(FontMetrics.provider.typographicWidth(
            text: text, font: labelFont,
        ))
        let ascent = Double(FontMetrics.provider.ascent(font: labelFont))
        let descent = Double(FontMetrics.provider.descent(font: labelFont))
        // Canvas.drawText anchors at the baseline. The bracket geometry
        // hands back the label's visual centre Y, so shift baseline
        // down by half of (ascent − descent) to vertically centre the
        // digit on `labelCenter.y`.
        let baselineY = Double(segments.labelCenter.y) + (ascent - descent) / 2
        out.append(.text(
            text,
            x: (Double(segments.labelCenter.x) - labelWidth / 2) * ptToMMScale,
            y: baselineY * ptToMMScale,
            size: fontSize * ptToMMScale,
            fontId: .textRoman,
        ))
        guard hasBracket else { return }
        let lineWidth = Double(TupletBracketGeometry.lineThicknessSp) * sp
        emitSegment(
            segments.leftHookFrom,
            segments.leftHookTo,
            width: lineWidth,
            into: &out,
        )
        emitSegment(
            segments.rightHookFrom,
            segments.rightHookTo,
            width: lineWidth,
            into: &out,
        )
        emitSegment(
            segments.leftSegFrom,
            segments.leftSegTo,
            width: lineWidth,
            into: &out,
        )
        emitSegment(
            segments.rightSegFrom,
            segments.rightSegTo,
            width: lineWidth,
            into: &out,
        )
    }

    private static func emitSegment(
        _ from: CGPoint, _ to: CGPoint, width: Double,
        into out: inout [DrawCommand],
    ) {
        out.append(.moveTo(
            x: Double(from.x) * ptToMMScale,
            y: Double(from.y) * ptToMMScale,
        ))
        out.append(.lineTo(
            x: Double(to.x) * ptToMMScale,
            y: Double(to.y) * ptToMMScale,
        ))
        out.append(.stroke(width: width * ptToMMScale))
    }

    // MARK: - Key signature

    // swiftlint:disable:next function_parameter_count
    static func encodeKeySignature(
        sharps: Int,
        flats: Int,
        originX: Double,
        originY: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return }
        let isSharp = sharps > 0
        let codepoint = isSharp
            ? SMuFLCodepoint.accidentalSharp
            : SMuFLCodepoint.accidentalFlat
        let steps = isSharp
            ? KeySignatureSteps.sharps
            : KeySignatureSteps.flats
        let advance = Double(KeySignatureSteps.advance(sp: CGFloat(sp)))
        for i in 0 ..< min(count, steps.count) {
            let stepDy = Double(KeySignatureSteps.stepDy(
                step: steps[i], sp: CGFloat(sp),
            ))
            emitCenterAnchoredGlyph(
                codepoint: codepoint,
                cxPt: originX + Double(i) * advance,
                cyPt: originY + stepDy,
                sizePt: glyphSize,
                into: &out,
            )
        }
    }
}
