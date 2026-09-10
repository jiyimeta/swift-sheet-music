// swiftlint:disable file_length
import QuartzCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    // MARK: - Element dispatch

    static func drawElement( // swiftlint:disable:this function_body_length
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer,
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        let firstLayerIndex = parent.sublayers?.count ?? 0
        defer {
            // Register only this element's newly drawn ink, including every stroke, dot and text run.
            // The shared identity predicate is also the hit tester's eligibility rule.
            if let itemID = element.elementItemID {
                for layer in (parent.sublayers ?? []).dropFirst(firstLayerIndex) {
                    if let ink = layer as? CAShapeLayer {
                        context.attach(ink, to: itemID)
                    }
                }
            }
        }
        switch element {
        case let .clef(raw, p, anchor):
            let layer = drawClef(
                rawType: raw, origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
            if let layer, let anchor {
                context.attach(layer, to: .clef(anchor))
            }
        case let .keySignature(s, f, clef, naturals, p, _):
            drawKeySignature(
                sharps: s, flats: f, clef: clef, naturals: naturals,
                origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .timeSignature(n, d, symbol, p, _):
            drawTimeSignature(
                numerator: n, denominator: d, symbol: symbol,
                origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .barLine(s, p, halfHeight, _, _):
            drawBarLine(
                subtype: s, origin: shift(p), halfHeight: halfHeight,
                metrics: metrics, height: height, into: parent,
            )
        case let .ledgerLine(from, to, thickness):
            let path = CGMutablePath()
            path.move(to: shift(from))
            path.addLine(to: shift(to))
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: thickness,
            ))
        case let .rest(d, p, _, rid, hll):
            if let layer = drawRest(
                duration: d, origin: shift(p),
                hasLegerLine: hll,
                metrics: metrics, height: height, into: parent,
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
            _,
            stemExt,
            stemHidden,
            mag,
        ):
            // Scale metrics for small / cue noteheads (mag < 1.0).
            // Mirrors `GraceChordRenderer.drawGraceChord`'s pattern:
            // derive a scaled StaffMetrics from staffHeight * mag so
            // every glyph dimension shrinks proportionally.
            let chordMetrics = mag == 1.0
                ? metrics
                : StaffMetrics(staffSize: metrics.staffHeight * mag)
            drawChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, isBeamed: beamed,
                tremoloStemExtension: stemExt,
                stemIsInvisible: stemHidden,
                base: base,
                metrics: chordMetrics, height: height,
                context: &context, into: parent,
            )
        case let .textMark(.dynamic, text, p):
            // Standard dynamics → Bravura SMuFL glyphs at 4 sp.
            // Free-form text dynamics → Edwin italic 10 pt fallback.
            // See `TextMarkRenderer.drawDynamic` for the rationale.
            if let glyphString = DynamicSymbolMap.glyphString(for: text) {
                let glyphSize = metrics.sp * 4
                let bravura = CTFontCreateWithName(
                    BravuraFont.familyName as CFString, glyphSize, nil,
                )
                if let layer = textLayer(
                    text: glyphString, at: shift(p),
                    size: glyphSize, italic: false,
                    anchor: CGPoint(x: 0, y: 0.5),
                    font: bravura,
                    height: height,
                ) {
                    parent.addSublayer(layer)
                }
            } else {
                let style = ResolvedTextStyle.resolve(
                    .dynamics, metrics: metrics,
                )
                if let layer = textLayer(
                    text: text, at: shift(p),
                    size: style.pointSize, italic: style.isItalic,
                    anchor: CGPoint(x: 0, y: 0.5),
                    font: style.ctFont,
                    height: height,
                ) {
                    parent.addSublayer(layer)
                }
            }
        case let .textMark(.tempo, text, p):
            drawTempoText(text: text, origin: shift(p), metrics: metrics, height: height, into: parent)
        case let .textMark(
            .lyrics(lyricColor, _, _), text, p,
        ):
            let style = ResolvedTextStyle.resolve(
                .lyricsOdd, metrics: metrics,
            )
            if let layer = textLayer(
                text: text, at: shift(p),
                size: style.pointSize, italic: style.isItalic,
                anchor: CGPoint(x: 0.5, y: 0.5),
                color: lyricColor.map(scoreColorToCGColor) ?? inkColor,
                font: style.ctFont,
                height: height,
            ) {
                parent.addSublayer(layer)
                // One syllable, one selectable item — never the verse
                // row, and never the hyphen / melisma rules between
                // syllables, which are their own elements. See
                // `ScoreTextID` for the MuseScore rule this follows.
                attachText(element, layer, context: &context)
            }
        case let .beam(from, to, direction, level, beamColor):
            drawBeam(
                from: shift(from), to: shift(to),
                direction: direction, level: level,
                color: beamColor.map(scoreColorToCGColor) ?? inkColor,
                metrics: metrics, height: height, into: parent,
            )
        case let .fermata(subtype, p, _):
            drawFermata(
                subtype: subtype, origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .breath(kind, p, _):
            drawBreath(
                kind: kind, origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .articulation(kind, p, isAbove, _):
            drawArticulation(
                kind: kind, isAbove: isAbove,
                origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .measureRepeat(c, p):
            drawMeasureRepeat(
                count: c, origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .arpeggioWiggle(top, bot, sub):
            drawArpeggio(
                top: shift(top), bottom: shift(bot), subtype: sub,
                metrics: metrics, height: height, into: parent,
            )
        case let .spannerSegment(
            kind, from, to, cl, cr, text, _,
        ):
            drawSpanner(
                kind: kind, from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr, text: text,
                metrics: metrics, height: height, into: parent,
            )
        case let .tieArc(from, to, above, _):
            drawTieArc(
                from: shift(from), to: shift(to), above: above,
                metrics: metrics, height: height, into: parent,
            )
        case let .glissandoLine(from, to, wavy, text):
            drawGlissando(
                from: shift(from), to: shift(to), wavy: wavy,
                text: text,
                metrics: metrics, height: height, into: parent,
            )
        case let .guitarBend(from, vertex, to, slight):
            drawGuitarBend(
                from: shift(from), vertex: shift(vertex), to: shift(to),
                slight: slight,
                metrics: metrics, height: height, into: parent,
            )
        case let .legacyBend(shape):
            // The shape carries absolute coords, so the whole thing
            // shifts at once instead of point by point.
            drawLegacyBend(
                shape: shape.translated(by: base),
                metrics: metrics, height: height, into: parent,
            )
        case let .chordLine(shape, origin, thickness):
            drawChordLine(
                shape: shape, origin: shift(origin),
                thickness: thickness,
                metrics: metrics, height: height, into: parent,
            )
        case let .tupletLabel(
            from, to, text, bracket, above,
            tid,
        ):
            drawTuplet(
                from: shift(from), to: shift(to),
                text: text, hasBracket: bracket, isAbove: above,
                tupletID: tid,
                metrics: metrics, height: height,
                context: &context, into: parent,
            )
        case let .marker(kind, text, p, _):
            drawMarker(
                kind: kind, text: text, origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .rehearsalMark(text, p, frame, color, _):
            // The frame is attached alongside the letter: MuseScore
            // tints a selected text's frame too, from the same
            // `curColor` (`TDraw::drawTextBase`), so a selected boxed
            // "A" turns blue box and all.
            for layer in drawRehearsalMark(
                text: text, origin: shift(p), frame: frame,
                color: color.map(scoreColorToCGColor) ?? Self.inkColor,
                metrics: metrics, height: height, into: parent,
            ) {
                attachText(element, layer, context: &context)
            }
        case let .jump(text, p, _):
            if !text.isEmpty,
               let layer = notationTextLayer(
                   text: text, role: .jump, origin: shift(p), metrics: metrics, height: height,
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
               let layer = notationTextLayer(
                   text: text, role: .measureNumber, origin: shift(p), metrics: metrics, height: height,
               )
            {
                parent.addSublayer(layer)
            }
        case let .staffText(text, p, color, style, _):
            // Author-supplied staff/system text. Color and offset
            // (already baked into `p` by placement) come from the
            // source `.mscx`. Bottom-leading anchor at `p` matches
            // the placement convention used for dynamics/tempo.
            let resolvedStyle = ResolvedTextStyle.resolve(
                style, metrics: metrics,
            )
            if !text.isEmpty,
               let layer = textLayer(
                   text: text, at: shift(p),
                   size: resolvedStyle.pointSize, italic: resolvedStyle.isItalic,
                   anchor: CGPoint(x: 0, y: 1),
                   color: color.map(scoreColorToCGColor)
                       ?? Self.inkColor,
                   font: resolvedStyle.ctFont,
                   height: height,
               )
            {
                parent.addSublayer(layer)
                attachText(element, layer, context: &context)
            }
        case let .harmony(lh):
            // Per-run dispatch: text runs go through the
            // ResolvedTextStyle path (Edwin/Campania); accidental
            // runs render the SMuFL glyph in Bravura at glyph size.
            let style = ResolvedTextStyle.resolve(
                lh.harmony.styleType,
                overrides: lh.harmony.properties,
                metrics: metrics,
            )
            let textColor: CGColor = lh.harmony.color
                .map(scoreColorToCGColor) ?? Self.inkColor
            let glyphSize = HarmonyRendering.glyphPointSize(
                for: lh.harmony, metrics: metrics,
            )
            let bravura = CTFontCreateWithName(
                BravuraFont.familyName as CFString,
                glyphSize, nil,
            )
            let originPoint = shift(CGPoint(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y),
            ))
            for run in lh.runs {
                let p = CGPoint(
                    x: originPoint.x + CGFloat(run.x),
                    y: originPoint.y,
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
                        height: height,
                    ) {
                        parent.addSublayer(layer)
                        attachText(element, layer, context: &context)
                    }
                case let .accidental(acc):
                    if let layer = textLayer(
                        text: String(acc.codepoint), at: p,
                        size: glyphSize,
                        italic: false,
                        anchor: CGPoint(x: 0, y: 0.5),
                        color: textColor,
                        font: bravura,
                        height: height,
                    ) {
                        parent.addSublayer(layer)
                        // Every run, text and SMuFL accidental alike:
                        // "Cm♭5" is one chord symbol and tints whole.
                        attachText(element, layer, context: &context)
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
               let layer = notationTextLayer(
                   text: text, role: .staffName, origin: shift(p), metrics: metrics, height: height,
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
                metrics: metrics, height: height, into: parent,
            )
        case let .graceChord(
            notes, dur, stem, so, _, slash, mag, _,
        ):
            drawGraceChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, hasSlash: slash, mag: mag,
                base: base, metrics: metrics, height: height,
                context: &context, into: parent,
            )
        case let .multiMeasureRest(c, p):
            drawMultiMeasureRest(
                count: c, origin: shift(p),
                metrics: metrics, height: height, into: parent,
            )
        case let .tremoloBars(anchor, barCount):
            let shiftedAnchor: TremoloAnchor
            switch anchor {
            case let .single(c):
                shiftedAnchor = .single(center: shift(c))
            case let .between(left, right):
                shiftedAnchor = .between(
                    leftStemMid: shift(left),
                    rightStemMid: shift(right),
                )
            }
            drawTremoloBars(
                anchor: shiftedAnchor, barCount: barCount,
                metrics: metrics, height: height, into: parent,
            )
        case .note:
            break
        }
    }

    /// Registers `layer` as part of the engraved text `element` draws, so a selection naming that text can
    /// re-tint it. A no-op for an element that is not addressable text.
    ///
    /// The predicate is `LayoutElement.textID`, the same one `ScoreHitTester` reports a hit from — so what
    /// a click can select and what a selection can tint are one decision, not two that could drift.
    private static func attachText(
        _ element: LayoutElement,
        _ layer: CAShapeLayer,
        context: inout BuildContext,
    ) {
        guard let id = element.textItemID else { return }
        context.attach(layer, to: id)
    }

    // MARK: - Melisma

    private static func drawLyricsMelisma(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
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
            lineWidth: metrics.sp * 0.1,
        ))
    }
}
