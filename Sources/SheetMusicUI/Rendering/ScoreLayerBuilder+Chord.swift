// swiftlint:disable file_length
import CoreText
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
    // MARK: - Chord

    static func drawChord( // swiftlint:disable:this function_body_length function_parameter_count
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        isBeamed: Bool,
        tremoloStemExtension: CGFloat = 0,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer,
    ) {
        let (baseDur, dots) = DurationInterpretation.split(duration)
        let shifted = notes.map { n -> LayoutChordNote in
            LayoutChordNote(
                noteID: n.noteID,
                step: n.step,
                accidental: n.accidental,
                origin: CGPoint(
                    x: base.x + n.origin.x,
                    y: base.y + n.origin.y,
                ),
                tieForward: n.tieForward,
                tieBack: n.tieBack,
                hasGlissando: n.hasGlissando,
                headType: n.headType,
                mirror: n.mirror,
                isInvisible: n.isInvisible,
            )
        }
        for n in shifted {
            let glyph = noteheadGlyph(
                for: baseDur, headType: n.headType,
            )
            // Mirrored seconds: notehead, accidental and dots track
            // the visual centre, while ledger lines + stem stay on
            // the chord's natural anchor x.
            let mirrorDx = n.mirrorDx(stem: stem, sp: metrics.sp)
            let visualOrigin = CGPoint(
                x: n.origin.x + mirrorDx, y: n.origin.y,
            )
            if let layer = glyphLayer(
                glyph, at: visualOrigin,
                size: metrics.glyphFontSize,
                height: height,
            ) {
                parent.addSublayer(layer)
                context.attach(layer, to: .note(n.noteID))
            }
            if let acc = n.accidental,
               let accLayer = drawAccidental(
                   accidental: acc, origin: visualOrigin,
                   metrics: metrics, height: height, into: parent,
               )
            {
                context.attach(accLayer, to: .note(n.noteID))
            }
            drawDots(
                after: visualOrigin, count: dots,
                onStaffLine: n.step.isMultiple(of: 2),
                metrics: metrics, height: height, into: parent,
            )
        }
        drawLedgerLines(
            notes: shifted, stem: stem, metrics: metrics,
            height: height, into: parent,
        )
        let shiftedStemOrigin = CGPoint(
            x: base.x + stemOrigin.x,
            y: base.y + stemOrigin.y,
        )
        let beamY: CGFloat? = isBeamed ? shiftedStemOrigin.y : nil
        // Extend the stem by one step (0.5 sp) when a dotted flagged
        // chord has the stem-side outer note sitting on a staff
        // line.  The dot is raised 0.5 sp to clear the line
        // (see `drawDots`), which otherwise lands inside the flag
        // glyph's visual bbox for a stem-up chord.  MuseScore's
        // engraver produces the same effect — the flag moves clear
        // of the raised dot.  For stem-down chords in our always-up
        // dot placement, the dot and flag are on opposite sides of
        // the notehead so no collision arises.
        let hasFlag = !isBeamed && isFlagged(baseDur)
        let stemUpTopOnLine = stem == .up
            && dots > 0
            && hasFlag
            && ((shifted.map(\.step).max() ?? 0).isMultiple(of: 2))
        let dotOnLineExtension: CGFloat = stemUpTopOnLine
            ? metrics.sp * 0.5
            : 0
        drawStem(
            notes: shifted, direction: stem, duration: baseDur,
            isBeamed: isBeamed, beamY: beamY,
            stemExtension: dotOnLineExtension + tremoloStemExtension,
            metrics: metrics, height: height, into: parent,
        )
    }

    /// True when `dur` would normally be drawn with a flag (i.e.,
    /// 8th-note or shorter).  Used by the dot-on-line stem extension.
    private static func isFlagged(_ dur: NoteDuration) -> Bool {
        switch dur {
        case .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            true
        default:
            false
        }
    }

    private static func noteheadGlyph(
        for duration: NoteDuration, headType: String?,
    ) -> Character {
        let cp = NoteheadGlyph.codepoint(
            duration: duration, headType: headType,
        )
        // swiftlint:disable:next force_unwrapping
        return Character(UnicodeScalar(cp)!)
    }

    // MARK: - Accidental

    @discardableResult
    private static func drawAccidental(
        accidental: Accidental, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) -> CAShapeLayer? {
        let glyph: Character
        switch accidental {
        case .sharp: glyph = SMuFLGlyph.accidentalSharp
        case .flat: glyph = SMuFLGlyph.accidentalFlat
        case .natural: glyph = SMuFLGlyph.accidentalNatural
        case .doubleSharp: glyph = SMuFLGlyph.accidentalDoubleSharp
        case .doubleFlat: glyph = SMuFLGlyph.accidentalDoubleFlat
        }
        guard let layer = glyphLayer(
            glyph,
            at: CGPoint(
                x: origin.x - metrics.sp * 1.2,
                y: origin.y,
            ),
            size: metrics.glyphFontSize,
            height: height,
        )
        else { return nil }
        parent.addSublayer(layer)
        return layer
    }

    // MARK: - Dots

    static func drawDots(
        after origin: CGPoint, count: Int,
        onStaffLine: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        guard count > 0 else { return }
        let radius = metrics.sp * 0.22
        let firstOffset = metrics.sp * 1.15
        let spacing = metrics.sp * 0.6
        let y = onStaffLine ? origin.y - metrics.sp / 2 : origin.y
        for i in 0 ..< count {
            let x = origin.x + firstOffset + CGFloat(i) * spacing
            let rect = CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2,
            )
            parent.addSublayer(fillLayer(
                path: CGPath(ellipseIn: rect, transform: nil),
                height: height,
            ))
        }
    }

    // MARK: - Ledger lines

    private static func drawLedgerLines(
        notes: [LayoutChordNote],
        stem: StemDirection,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
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

        /// When a ledger spans a mirrored note, extend its width on
        /// that side by the notehead-width offset so the stroke still
        /// reaches the visible head.
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
            for ledgerStep in stride(
                from: 6, through: topEven, by: 2,
            ) {
                let y = staffMidYAbs
                    - CGFloat(ledgerStep) * metrics.sp / 2
                let (xL, xR) = bounds(forLedgerStep: ledgerStep)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: xL, y: y))
                path.addLine(to: CGPoint(x: xR, y: y))
                parent.addSublayer(strokeLayer(
                    path: path, height: height,
                    lineWidth: lineWidth,
                ))
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
                let path = CGMutablePath()
                path.move(to: CGPoint(x: xL, y: y))
                path.addLine(to: CGPoint(x: xR, y: y))
                parent.addSublayer(strokeLayer(
                    path: path, height: height,
                    lineWidth: lineWidth,
                ))
            }
        }
    }

    // MARK: - Stem + flag

    private static func drawStem(
        notes: [LayoutChordNote],
        direction: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        beamY: CGFloat?,
        stemExtension: CGFloat = 0,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        guard !notes.isEmpty else { return }
        if case .whole = duration { return }
        let xs = notes.map(\.origin.x)
        let ys = notes.map(\.origin.y)
        // Mirrors MuseScore's `TLayout::layoutStem`:
        //
        //   double lineWidthCorrection = item->lineWidthMag() * 0.5;
        //   double lineX = _up * lineWidthCorrection;
        //
        // The stem line is drawn at `stemPosX + lineX` where
        // stemPosX is the SMuFL anchor (stemUpSE.x for stem-up,
        // stemDownNW.x for stem-down) and lineX pulls the stem CENTER
        // inward by half the stem width, so the stem's FAR edge
        // (farther from the notehead body) lands exactly on
        // stemUpSE.x / stemDownNW.x.
        //
        // For Bravura's noteheadBlack at `.center`-anchored (glyph
        // width 1.18 sp, so bbox right = 0.59 sp from notehead
        // centre), the stem's far edge sits at ±0.59 sp from centre,
        // giving a stem centre offset of 0.59 sp - stemWidth/2.
        let stemAttachDx = metrics.sp * 0.59 - metrics.stemThickness / 2
        let xMin = xs.min() ?? 0
        let xMax = xs.max() ?? 0
        let yTop = ys.min() ?? 0
        let yBot = ys.max() ?? 0
        let xStem: CGFloat
        let startY: CGFloat
        let endY: CGFloat
        switch direction {
        case .up:
            xStem = xMax + stemAttachDx
            startY = beamY ?? (yTop - metrics.defaultStemLength - stemExtension)
            endY = yBot
        case .down:
            xStem = xMin - stemAttachDx
            startY = yTop
            endY = beamY ?? (yBot + metrics.defaultStemLength + stemExtension)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: xStem, y: startY))
        path.addLine(to: CGPoint(x: xStem, y: endY))
        parent.addSublayer(strokeLayer(
            path: path, height: height,
            lineWidth: metrics.stemThickness,
        ))

        if isBeamed { return }
        if let flag = flagGlyph(
            for: duration, direction: direction,
        ) {
            let tipY: CGFloat = direction == .up ? startY : endY
            let font = bravuraFont(size: metrics.glyphFontSize)
            let ascent = CTFontGetAscent(font)
            if let layer = glyphLayer(
                flag,
                at: CGPoint(x: xStem, y: tipY - ascent),
                size: metrics.glyphFontSize,
                anchor: CGPoint(x: 0, y: 0),
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func flagGlyph(
        for dur: NoteDuration, direction: StemDirection,
    ) -> Character? {
        switch (dur, direction) {
        case (.eighth, .up): return SMuFLGlyph.flag8thUp
        case (.eighth, .down): return SMuFLGlyph.flag8thDown
        case (.sixteenth, .up): return SMuFLGlyph.flag16thUp
        case (.sixteenth, .down): return SMuFLGlyph.flag16thDown
        case (.thirtySecond, .up): return SMuFLGlyph.flag32ndUp
        case (.thirtySecond, .down): return SMuFLGlyph.flag32ndDown
        case (.sixtyFourth, .up): return SMuFLGlyph.flag64thUp
        case (.sixtyFourth, .down): return SMuFLGlyph.flag64thDown
        default: return nil
        }
    }

    // MARK: - Beam

    static func drawBeam(
        from: CGPoint, to: CGPoint,
        direction: StemDirection, level: Int,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        guard level >= 1 else { return }
        let beamThickness = metrics.sp * 0.5
        let beamGap = metrics.sp * 0.3
        let stackSign: CGFloat = direction == .up ? 1 : -1
        let dy = CGFloat(level - 1) * (beamThickness + beamGap) * stackSign
        let barInner = dy
        let barOuter = dy + beamThickness * stackSign
        let path = CGMutablePath()
        path.move(to: CGPoint(x: from.x, y: from.y + barInner))
        path.addLine(to: CGPoint(x: to.x, y: to.y + barInner))
        path.addLine(to: CGPoint(x: to.x, y: to.y + barOuter))
        path.addLine(to: CGPoint(x: from.x, y: from.y + barOuter))
        path.closeSubpath()
        parent.addSublayer(fillLayer(
            path: path, height: height,
        ))
    }
}
