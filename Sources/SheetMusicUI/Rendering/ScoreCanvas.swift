// swiftlint:disable file_length
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// A single system rendered in its own Canvas. Used by `ScoreView`
/// inside a `LazyVStack` so only visible systems are drawn — the
/// biggest performance win for long scores during scrolling.
@available(macOS 15.0, *)
struct SystemCanvas: View {
    let system: LayoutSystem
    let metrics: StaffMetrics

    private static let overlap: CGFloat = 1

    var body: some View {
        let h = system.size.height + Self.overlap
        Canvas(opaque: true, rendersAsynchronously: true) { context, _ in
            context.fill(
                Path(CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: system.size.width, height: h,
                    ),
                )),
                with: .color(.white),
            )
            var local = context
            local.translateBy(x: -system.origin.x, y: -system.origin.y)
            ScoreCanvasDrawing.drawSystem(
                system, metrics: metrics, into: &local,
            )
        }
        .frame(
            width: system.size.width,
            height: h,
            alignment: .topLeading,
        )
        .environment(\.colorScheme, .light)
    }
}

/// A horizontal slice of a single system. Used by `ScoreView` in
/// horizontal-scroll mode inside a `LazyHStack` so only visible
/// portions of a long system are rasterised.
@available(macOS 15.0, *)
struct SystemSliceCanvas: View {
    let system: LayoutSystem
    let metrics: StaffMetrics
    let xStart: CGFloat
    let sliceWidth: CGFloat

    var body: some View {
        let h = system.size.height + 1
        Canvas(opaque: true, rendersAsynchronously: true) { context, _ in
            context.fill(
                Path(CGRect(
                    origin: .zero,
                    size: CGSize(width: sliceWidth, height: h),
                )),
                with: .color(.white),
            )
            var local = context
            local.translateBy(
                x: -system.origin.x - xStart,
                y: -system.origin.y,
            )
            let absX = system.origin.x + xStart
            ScoreCanvasDrawing.drawSystem(
                system, metrics: metrics, into: &local,
                visibleX: absX ... (absX + sliceWidth),
            )
        }
        .frame(width: sliceWidth, height: h, alignment: .topLeading)
        .environment(\.colorScheme, .light)
    }
}

/// Static drawing routines shared between single-system and full-
/// document canvases. Factored out of `ScoreCanvas` so `SystemCanvas`
/// can call them too.
@available(macOS 15.0, *)
public enum ScoreCanvasDrawing { // swiftlint:disable:this type_body_length
    public static func drawSystem( // swiftlint:disable:this function_body_length
        _ system: LayoutSystem,
        metrics: StaffMetrics,
        into context: inout GraphicsContext,
        visibleX: ClosedRange<CGFloat>? = nil,
    ) {
        // Staves
        let staffEndX = StaffRenderer.endX(for: system)
        for origin in system.staffOrigins {
            StaffRenderer.draw(
                context: &context,
                origin: CGPoint(
                    x: system.origin.x + origin.x,
                    y: system.origin.y + origin.y,
                ),
                width: staffEndX - origin.x,
                metrics: metrics,
            )
        }
        // System barline — vertical line at the system's left edge
        // joining all staves.
        if let first = system.staffOrigins.first,
           let last = system.staffOrigins.last
        {
            let x = system.origin.x + first.x
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: system.origin.y + first.y))
            bar.addLine(to: CGPoint(
                x: x,
                y: system.origin.y + last.y + metrics.staffHeight,
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
                    into: &context,
                )
            }
            if !measure.invisibleElements.isEmpty {
                var grey = context
                // MuseScore invisibleColor() = #808080; 50% black on the
                // white score background is the exact equivalent.
                grey.opacity = 0.5
                for element in measure.invisibleElements {
                    drawElement(
                        element,
                        base: base,
                        metrics: metrics,
                        into: &grey,
                    )
                }
            }
            for el in measure.markers {
                drawElement(
                    el,
                    base: base,
                    metrics: metrics,
                    into: &context,
                )
            }
            for el in measure.jumps {
                drawElement(
                    el,
                    base: base,
                    metrics: metrics,
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
                into: &context,
            )
        }
        if !system.invisibleSpanners.isEmpty {
            var grey = context
            // MuseScore invisibleColor() = #808080; 50% black on the
            // white score background is the exact equivalent.
            grey.opacity = 0.5
            for el in system.invisibleSpanners {
                drawElement(
                    el,
                    base: system.origin,
                    metrics: metrics,
                    into: &grey,
                )
            }
        }
    }

    static func drawElement( // swiftlint:disable:this function_body_length
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
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
        case let .keySignature(s, f, p):
            KeySignatureRenderer.draw(
                context: &context, sharps: s, flats: f,
                origin: shift(p), metrics: metrics,
            )
        case let .timeSignature(n, d, p):
            TimeSignatureRenderer.draw(
                context: &context, numerator: n, denominator: d,
                origin: shift(p), metrics: metrics,
            )
        case let .barLine(s, p):
            BarLineRenderer.draw(
                context: &context, subtype: s,
                origin: shift(p), metrics: metrics,
            )
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
        ):
            let (baseDur, dots) = DurationInterpretation.split(dur)
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    noteID: $0.noteID,
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando,
                    headType: $0.headType,
                    mirror: $0.mirror,
                )
            }
            for n in shiftedNotes {
                let mirrorDx = n.mirrorDx(stem: stem, sp: metrics.sp)
                let visualOrigin = CGPoint(
                    x: n.origin.x + mirrorDx, y: n.origin.y,
                )
                NoteheadRenderer.drawHead(
                    context: &context, at: visualOrigin,
                    duration: baseDur, headType: n.headType,
                    metrics: metrics,
                )
                if let acc = n.accidental {
                    AccidentalRenderer.draw(
                        context: &context, accidental: acc,
                        origin: visualOrigin, metrics: metrics,
                    )
                }
                DotRenderer.draw(
                    context: &context,
                    after: visualOrigin,
                    count: dots,
                    onStaffLine: n.step.isMultiple(of: 2),
                    metrics: metrics,
                )
            }
            // Ledger lines
            drawLedgerLines(
                context: &context,
                notes: shiftedNotes, stem: stem,
                metrics: metrics,
            )
            let beamY: CGFloat? = isBeamed ? shift(stemOrigin).y : nil
            StemRenderer.draw(
                context: &context, notes: shiftedNotes,
                direction: stem, duration: baseDur,
                isBeamed: isBeamed, beamY: beamY,
                stemExtension: stemExt, metrics: metrics,
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
        case let .textMark(.lyrics, text, p):
            TextMarkRenderer.drawLyric(
                context: &context, text: text,
                origin: shift(p), metrics: metrics,
            )
        case let .beam(from, to, direction, level):
            BeamRenderer.draw(
                context: &context,
                from: shift(from),
                to: shift(to),
                direction: direction,
                level: level,
                metrics: metrics,
            )
        case let .fermata(subtype, p):
            FermataRenderer.draw(
                context: &context, subtype: subtype,
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
        case let .staffText(text, p, color, _):
            StaffTextRenderer.draw(
                context: &context, text: text,
                origin: shift(p),
                color: color,
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
            // Drawn by MultiMeasureRestRenderer in Task 10/11. Stub for
            // exhaustive switch; Task 11 replaces this with the real call.
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
        case .note, .graceChord:
            break
        }
    }

    // MARK: - Ledger lines

    static func drawLedgerLines(
        context: inout GraphicsContext,
        notes: [LayoutChordNote],
        stem: StemDirection,
        metrics: StaffMetrics,
    ) {
        guard let ref = notes.first else { return }
        let allSteps = notes.map(\.step)
        let maxStep = allSteps.max() ?? 0
        let minStep = allSteps.min() ?? 0
        guard maxStep > 4 || minStep < -4 else { return }

        let staffMidYAbs = ref.origin.y
            + CGFloat(ref.step) * metrics.sp / 2
        let chordX = ref.origin.x
        let halfWidth = metrics.sp * 0.9
        let lineWidth = metrics.staffLineThickness * 1.5

        func bounds(forLedgerStep ledger: Int) -> (CGFloat, CGFloat) {
            var leftExt: CGFloat = 0
            var rightExt: CGFloat = 0
            for n in notes
                where abs(n.step - ledger) <= 1 && n.mirror
            {
                let dx = n.mirrorDx(stem: stem, sp: metrics.sp)
                if dx > 0 { rightExt = max(rightExt, dx) } else { leftExt = max(leftExt, -dx) }
            }
            return (
                chordX - halfWidth - leftExt,
                chordX + halfWidth + rightExt,
            )
        }

        if maxStep > 4 {
            let topEven = maxStep.isMultiple(of: 2)
                ? maxStep : maxStep - 1
            for ledgerStep in stride(from: 6, through: topEven, by: 2) {
                let y = staffMidYAbs
                    - CGFloat(ledgerStep) * metrics.sp / 2
                let (xL, xR) = bounds(forLedgerStep: ledgerStep)
                var p = Path()
                p.move(to: CGPoint(x: xL, y: y))
                p.addLine(to: CGPoint(x: xR, y: y))
                context.stroke(
                    p, with: .color(.primary), lineWidth: lineWidth,
                )
            }
        }

        if minStep < -4 {
            let botEven = minStep.isMultiple(of: 2)
                ? minStep : minStep + 1
            for ledgerStep in stride(
                from: -6, through: botEven, by: -2,
            ) {
                let y = staffMidYAbs
                    - CGFloat(ledgerStep) * metrics.sp / 2
                let (xL, xR) = bounds(forLedgerStep: ledgerStep)
                var p = Path()
                p.move(to: CGPoint(x: xL, y: y))
                p.addLine(to: CGPoint(x: xR, y: y))
                context.stroke(
                    p, with: .color(.primary), lineWidth: lineWidth,
                )
            }
        }
    }
}
