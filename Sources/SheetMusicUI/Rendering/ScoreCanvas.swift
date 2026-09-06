// swiftlint:disable file_length
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Static drawing routines shared between single-system and full-
/// document canvases. Factored out so every `Canvas`-based renderer —
/// `PagedScoreView`, `PDFPageView`, `TitleFrameView` — draws a system
/// exactly the same way.
@available(macOS 15.0, *)
public enum ScoreCanvasDrawing { // swiftlint:disable:this type_body_length
    /// Draw one system into `context`.
    ///
    /// `visibleX` clips the draw to a document-X range. It existed for
    /// the slice-per-chunk renderer that `ScoreView` retired in favor
    /// of CALayer trees, so **no caller in this package passes it any
    /// more**; it stays because it is public API and callers outside
    /// the package may rely on it.
    public static func drawSystem( // swiftlint:disable:this function_body_length
        _ system: LayoutSystem,
        metrics: StaffMetrics,
        into context: inout GraphicsContext,
        visibleX: ClosedRange<CGFloat>? = nil,
    ) {
        // Staves
        let staffEndX = StaffRenderer.endX(for: system)
        for (index, origin) in system.staffOrigins.enumerated() {
            StaffRenderer.draw(
                context: &context,
                origin: CGPoint(
                    x: system.origin.x + origin.x,
                    y: system.origin.y + origin.y,
                ),
                width: staffEndX - origin.x,
                geometry: system.geometry(atFlatIndex: index),
                metrics: metrics,
            )
        }
        // System barline — vertical line at the system's left edge
        // joining all staves. Both ends come from `systemStartBarLine`,
        // which spans the END staves by their own line counts.
        if let span = system.systemStartBarLine {
            let x = system.origin.x + span.x
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: system.origin.y + span.top))
            bar.addLine(to: CGPoint(
                x: x,
                y: system.origin.y + span.bottom,
            ))
            context.stroke(
                bar,
                with: .color(.primary),
                lineWidth: metrics.staffLineThickness,
            )
        }
        // Brackets / braces at the left edge of the system.
        StaffRenderer.drawBrackets(
            context: &context,
            system: system,
            metrics: metrics,
        )
        // Part labels — `label.origin.x` already encodes the right-edge
        // X (in system coords) computed by the layout pass to clear any
        // bracket/brace columns.
        for label in system.partLabels {
            PartLabelRenderer.draw(
                context: &context,
                text: label.text,
                origin: CGPoint(
                    x: system.origin.x + label.origin.x,
                    y: system.origin.y + label.origin.y,
                ),
                metrics: metrics,
            )
        }
        // Measures — skip those entirely outside the visible x range.
        let showsInvisible = system.showsInvisibleElements
        for measure in system.measures {
            if let vx = visibleX {
                let mLeft = system.origin.x + measure.origin.x
                let mRight = mLeft + measure.width
                if mRight < vx.lowerBound || mLeft > vx.upperBound {
                    continue
                }
            }
            let base = CGPoint(
                x: system.origin.x + measure.origin.x,
                y: system.origin.y + measure.origin.y,
            )
            for element in measure.elements {
                drawElement(
                    element,
                    base: base,
                    metrics: metrics,
                    showsInvisibleElements: showsInvisible,
                    into: &context,
                )
            }
            if !measure.invisibleElements.isEmpty {
                var gray = context
                // MuseScore invisibleColor() = #808080; 50% black on the
                // white score background is the exact equivalent.
                gray.opacity = 0.5
                for element in measure.invisibleElements {
                    drawElement(
                        element,
                        base: base,
                        metrics: metrics,
                        // Routed-to-invisible chord/note glyphs already
                        // sit under a 50% group context; force-enable
                        // showsInvisible so per-note dispatch grays
                        // rather than skips them.
                        showsInvisibleElements: true,
                        into: &gray,
                    )
                }
            }
            for el in measure.markers {
                drawElement(
                    el,
                    base: base,
                    metrics: metrics,
                    showsInvisibleElements: showsInvisible,
                    into: &context,
                )
            }
            for el in measure.jumps {
                drawElement(
                    el,
                    base: base,
                    metrics: metrics,
                    showsInvisibleElements: showsInvisible,
                    into: &context,
                )
            }
        }
        // System-level spanners
        for el in system.spanners {
            drawElement(
                el,
                base: system.origin,
                metrics: metrics,
                showsInvisibleElements: showsInvisible,
                into: &context,
            )
        }
        if !system.invisibleSpanners.isEmpty {
            var gray = context
            // MuseScore invisibleColor() = #808080; 50% black on the
            // white score background is the exact equivalent.
            gray.opacity = 0.5
            for el in system.invisibleSpanners {
                drawElement(
                    el,
                    base: system.origin,
                    metrics: metrics,
                    showsInvisibleElements: true,
                    into: &gray,
                )
            }
        }
    }

    static func drawElement( // swiftlint:disable:this function_body_length
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
        showsInvisibleElements: Bool = false,
        into context: inout GraphicsContext,
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        switch element {
        case let .clef(raw, p, _):
            ClefRenderer.draw(
                context: &context, rawType: raw,
                origin: shift(p), metrics: metrics,
            )
        case let .keySignature(s, f, clef, naturals, p):
            KeySignatureRenderer.draw(
                context: &context, sharps: s, flats: f, clef: clef,
                naturals: naturals,
                origin: shift(p), metrics: metrics,
            )
        case let .timeSignature(n, d, symbol, p):
            TimeSignatureRenderer.draw(
                context: &context, numerator: n, denominator: d,
                symbol: symbol, origin: shift(p), metrics: metrics,
            )
        case let .barLine(s, p, halfHeight):
            BarLineRenderer.draw(
                context: &context, subtype: s,
                origin: shift(p), halfHeight: halfHeight,
                metrics: metrics,
            )
        case let .ledgerLine(from, to, thickness):
            var p = Path()
            p.move(to: shift(from))
            p.addLine(to: shift(to))
            context.stroke(p, with: .color(.primary), lineWidth: thickness)
        case let .rest(d, p, _, _, hll):
            let (baseDur, dots) = DurationInterpretation.split(d)
            RestRenderer.draw(
                context: &context, duration: baseDur,
                hasLegerLine: hll,
                origin: shift(p), metrics: metrics,
            )
            DotRenderer.draw(
                context: &context,
                after: shift(p),
                count: dots,
                onStaffLine: true,
                metrics: metrics,
            )
        case let .chord(
            notes,
            dur,
            stem,
            stemOrigin,
            _,
            _,
            isBeamed,
            _,
            stemExt,
            stemIsInvisible,
            mag,
        ):
            // Scale metrics for small / cue noteheads (mag < 1.0).
            // Mirrors `ScoreLayerBuilder+Element`'s pattern: derive a
            // scaled StaffMetrics so every glyph dimension shrinks.
            let chordMetrics = mag == 1.0
                ? metrics
                : StaffMetrics(staffSize: metrics.staffHeight * mag)
            drawChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: stemOrigin, isBeamed: isBeamed,
                stemExtension: stemExt,
                stemIsInvisible: stemIsInvisible,
                base: base, metrics: chordMetrics,
                showsInvisibleElements: showsInvisibleElements,
                into: &context,
            )
        case let .textMark(.dynamic, text, p):
            TextMarkRenderer.drawDynamic(
                context: &context, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .textMark(.tempo, text, p):
            TextMarkRenderer.drawTempo(
                context: &context, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .textMark(.lyrics(lyricColor), text, p):
            TextMarkRenderer.drawLyric(
                context: &context, text: text,
                origin: shift(p),
                color: lyricColor.map { Color(scoreColor: $0) } ?? .primary,
                metrics: metrics,
            )
        case let .beam(from, to, direction, level, beamColor):
            BeamRenderer.draw(
                context: &context,
                from: shift(from),
                to: shift(to),
                direction: direction,
                level: level,
                color: beamColor.map { Color(scoreColor: $0) } ?? .primary,
                metrics: metrics,
            )
        case let .fermata(subtype, p):
            FermataRenderer.draw(
                context: &context, subtype: subtype,
                origin: shift(p), metrics: metrics,
            )
        case let .breath(kind, p):
            BreathRenderer.draw(
                context: &context, kind: kind,
                origin: shift(p), metrics: metrics,
            )
        case let .articulation(kind, p, isAbove):
            ArticulationRenderer.draw(
                context: &context, kind: kind,
                isAbove: isAbove, origin: shift(p),
                metrics: metrics,
            )
        case let .measureRepeat(c, p):
            MeasureRepeatRenderer.draw(
                context: &context, count: c,
                origin: shift(p), metrics: metrics,
            )
        case let .arpeggioWiggle(top, bot, sub):
            ArpeggioRenderer.draw(
                context: &context, top: shift(top),
                bottom: shift(bot), subtype: sub,
                metrics: metrics,
            )
        case let .spannerSegment(
            kind,
            from,
            to,
            cl,
            cr,
            text,
        ):
            SpannerRenderer.draw(
                context: &context, kind: kind,
                from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr,
                text: text, metrics: metrics,
            )
        case let .tieArc(from, to, above):
            TieRenderer.draw(
                context: &context,
                from: shift(from), to: shift(to),
                above: above, metrics: metrics,
            )
        case let .glissandoLine(from, to, wavy, text):
            GlissandoRenderer.draw(
                context: &context,
                from: shift(from), to: shift(to),
                wavy: wavy, text: text, metrics: metrics,
            )
        case let .guitarBend(from, vertex, to, slight):
            GuitarBendRenderer.draw(
                context: &context,
                from: shift(from), vertex: shift(vertex), to: shift(to),
                slight: slight, metrics: metrics,
            )
        case let .legacyBend(shape):
            // The shape carries absolute coords, so the whole thing
            // shifts at once instead of point by point.
            LegacyBendRenderer.draw(
                context: &context,
                shape: shape.translated(by: base),
                metrics: metrics,
            )
        case let .chordLine(shape, origin, thickness):
            ChordLineRenderer.draw(
                context: &context,
                shape: shape, origin: shift(origin),
                thickness: thickness, metrics: metrics,
            )
        case let .tupletLabel(
            from,
            to,
            text,
            bracket,
            above,
            _,
        ):
            TupletRenderer.draw(
                context: &context,
                from: shift(from), to: shift(to),
                text: text,
                hasBracket: bracket,
                isAbove: above,
                metrics: metrics,
            )
        case let .marker(kind, text, p):
            MarkerRenderer.draw(
                context: &context, kind: kind, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .rehearsalMark(text, p, frame, color):
            RehearsalMarkRenderer.draw(
                context: &context, text: text,
                origin: shift(p), frame: frame, color: color,
                metrics: metrics,
            )
        case let .jump(text, p):
            JumpRenderer.draw(
                context: &context, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .measureNumber(text, p):
            MeasureNumberRenderer.draw(
                context: &context, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .staffName(text, p):
            StaffNameRenderer.draw(
                context: &context, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .staffText(text, p, color, style):
            StaffTextRenderer.draw(
                context: &context, text: text,
                origin: shift(p),
                color: color,
                style: style,
                metrics: metrics,
            )
        case let .harmony(lh):
            let p = shift(CGPoint(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y),
            ))
            HarmonyRenderer.draw(
                context: &context,
                harmony: lh,
                origin: p,
                metrics: metrics,
            )
        case let .lyricsMelisma(from, to):
            var path = Path()
            path.move(to: shift(from))
            path.addLine(to: shift(to))
            context.stroke(
                path,
                with: .color(.primary),
                lineWidth: metrics.sp * 0.1,
            )
        case let .lyricHyphen(from, to):
            // Same line thickness as the melisma rule; MuseScore's
            // `lyricsDashLineThickness` default is 0.1 sp.
            var path = Path()
            path.move(to: shift(from))
            path.addLine(to: shift(to))
            context.stroke(
                path,
                with: .color(.primary),
                lineWidth: metrics.sp * 0.1,
            )
        case .multiMeasureRest:
            // The CALayer path implements this
            // (`ScoreLayerBuilder+Misc.drawMultiMeasureRest`, called
            // from `ScoreLayerBuilder+Element`); the Canvas path does
            // not draw multi-measure rests yet — a known dual-renderer
            // parity gap (tracked 2026-08-27).
            break
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
            TremoloRenderer.draw(
                context: &context, anchor: shiftedAnchor,
                barCount: barCount, metrics: metrics,
            )
        case let .graceChord(
            notes,
            dur,
            stem,
            stemOrigin,
            // `relativeX` is NOT applied here: the grace notes were
            // already placed at `chordX + relativeX`
            // (`LayoutEngine+Placement`), so their origins are absolute
            // in measure space. Adding it again would shift every grace.
            _,
            hasSlash,
            mag,
            _,
        ):
            drawGraceChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: stemOrigin, hasSlash: hasSlash, mag: mag,
                base: base, metrics: metrics,
                showsInvisibleElements: showsInvisibleElements,
                into: &context,
            )
        case .note:
            break
        }
    }
}
