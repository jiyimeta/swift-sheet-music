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
    // MARK: - Element dispatch

    static func drawElement(
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        switch element {
        case .clef(let raw, let p):
            drawClef(
                rawType: raw, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .keySignature(let s, let f, let p):
            drawKeySignature(
                sharps: s, flats: f, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .timeSignature(let n, let d, let p):
            drawTimeSignature(
                numerator: n, denominator: d, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .barLine(let s, let p):
            drawBarLine(
                subtype: s, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case let .rest(d, p, _, rid, hll):
            if let layer = drawRest(
                duration: d, origin: shift(p),
                hasLegerLine: hll,
                metrics: metrics, height: height, into: parent) {
                context.attach(layer, to: .rest(rid))
            }
        case .chord(let notes, let dur, let stem, let so,
                    _, _, let beamed, _):
            drawChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, isBeamed: beamed,
                base: base,
                metrics: metrics, height: height,
                context: &context, into: parent)
        case .textMark(.dynamic, let text, let p):
            if let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.5, italic: true,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        case .textMark(.tempo, let text, let p):
            if let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.2, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        case .textMark(.lyrics, let text, let p):
            if let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.2, italic: false,
                anchor: CGPoint(x: 0.5, y: 0.5),
                kind: .lyrics,
                height: height) {
                parent.addSublayer(layer)
            }
        case .beam(let from, let to, let direction, let level):
            drawBeam(
                from: shift(from), to: shift(to),
                direction: direction, level: level,
                metrics: metrics, height: height, into: parent)
        case .fermata(let subtype, let p):
            drawFermata(
                subtype: subtype, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .measureRepeat(let c, let p):
            drawMeasureRepeat(
                count: c, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .arpeggioWiggle(let top, let bot, let sub):
            drawArpeggio(
                top: shift(top), bottom: shift(bot), subtype: sub,
                metrics: metrics, height: height, into: parent)
        case .spannerSegment(
            let kind, let from, let to, let cl, let cr, let text):
            drawSpanner(
                kind: kind, from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr, text: text,
                metrics: metrics, height: height, into: parent)
        case .tieArc(let from, let to, let above):
            drawTieArc(
                from: shift(from), to: shift(to), above: above,
                metrics: metrics, height: height, into: parent)
        case .glissandoLine(let from, let to, let wavy, let text):
            drawGlissando(
                from: shift(from), to: shift(to), wavy: wavy,
                text: text,
                metrics: metrics, height: height, into: parent)
        case .tupletLabel(
            let from, let to, let text, let bracket, let above):
            drawTuplet(
                from: shift(from), to: shift(to),
                text: text, hasBracket: bracket, isAbove: above,
                metrics: metrics, height: height, into: parent)
        case .marker(let kind, let text, let p):
            drawMarker(
                kind: kind, text: text, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .rehearsalMark(let text, let p, let frame, let color):
            drawRehearsalMark(
                text: text, origin: shift(p), frame: frame,
                color: color.map(scoreColorToCGColor) ?? Self.inkColor,
                metrics: metrics, height: height, into: parent)
        case .jump(let text, let p):
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.5, italic: true,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        case .measureNumber(let text, let p):
            // Measure number at MuseScore's
            // `TextStyleType::DEFAULT` size (10 pt at 5 pt-spatium
            // ≈ 2 spatia → `sp * 2.0`), bottom-LEADING anchored so
            // the digits' LEFT edge lines up with `origin.x` — the
            // layout pins it to the bracket spine for inline use,
            // or to `keySigX` in the sticky pane.
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.0, italic: false,
                anchor: CGPoint(x: 0, y: 1),
                height: height) {
                parent.addSublayer(layer)
            }
        case .staffText(let text, let p, let color, _):
            // Author-supplied staff/system text. Colour and offset
            // (already baked into `p` by placement) come from the
            // source `.mscx`. Bottom-leading anchor at `p` matches
            // the placement convention used for dynamics/tempo.
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.2, italic: false,
                anchor: CGPoint(x: 0, y: 1),
                color: color.map(scoreColorToCGColor)
                    ?? Self.inkColor,
                height: height) {
                parent.addSublayer(layer)
            }
        case .staffName(let text, let p):
            // Staff name in the sticky pane: bottom-leading anchor
            // so the text sits ABOVE the staff with its left edge at
            // `origin.x` (which the layout sets to `keySigX`,
            // matching MuseScore's `clefLeftMargin + widthClef`).
            // Same `sp * 2.0` size as the measure number above it,
            // matching MuseScore's `TextStyleType::DEFAULT`. The
            // CALayer tree has `masksToBounds = false`, so a long
            // instrument name overflows the pane's white frame to
            // the right without forcing the panel itself to grow.
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.0, italic: false,
                anchor: CGPoint(x: 0, y: 1),
                height: height) {
                parent.addSublayer(layer)
            }
        case .lyricsMelisma(let from, let to),
             .lyricHyphen(let from, let to):
            // Hyphens reuse the melisma rule's stroke (0.1 sp,
            // matching MuseScore's `lyricsDashLineThickness`); the
            // layout decides position and length per
            // `LyricsLayout::layoutDashes`.
            drawLyricsMelisma(
                from: shift(from), to: shift(to),
                metrics: metrics, height: height, into: parent)
        case .note:
            break
        }
    }

    // MARK: - Melisma

    private static func drawLyricsMelisma(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        // MuseScore uses ~0.1 sp for the melisma rule (engraving
        // default `LYRICS_LINE_WIDTH`). That's a touch thinner than
        // a staff line — slim enough that the rule doesn't pull
        // visual weight from the noteheads above.
        parent.addSublayer(strokeLayer(
            path: path, height: height,
            lineWidth: metrics.sp * 0.1))
    }
}
