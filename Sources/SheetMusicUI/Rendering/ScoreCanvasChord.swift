import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Chord + grace-chord drawing for the SwiftUI Canvas renderer.
///
/// Factored out of `ScoreCanvas.drawElement` so `.chord` and
/// `.graceChord` share one implementation of the notehead / accidental /
/// dot / stem / flag stack — the same arrangement the CALayer renderer
/// uses (`ScoreLayerBuilder+Chord` + `GraceChordRenderer`).
@available(macOS 15.0, *)
extension ScoreCanvasDrawing {
    // swiftlint:disable:next function_parameter_count function_body_length
    static func drawChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        isBeamed: Bool,
        stemExtension: CGFloat = 0,
        stemIsInvisible: Bool = false,
        base: CGPoint,
        metrics: StaffMetrics,
        showsInvisibleElements: Bool,
        into context: inout GraphicsContext,
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        let (baseDur, dots) = DurationInterpretation.split(duration)
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
                isInvisible: $0.isInvisible,
                color: $0.color,
                accidentalBracket: $0.accidentalBracket,
                parentheses: $0.parentheses,
            )
        }
        // Stem / flag inherit the chord's notehead color (the first
        // colored note wins) — MuseScore stores `<Stem>/<Hook>`
        // color separately but in practice it matches the note.
        let stemColor: Color = shiftedNotes
            .compactMap(\.color).first
            .map { Color(scoreColor: $0) } ?? .primary
        // Ledger lines are no longer drawn here: `LedgerLinePass`
        // emits them as `.ledgerLine` elements immediately before
        // this chord, so they still render behind the chord's ink
        // while the geometry lives in one place.
        for n in shiftedNotes {
            let mirrorDx = n.mirrorDx(stem: stem, sp: metrics.sp)
            let visualOrigin = CGPoint(
                x: n.origin.x + mirrorDx, y: n.origin.y,
            )
            if n.isInvisible {
                // Toggle off + per-note hidden: skip the head /
                // accidental / dots entirely (stem geometry still
                // sees the note via shiftedNotes below). Slot is
                // preserved by the chord's natural origin.
                guard showsInvisibleElements else { continue }
                // MuseScore invisibleColor() = #808080; 50% black on the
                // white score background is the exact equivalent.
                var gray = context
                gray.opacity = 0.5
                drawNote(
                    n, at: visualOrigin, duration: baseDur, stem: stem,
                    dots: dots, color: .primary,
                    metrics: metrics, into: &gray,
                )
            } else {
                let headColor: Color = n.color
                    .map { Color(scoreColor: $0) } ?? .primary
                drawNote(
                    n, at: visualOrigin, duration: baseDur, stem: stem,
                    dots: dots, color: headColor,
                    metrics: metrics, into: &context,
                )
            }
        }
        let beamY: CGFloat? = isBeamed ? shift(stemOrigin).y : nil
        // Stem visibility (MSCX `<Stem><visible>`) is independent of
        // notehead visibility. When the stem is hidden:
        //   * toggle off → skip stem + flag entirely.
        //   * toggle on  → gray both at 50%.
        // Beam suppression on hidden-stem chords is a separate
        // concern (would require `<Beam><visible>`).
        if stemIsInvisible {
            if showsInvisibleElements {
                var gray = context
                gray.opacity = 0.5
                StemRenderer.draw(
                    context: &gray, notes: shiftedNotes,
                    direction: stem, duration: baseDur,
                    isBeamed: isBeamed, beamY: beamY,
                    stemExtension: stemExtension, color: stemColor,
                    metrics: metrics,
                )
            }
        } else {
            StemRenderer.draw(
                context: &context, notes: shiftedNotes,
                direction: stem, duration: baseDur,
                isBeamed: isBeamed, beamY: beamY,
                stemExtension: stemExtension, color: stemColor,
                metrics: metrics,
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    /// Notehead + optional parentheses, accidental and augmentation dots
    /// for one already-shifted chord note.
    private static func drawNote(
        _ note: LayoutChordNote,
        at visualOrigin: CGPoint,
        duration baseDur: NoteDuration,
        stem: StemDirection,
        dots: Int,
        color: Color,
        metrics: StaffMetrics,
        into context: inout GraphicsContext,
    ) {
        NoteheadRenderer.drawHead(
            context: &context, at: visualOrigin,
            duration: baseDur, headType: note.headType,
            stemUp: stem == .up,
            color: color,
            metrics: metrics,
        )
        NoteheadParenthesisRenderer.draw(
            context: &context, parentheses: note.parentheses,
            origin: visualOrigin, color: color,
            metrics: metrics,
        )
        if let acc = note.accidental {
            AccidentalRenderer.draw(
                context: &context, accidental: acc,
                bracket: note.accidentalBracket,
                origin: visualOrigin, metrics: metrics,
            )
        }
        DotRenderer.draw(
            context: &context,
            after: visualOrigin,
            count: dots,
            onStaffLine: note.step.isMultiple(of: 2),
            color: color,
            metrics: metrics,
        )
    }

    // swiftlint:disable:next function_parameter_count
    /// Draw a `LayoutElement.graceChord` by reusing `drawChord` at a
    /// `mag`-scaled `StaffMetrics`, then stroking the acciaccatura slash.
    /// Mirrors the CALayer path's `ScoreLayerBuilder.drawGraceChord`.
    static func drawGraceChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasSlash: Bool,
        mag: CGFloat,
        base: CGPoint,
        metrics: StaffMetrics,
        showsInvisibleElements: Bool,
        into context: inout GraphicsContext,
    ) {
        // Every dimension on `StaffMetrics` derives from `sp =
        // staffSize/4`, so feeding `staffSize * mag` shrinks notehead /
        // stem / flag proportionally. The grace's y-positions (already in
        // parent-staff coordinates from the layout step) pass through
        // untouched, so the glyphs sit on the parent staff — only the
        // GLYPH sizes shrink.
        let scaled = StaffMetrics(staffSize: metrics.staffHeight * mag)
        drawChord(
            notes: notes, duration: duration, stem: stem,
            stemOrigin: stemOrigin, isBeamed: false,
            base: base, metrics: scaled,
            showsInvisibleElements: showsInvisibleElements,
            into: &context,
        )
        guard hasSlash else { return }
        // Slash endpoints come from the shared `GraceSlashGeometry`
        // (Bravura `graceNoteSlash` anchor table) so this renderer, the
        // CALayer renderer and the Android bridge draw the identical
        // slash. `scaled` already folds in `mag`, so the geometry matches
        // the reduced grace stem.
        guard let slash = GraceSlashGeometry.slash(
            noteOrigins: notes.map(\.origin),
            stem: stem,
            sp: scaled.sp,
            defaultStemLength: scaled.defaultStemLength,
            stemThickness: scaled.stemThickness,
        ) else { return }
        var path = Path()
        path.move(to: CGPoint(
            x: base.x + slash.from.x, y: base.y + slash.from.y,
        ))
        path.addLine(to: CGPoint(
            x: base.x + slash.to.x, y: base.y + slash.to.y,
        ))
        // Match the rendered grace stem's weight so the slash reads at
        // on-screen DPIs. MuseScore's `stemSlashThickness = 0.125 sp ×
        // mag` aliases below one device pixel.
        context.stroke(
            path,
            with: .color(.primary),
            lineWidth: scaled.stemThickness,
        )
    }
}
