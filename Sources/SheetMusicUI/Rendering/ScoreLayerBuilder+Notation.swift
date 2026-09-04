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
    // MARK: - Clef

    @discardableResult
    static func drawClef(
        rawType: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) -> CAShapeLayer? {
        let clef = NotatedClef(rawType: rawType)
        let glyph: Character
        let yOffset: CGFloat
        switch clef {
        case .treble: glyph = SMuFLGlyph.gClef; yOffset = metrics.sp
        case .treble8va: glyph = SMuFLGlyph.gClef8va; yOffset = metrics.sp
        case .treble8vb: glyph = SMuFLGlyph.gClef8vb; yOffset = metrics.sp
        case .treble15ma: glyph = SMuFLGlyph.gClef15ma; yOffset = metrics.sp
        case .treble15mb: glyph = SMuFLGlyph.gClef15mb; yOffset = metrics.sp
        case .bass: glyph = SMuFLGlyph.fClef; yOffset = -metrics.sp
        case .bass8va: glyph = SMuFLGlyph.fClef8va; yOffset = -metrics.sp
        case .bass8vb: glyph = SMuFLGlyph.fClef8vb; yOffset = -metrics.sp
        case .soprano: glyph = SMuFLGlyph.cClef; yOffset = 2 * metrics.sp
        case .alto: glyph = SMuFLGlyph.cClef; yOffset = 0
        case .tenor: glyph = SMuFLGlyph.cClef; yOffset = -metrics.sp
        case .baritone: glyph = SMuFLGlyph.cClef; yOffset = -2 * metrics.sp
        case .percussion: glyph = SMuFLGlyph.percussionClef; yOffset = 0
        case .percussion2: glyph = SMuFLGlyph.percussionClef2; yOffset = 0
        }
        guard let layer = glyphLayer(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize,
            height: height,
        ) else {
            return nil
        }
        parent.addSublayer(layer)
        return layer
    }

    // MARK: - Key signature

    /// `naturals` are pre-resolved steps (the layout engine matched them
    /// to the clef); they are drawn FIRST, ahead of the new signature.
    static func drawKeySignature(
        sharps: Int, flats: Int, clef: NotatedClef,
        naturals: [Int] = [], origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let glyph = sharps > 0
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        // Step table and advance come from `KeySignatureSteps` so this
        // renderer, `KeySignatureRenderer` (SwiftUI) and the Android
        // draw-command bridge all place the cluster identically.
        let steps = KeySignatureSteps.steps(
            sharps: sharps, flats: flats, clef: clef,
        )
        let advance = KeySignatureSteps.advance(sp: metrics.sp)
        let run = naturals.map { ($0, SMuFLGlyph.accidentalNatural) }
            + steps.map { ($0, glyph) }
        for (i, entry) in run.enumerated() {
            let x = origin.x + CGFloat(i) * advance
            let y = origin.y + KeySignatureSteps.stepDy(
                step: entry.0, sp: metrics.sp,
            )
            if let layer = glyphLayer(
                entry.1,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Time signature

    static func drawTimeSignature(
        numerator: Int, denominator: Int,
        origin: CGPoint, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let numStr = String(numerator)
        let denStr = String(denominator)
        let digitAdvance = metrics.sp * 1.4
        let numWidth = CGFloat(numStr.count) * digitAdvance
        let denWidth = CGFloat(denStr.count) * digitAdvance
        let maxWidth = max(numWidth, denWidth)
        let numOffsetX = (maxWidth - numWidth) / 2
        let denOffsetX = (maxWidth - denWidth) / 2

        for (i, ch) in numStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            if let layer = glyphLayer(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + numOffsetX
                        + CGFloat(i) * digitAdvance,
                    y: origin.y - metrics.sp,
                ),
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
        for (i, ch) in denStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            if let layer = glyphLayer(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + denOffsetX
                        + CGFloat(i) * digitAdvance,
                    y: origin.y + metrics.sp,
                ),
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Bar line

    /// `halfHeight` is the distance from `origin.y` to each end of the
    /// stroke, carried on `LayoutElement.barLine` — half the staff's
    /// drawn height, or 2 sp on a one-line staff. Do not re-derive it
    /// from `metrics`: `metrics` describes the five-line reference
    /// staff and knows nothing about this staff's line count.
    static func drawBarLine(
        subtype: String?, origin: CGPoint, halfHeight: CGFloat,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let topY = origin.y - halfHeight
        let botY = origin.y + halfHeight
        let sp = metrics.sp
        let thin = sp * BarLineGeometry.thinThicknessSp
        let thick = sp * BarLineGeometry.thickThicknessSp
        func line(dx: CGFloat, width: CGFloat) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: origin.x + dx, y: topY))
            path.addLine(to: CGPoint(x: origin.x + dx, y: botY))
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: width,
            ))
        }
        switch subtype {
        case "double":
            line(dx: -sp * BarLineGeometry.doubleStrokeDxSp, width: thin)
            line(dx: sp * BarLineGeometry.doubleStrokeDxSp, width: thin)
        case "end", "final":
            line(dx: 0, width: thin)
            line(dx: sp * BarLineGeometry.endThickStrokeDxSp, width: thick)
        case "start-repeat":
            line(dx: 0, width: thick)
            line(dx: sp * BarLineGeometry.repeatSecondStrokeDxSp, width: thin)
            drawRepeatDots(
                origin: origin,
                xOffset: sp * BarLineGeometry.repeatDotDxSp,
                metrics: metrics, height: height, into: parent,
            )
        case "end-repeat":
            drawRepeatDots(
                origin: origin,
                xOffset: -sp * BarLineGeometry.repeatDotDxSp,
                metrics: metrics, height: height, into: parent,
            )
            line(dx: 0, width: thin)
            line(dx: sp * BarLineGeometry.repeatSecondStrokeDxSp, width: thick)
        default:
            line(dx: 0, width: thin)
        }
    }

    private static func drawRepeatDots(
        origin: CGPoint, xOffset: CGFloat,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let dotSize = metrics.sp * BarLineGeometry.repeatDotDiameterSp
        let half = dotSize / 2
        let top = CGRect(
            x: origin.x + xOffset - half,
            y: origin.y - metrics.sp / 2 - half,
            width: dotSize, height: dotSize,
        )
        let bot = CGRect(
            x: origin.x + xOffset - half,
            y: origin.y + metrics.sp / 2 - half,
            width: dotSize, height: dotSize,
        )
        parent.addSublayer(fillLayer(
            path: CGPath(ellipseIn: top, transform: nil),
            height: height,
        ))
        parent.addSublayer(fillLayer(
            path: CGPath(ellipseIn: bot, transform: nil),
            height: height,
        ))
    }

    // MARK: - Rest

    @discardableResult
    static func drawRest(
        duration: NoteDuration, origin: CGPoint,
        hasLegerLine: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) -> CAShapeLayer? {
        let (baseDur, dots) = DurationInterpretation.split(duration)
        let glyph: Character
        switch baseDur {
        case .whole:
            glyph = hasLegerLine
                ? SMuFLGlyph.restWholeLegerLine
                : SMuFLGlyph.restWhole
        case .half:
            glyph = hasLegerLine
                ? SMuFLGlyph.restHalfLegerLine
                : SMuFLGlyph.restHalf
        case .quarter: glyph = SMuFLGlyph.restQuarter
        case .eighth: glyph = SMuFLGlyph.rest8th
        case .sixteenth: glyph = SMuFLGlyph.rest16th
        case .thirtySecond: glyph = SMuFLGlyph.rest32nd
        case .sixtyFourth: glyph = SMuFLGlyph.rest64th
        default: glyph = SMuFLGlyph.restQuarter
        }
        let glyphLayerRef = glyphLayer(
            glyph, at: origin, size: metrics.glyphFontSize,
            height: height,
        )
        if let layer = glyphLayerRef {
            parent.addSublayer(layer)
        }
        drawDots(
            after: origin, count: dots,
            onStaffLine: true,
            metrics: metrics, height: height, into: parent,
        )
        return glyphLayerRef
    }
}
