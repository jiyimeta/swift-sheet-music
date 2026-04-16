#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
struct ScoreCanvas: View {
    let document: LayoutDocument

    var body: some View {
        Canvas { context, _ in
            for system in document.systems {
                drawSystem(system, into: &context)
            }
        }
        .frame(
            width: max(document.size.width, 1),
            height: max(document.size.height, 1),
            alignment: .topLeading
        )
    }

    private func drawSystem(
        _ system: LayoutSystem,
        into context: inout GraphicsContext
    ) {
        let metrics = document.metrics
        // Staves
        for origin in system.staffOrigins {
            StaffRenderer.draw(
                context: &context,
                origin: CGPoint(
                    x: system.origin.x + origin.x,
                    y: system.origin.y + origin.y
                ),
                width: system.size.width - origin.x,
                metrics: metrics
            )
        }
        // Bracket connecting multiple staves of a single Part (piano grand
        // staff and larger groupings). v1 draws one bracket spanning the
        // full vertical extent of all staves.
        if system.staffOrigins.count >= 2,
           let top = system.staffOrigins.first,
           let bot = system.staffOrigins.last {
            let x = system.origin.x + top.x - metrics.sp * 0.5
            StaffRenderer.drawBracket(
                context: &context,
                top: CGPoint(x: x, y: system.origin.y + top.y),
                bottom: CGPoint(
                    x: x,
                    y: system.origin.y + bot.y + metrics.staffHeight),
                metrics: metrics
            )
        }
        // Part labels (left of staves — origin.x is a small left margin;
        // offset by the staff-label-width reservation so text anchors to
        // the right just before staff start).
        for label in system.partLabels {
            PartLabelRenderer.draw(
                context: &context,
                text: label.text,
                origin: CGPoint(
                    x: system.origin.x + (system.staffOrigins.first?.x ?? 60) - metrics.sp,
                    y: system.origin.y + label.origin.y
                ),
                metrics: metrics
            )
        }
        // Measures
        for measure in system.measures {
            let base = CGPoint(
                x: system.origin.x + measure.origin.x,
                y: system.origin.y + measure.origin.y
            )
            for element in measure.elements {
                drawElement(element, base: base,
                            metrics: metrics, into: &context)
            }
            for el in measure.markers {
                drawElement(el, base: base,
                            metrics: metrics, into: &context)
            }
            for el in measure.jumps {
                drawElement(el, base: base,
                            metrics: metrics, into: &context)
            }
        }
        // System-level spanners (populated by Stage 9).
        for el in system.spanners {
            drawElement(el, base: system.origin,
                        metrics: metrics, into: &context)
        }
    }

    private func drawElement(
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
        into context: inout GraphicsContext
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        switch element {
        case .clef(let raw, let p):
            ClefRenderer.draw(
                context: &context, rawType: raw,
                origin: shift(p), metrics: metrics)
        case .keySignature(let s, let f, let p):
            KeySignatureRenderer.draw(
                context: &context, sharps: s, flats: f,
                origin: shift(p), metrics: metrics)
        case .timeSignature(let n, let d, let p):
            TimeSignatureRenderer.draw(
                context: &context, numerator: n, denominator: d,
                origin: shift(p), metrics: metrics)
        case .barLine(let s, let p):
            BarLineRenderer.draw(
                context: &context, subtype: s,
                origin: shift(p), metrics: metrics)
        case .rest(let d, let p):
            let (baseDur, dots) = DurationInterpretation.split(d)
            RestRenderer.draw(
                context: &context, duration: baseDur,
                origin: shift(p), metrics: metrics)
            DotRenderer.draw(
                context: &context,
                after: shift(p),
                count: dots,
                onStaffLine: true,
                metrics: metrics)
        case .chord(let notes, let dur, let stem, let stemOrigin,
                     _, _, let isBeamed):
            let (baseDur, dots) = DurationInterpretation.split(dur)
            // Shift note origins into absolute coords for the heads
            // and the stem renderer.
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando
                )
            }
            for n in shiftedNotes {
                NoteheadRenderer.drawHead(
                    context: &context, at: n.origin,
                    duration: baseDur, metrics: metrics)
                if let acc = n.accidental {
                    AccidentalRenderer.draw(
                        context: &context, accidental: acc,
                        origin: n.origin, metrics: metrics)
                }
                DotRenderer.draw(
                    context: &context,
                    after: n.origin,
                    count: dots,
                    onStaffLine: n.step.isMultiple(of: 2),
                    metrics: metrics)
            }
            // For beamed chords, the placement pass stores the shared
            // beam y into stemOrigin.y so every member's stem reaches
            // the same horizontal beam bar.
            let beamY: CGFloat? = isBeamed ? shift(stemOrigin).y : nil
            // Base duration drives stem/flag choice so a dotted 8th
            // still gets the 8th flag (its raw duration is a fraction).
            StemRenderer.draw(
                context: &context, notes: shiftedNotes,
                direction: stem, duration: baseDur,
                isBeamed: isBeamed, beamY: beamY, metrics: metrics)
        case .textMark(.dynamic, let text, let p):
            TextMarkRenderer.drawDynamic(
                context: &context, text: text,
                origin: shift(p), metrics: metrics)
        case .textMark(.tempo, let text, let p):
            TextMarkRenderer.drawTempo(
                context: &context, text: text,
                origin: shift(p), metrics: metrics)
        case .beam(let from, let to, let direction, let level):
            BeamRenderer.draw(
                context: &context,
                from: shift(from),
                to: shift(to),
                direction: direction,
                level: level,
                metrics: metrics)
        case .fermata(let subtype, let p):
            FermataRenderer.draw(
                context: &context, subtype: subtype,
                origin: shift(p), metrics: metrics)
        case .measureRepeat(let c, let p):
            MeasureRepeatRenderer.draw(
                context: &context, count: c,
                origin: shift(p), metrics: metrics)
        case .arpeggioWiggle(let top, let bot, let sub):
            ArpeggioRenderer.draw(
                context: &context, top: shift(top),
                bottom: shift(bot), subtype: sub,
                metrics: metrics)
        case .spannerSegment(let kind, let from, let to,
                             let cl, let cr, let text):
            SpannerRenderer.draw(
                context: &context, kind: kind,
                from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr,
                text: text, metrics: metrics)
        case .tieArc(let from, let to, let above):
            TieRenderer.draw(
                context: &context,
                from: shift(from), to: shift(to),
                above: above, metrics: metrics)
        case .glissandoLine(let from, let to, let wavy, let text):
            GlissandoRenderer.draw(
                context: &context,
                from: shift(from), to: shift(to),
                wavy: wavy, text: text, metrics: metrics)
        case .marker(let kind, let text, let p):
            MarkerRenderer.draw(
                context: &context, kind: kind, text: text,
                origin: shift(p), metrics: metrics)
        case .jump(let text, let p):
            JumpRenderer.draw(
                context: &context, text: text,
                origin: shift(p), metrics: metrics)
        case .tupletLabel(let from, let to, let text,
                          let bracket, let above):
            TupletRenderer.draw(
                context: &context,
                from: shift(from), to: shift(to),
                text: text,
                hasBracket: bracket,
                isAbove: above,
                metrics: metrics)
        case .note:
            // `.note` case isn't emitted in v1 (chords carry notes via
            // LayoutChordNote). Reserved for future expansion.
            break
        }
    }
}
#endif
