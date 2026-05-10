// swiftlint:disable function_body_length file_length
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
        case let .clef(raw, p, _):
            drawClef(
                rawType: raw, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .keySignature(s, f, p):
            drawKeySignature(
                sharps: s, flats: f, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .timeSignature(n, d, p):
            drawTimeSignature(
                numerator: n, denominator: d, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .barLine(s, p):
            drawBarLine(
                subtype: s, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .rest(d, p, _, rid, hll):
            if let layer = drawRest(
                duration: d, origin: shift(p),
                hasLegerLine: hll,
                metrics: metrics, height: height, into: parent
            ) {
                context.attach(layer, to: .rest(rid))
            }
        case let .chord(
            notes,
            dur,
            stem,
            so,
            _,
            _,
            beamed,
            _
        ):
            drawChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, isBeamed: beamed,
                base: base,
                metrics: metrics, height: height,
                context: &context, into: parent
            )
        case let .textMark(.dynamic, text, p):
            // Standard dynamics → Bravura SMuFL glyphs at 4 sp.
            // Free-form text dynamics → Edwin italic 10 pt fallback.
            // See `TextMarkRenderer.drawDynamic` for the rationale.
            if let glyphs = DynamicSymbolMap.glyphs(for: text) {
                let glyphSize = metrics.sp * 4
                let bravura = CTFontCreateWithName(
                    BravuraFont.familyName as CFString, glyphSize, nil
                )
                if let layer = textLayer(
                    text: String(glyphs), at: shift(p),
                    size: glyphSize, italic: false,
                    anchor: CGPoint(x: 0, y: 0.5),
                    font: bravura,
                    height: height
                ) {
                    parent.addSublayer(layer)
                }
            } else {
                let style = ResolvedTextStyle.resolve(
                    .dynamics, metrics: metrics
                )
                if let layer = textLayer(
                    text: text, at: shift(p),
                    size: style.pointSize, italic: style.isItalic,
                    anchor: CGPoint(x: 0, y: 0.5),
                    font: style.ctFont,
                    height: height
                ) {
                    parent.addSublayer(layer)
                }
            }
        case let .textMark(.tempo, text, p):
            let style = ResolvedTextStyle.resolve(
                .tempo, metrics: metrics
            )
            if let layer = textLayer(
                text: text, at: shift(p),
                size: style.pointSize, italic: style.isItalic,
                anchor: CGPoint(x: 0, y: 0.5),
                font: style.ctFont,
                height: height
            ) {
                parent.addSublayer(layer)
            }
        case let .textMark(.lyrics, text, p):
            let style = ResolvedTextStyle.resolve(
                .lyricsOdd, metrics: metrics
            )
            if let layer = textLayer(
                text: text, at: shift(p),
                size: style.pointSize, italic: style.isItalic,
                anchor: CGPoint(x: 0.5, y: 0.5),
                font: style.ctFont,
                height: height
            ) {
                parent.addSublayer(layer)
            }
        case let .beam(from, to, direction, level):
            drawBeam(
                from: shift(from), to: shift(to),
                direction: direction, level: level,
                metrics: metrics, height: height, into: parent
            )
        case let .fermata(subtype, p):
            drawFermata(
                subtype: subtype, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .articulation(kind, p, isAbove):
            drawArticulation(
                kind: kind, isAbove: isAbove,
                origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .measureRepeat(c, p):
            drawMeasureRepeat(
                count: c, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .arpeggioWiggle(top, bot, sub):
            drawArpeggio(
                top: shift(top), bottom: shift(bot), subtype: sub,
                metrics: metrics, height: height, into: parent
            )
        case let .spannerSegment(
            kind, from, to, cl, cr, text
        ):
            drawSpanner(
                kind: kind, from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr, text: text,
                metrics: metrics, height: height, into: parent
            )
        case let .tieArc(from, to, above):
            drawTieArc(
                from: shift(from), to: shift(to), above: above,
                metrics: metrics, height: height, into: parent
            )
        case let .glissandoLine(from, to, wavy, text):
            drawGlissando(
                from: shift(from), to: shift(to), wavy: wavy,
                text: text,
                metrics: metrics, height: height, into: parent
            )
        case let .tupletLabel(
            from, to, text, bracket, above,
            tid
        ):
            drawTuplet(
                from: shift(from), to: shift(to),
                text: text, hasBracket: bracket, isAbove: above,
                tupletID: tid,
                metrics: metrics, height: height,
                context: &context, into: parent
            )
        case let .marker(kind, text, p):
            drawMarker(
                kind: kind, text: text, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
        case let .rehearsalMark(text, p, frame, color):
            drawRehearsalMark(
                text: text, origin: shift(p), frame: frame,
                color: color.map(scoreColorToCGColor) ?? Self.inkColor,
                metrics: metrics, height: height, into: parent
            )
        case let .jump(text, p):
            if !text.isEmpty,
               let layer = textLayer(
                   text: text, at: shift(p),
                   size: metrics.sp * 2.5, italic: true,
                   anchor: CGPoint(x: 0, y: 0.5),
                   height: height
               )
            {
                parent.addSublayer(layer)
            }
        case let .measureNumber(text, p):
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
                   height: height
               )
            {
                parent.addSublayer(layer)
            }
        case let .staffText(text, p, color, isSystem):
            // Author-supplied staff/system text. Colour and offset
            // (already baked into `p` by placement) come from the
            // source `.mscx`. Bottom-leading anchor at `p` matches
            // the placement convention used for dynamics/tempo.
            let style = ResolvedTextStyle.resolve(
                isSystem ? .systemText : .staffText, metrics: metrics
            )
            if !text.isEmpty,
               let layer = textLayer(
                   text: text, at: shift(p),
                   size: style.pointSize, italic: style.isItalic,
                   anchor: CGPoint(x: 0, y: 1),
                   color: color.map(scoreColorToCGColor)
                       ?? Self.inkColor,
                   font: style.ctFont,
                   height: height
               )
            {
                parent.addSublayer(layer)
            }
        case let .harmony(lh):
            // Per-run dispatch: text runs go through the
            // ResolvedTextStyle path (Edwin/Campania); accidental
            // runs render the SMuFL glyph in Bravura at glyph size.
            let style = ResolvedTextStyle.resolve(
                lh.harmony.styleType,
                overrides: lh.harmony.properties,
                metrics: metrics
            )
            let textColor: CGColor = lh.harmony.color
                .map(scoreColorToCGColor) ?? Self.inkColor
            let glyphSize = HarmonyRendering.glyphPointSize(
                for: lh.harmony, metrics: metrics
            )
            let bravura = CTFontCreateWithName(
                BravuraFont.familyName as CFString,
                glyphSize, nil
            )
            let originPoint = shift(CGPoint(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y)
            ))
            for run in lh.runs {
                let p = CGPoint(
                    x: originPoint.x + CGFloat(run.x),
                    y: originPoint.y
                )
                switch run.kind {
                case .text:
                    if let layer = textLayer(
                        text: run.content, at: p,
                        size: style.pointSize,
                        italic: style.isItalic,
                        anchor: CGPoint(x: 0, y: 0.5),
                        color: textColor,
                        font: style.ctFont,
                        height: height
                    ) {
                        parent.addSublayer(layer)
                    }
                case let .accidental(acc):
                    if let layer = textLayer(
                        text: String(acc.codepoint), at: p,
                        size: glyphSize,
                        italic: false,
                        anchor: CGPoint(x: 0, y: 0.5),
                        color: textColor,
                        font: bravura,
                        height: height
                    ) {
                        parent.addSublayer(layer)
                    }
                }
            }
        case let .staffName(text, p):
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
                   height: height
               )
            {
                parent.addSublayer(layer)
            }
        case let .lyricsMelisma(from, to),
             let .lyricHyphen(from, to):
            // Hyphens reuse the melisma rule's stroke (0.1 sp,
            // matching MuseScore's `lyricsDashLineThickness`); the
            // layout decides position and length per
            // `LyricsLayout::layoutDashes`.
            drawLyricsMelisma(
                from: shift(from), to: shift(to),
                metrics: metrics, height: height, into: parent
            )
        case let .graceChord(
            notes, dur, stem, so, _, slash, mag, _
        ):
            drawGraceChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, hasSlash: slash, mag: mag,
                base: base, metrics: metrics, height: height,
                context: &context, into: parent
            )
        case let .multiMeasureRest(c, p):
            drawMultiMeasureRest(
                count: c, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
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
            lineWidth: metrics.sp * 0.1
        ))
    }
}
