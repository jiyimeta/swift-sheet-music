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
    // MARK: - Clef

    @discardableResult
    static func drawClef(
        rawType: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
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
        case .alto, .tenor: glyph = SMuFLGlyph.cClef; yOffset = 0
        case .percussion: glyph = SMuFLGlyph.percussionClef; yOffset = 0
        }
        guard let layer = glyphLayer(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize,
            height: height
        ) else {
            return nil
        }
        parent.addSublayer(layer)
        return layer
    }

    // MARK: - Key signature

    private static let sharpSteps: [Int] = [4, 1, 5, 2, -1, 3, 0]
    private static let flatSteps: [Int] = [0, 3, -1, 2, -2, 1, -3]

    static func drawKeySignature(
        sharps: Int, flats: Int, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return }
        let isSharp = sharps > 0
        let glyph = isSharp
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        let steps = isSharp ? sharpSteps : flatSteps
        let advance = metrics.sp * 1.4
        for i in 0 ..< min(count, steps.count) {
            let step = steps[i]
            let x = origin.x + CGFloat(i) * advance
            let y = origin.y - CGFloat(step) * metrics.sp / 2
            if let layer = glyphLayer(
                glyph,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
                height: height
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
        into parent: CALayer
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
                    y: origin.y - metrics.sp
                ),
                size: metrics.glyphFontSize,
                height: height
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
                    y: origin.y + metrics.sp
                ),
                size: metrics.glyphFontSize,
                height: height
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Bar line

    static func drawBarLine(
        subtype: String?, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let topY = origin.y - metrics.sp * 2
        let botY = origin.y + metrics.sp * 2
        func line(dx: CGFloat, width: CGFloat) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: origin.x + dx, y: topY))
            path.addLine(to: CGPoint(x: origin.x + dx, y: botY))
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: width
            ))
        }
        switch subtype {
        case "double":
            line(dx: -metrics.sp * 0.3, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.15)
        case "end", "final":
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.4, width: metrics.sp * 0.4)
        case "start-repeat":
            line(dx: 0, width: metrics.sp * 0.4)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.15)
            drawRepeatDots(
                origin: origin, xOffset: metrics.sp * 0.6,
                metrics: metrics, height: height, into: parent
            )
        case "end-repeat":
            drawRepeatDots(
                origin: origin, xOffset: -metrics.sp * 0.6,
                metrics: metrics, height: height, into: parent
            )
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.4)
        default:
            line(dx: 0, width: metrics.sp * 0.15)
        }
    }

    private static func drawRepeatDots(
        origin: CGPoint, xOffset: CGFloat,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let dotSize = metrics.sp * 0.3
        let half = dotSize / 2
        let top = CGRect(
            x: origin.x + xOffset - half,
            y: origin.y - metrics.sp / 2 - half,
            width: dotSize, height: dotSize
        )
        let bot = CGRect(
            x: origin.x + xOffset - half,
            y: origin.y + metrics.sp / 2 - half,
            width: dotSize, height: dotSize
        )
        parent.addSublayer(fillLayer(
            path: CGPath(ellipseIn: top, transform: nil),
            height: height
        ))
        parent.addSublayer(fillLayer(
            path: CGPath(ellipseIn: bot, transform: nil),
            height: height
        ))
    }

    // MARK: - Rest

    @discardableResult
    static func drawRest(
        duration: NoteDuration, origin: CGPoint,
        hasLegerLine: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
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
            height: height
        )
        if let layer = glyphLayerRef {
            parent.addSublayer(layer)
        }
        drawDots(
            after: origin, count: dots,
            onStaffLine: true,
            metrics: metrics, height: height, into: parent
        )
        return glyphLayerRef
    }
}
