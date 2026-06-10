import Foundation
import SheetMusicCore
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Chord (noteheads + stem + flag + augmentation dots) emitters.
/// Split out of LayoutBridge+Engraving.swift only to stay under the
/// per-file length cap; helpers remain internal.
extension LayoutBridge {
    // Linear chord-emit orchestration (noteheads, accidentals, dots, stem,
    // flag); a few lines over the body-length budget after adding accidentals.
    // swiftlint:disable:next function_parameter_count function_body_length
    static func encodeChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        // `stemOriginY` is the beam-side stem terminus Y in measure-
        // local coordinates. Passed as a bare Double instead of CGPoint
        // so the signature stays public-internal-friendly even when
        // SheetMusicLayout.CGPoint is the platform stub (Android).
        stemOriginY: Double,
        isBeamed: Bool,
        stemExtension: Double,
        mag: Double,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        metrics ctx: MetricsContext,
        // When false, per-note-invisible noteheads are dropped; when true
        // they are drawn in MuseScore's invisibleColor() = #808080.
        showsInvisible: Bool,
        into out: inout [DrawCommand],
    ) {
        let glyphSize = ctx.glyphSize * mag
        // Split base duration + dot count for both notehead glyph and
        // augmentation-dot emit.
        let (baseDur, dotCount) = DurationInterpretation.split(duration)
        // ── Noteheads / accidentals / dots, partitioned by visibility ──
        // Invisible noteheads are dropped when the toggle is off and grayed
        // when on — mirrors Apple's ScoreCanvas per-note dispatch. A chord
        // with *every* note invisible is routed wholesale to
        // `invisibleElements` upstream, so `visibleNotes` is non-empty here
        // in the normal pass; the stem geometry below still spans all notes,
        // matching the toggle-agnostic stem the layout engine computes.
        let visibleNotes = notes.filter { !$0.isInvisible }
        let invisibleNotes = showsInvisible ? notes.filter(\.isInvisible) : []
        emitNoteGlyphs(
            visibleNotes, baseDuration: baseDur, dotCount: dotCount,
            glyphSize: glyphSize, metrics: ctx, mag: mag,
            measureOriginX: mox, measureOriginY: moy,
            honorColor: true, into: &out,
        )
        if !invisibleNotes.isEmpty {
            out.append(.setColor(argb: LayoutBridge.invisibleARGB))
            emitNoteGlyphs(
                invisibleNotes, baseDuration: baseDur, dotCount: dotCount,
                glyphSize: glyphSize, metrics: ctx, mag: mag,
                measureOriginX: mox, measureOriginY: moy,
                honorColor: false, into: &out,
            )
            out.append(.setColor(argb: LayoutBridge.blackARGB))
        }
        // Whole notes (and lower-resolution rests) are stemless.
        if case .whole = baseDur { return }
        // ── Stem ─────────────────────────────────────────────────────
        let noteOrigins = notes.map { CGPoint(
            x: CGFloat(mox + Double($0.origin.x)),
            y: CGFloat(moy + Double($0.origin.y)),
        )
        }
        // For beamed chords the stem extends to the shared beam Y instead
        // of each chord's own natural stem-top. World Y = moy + stemOriginY.
        let beamY: CGFloat? = isBeamed
            ? CGFloat(moy + stemOriginY)
            : nil
        guard let geometry = StemGeometry.compute(
            noteOrigins: noteOrigins,
            direction: stem,
            beamY: beamY,
            defaultStemLength: CGFloat(ctx.defaultStemLength * mag),
            stemExtension: CGFloat(stemExtension),
            // `attachDx` inside `StemGeometry` scales with `sp`; for a
            // mag-reduced grace chord the stem must attach at the
            // SHRUNKEN notehead's edge, so feed the magnified spatium
            // (`sp * mag`). Apple's `drawStem` uses `scaled.sp`
            // (= `sp * mag`) for the same reason. For main chords
            // `mag == 1`, so this is a no-op.
            sp: CGFloat(ctx.sp * mag),
        ) else { return }
        let xStem = Double(geometry.xStem)
        let startY = Double(geometry.startY)
        let endY = Double(geometry.endY)
        // Stem + flag inherit the chord's notehead color (first colored
        // note wins) — matches Apple's `ScoreLayerBuilder` `stemColor`.
        // MuseScore stores `<Stem>/<Hook>` color separately but in practice
        // it tracks the note.
        let stemARGB = notes.compactMap(\.color).first
            .flatMap(LayoutBridge.argb(from:))
        if let stemARGB { out.append(.setColor(argb: stemARGB)) }
        out.append(.moveTo(x: xStem * ptToMMScale, y: startY * ptToMMScale))
        out.append(.lineTo(x: xStem * ptToMMScale, y: endY * ptToMMScale))
        out.append(.stroke(width: ctx.stemThickness * mag * ptToMMScale))
        // ── Flag (unbeamed only) ─────────────────────────────────────
        if !isBeamed,
           let flagCp = FlagGlyph.codepoint(duration: baseDur, stem: stem)
        {
            let tipY = stem == .up ? startY : endY
            // Apple's StemRenderer draws the flag with `.topLeading` so the
            // glyph's baseline anchor sits on the stem tip. On Android the
            // wire format anchors at baseline-leading natively — emit at
            // (xStem, tipY) directly, without the center-anchor offset.
            out.append(.glyph(
                codepoint: flagCp,
                x: xStem * ptToMMScale,
                y: tipY * ptToMMScale,
                size: glyphSize * ptToMMScale,
                fontId: .smufl,
            ))
        }
        if stemARGB != nil { out.append(.setColor(argb: LayoutBridge.blackARGB)) }
    }

    /// Emit noteheads + accidentals + augmentation dots for a subset of a
    /// chord's notes. Factored so the chord encoder can run it once for the
    /// visible notes (`honorColor: true`) and again, wrapped in
    /// `invisibleARGB`, for the per-note-invisible ones (`honorColor:
    /// false`, so the gray override wins over any author `<color>`).
    ///
    /// When `honorColor` is set, each note carrying an author color
    /// (`Note.elementProperties.color`) has its notehead + accidental +
    /// dots wrapped in a `setColor` / reset-to-black pair — matching the
    /// Apple `ScoreLayerBuilder` per-note `headColor`. Uncolored notes
    /// paint in the ambient color.
    static func emitNoteGlyphs(
        _ notes: [LayoutChordNote],
        baseDuration baseDur: NoteDuration,
        dotCount: Int,
        glyphSize: Double,
        metrics ctx: MetricsContext,
        mag: Double,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        honorColor: Bool,
        into out: inout [DrawCommand],
    ) {
        for note in notes {
            let argb = honorColor
                ? note.color.flatMap(LayoutBridge.argb(from:))
                : nil
            if let argb { out.append(.setColor(argb: argb)) }
            emitCenterAnchoredGlyph(
                codepoint: NoteheadGlyph.codepoint(
                    duration: baseDur, headType: note.headType,
                ),
                cxPt: mox + Double(note.origin.x),
                cyPt: moy + Double(note.origin.y),
                sizePt: glyphSize,
                into: &out,
            )
            // Accidental: a single Bravura glyph center-anchored 1.2 sp left
            // of the notehead (the offset scaled by `mag` so grace-note
            // accidentals stay glued to their reduced head). doubleSharp /
            // doubleFlat are included even though they never come from a key
            // signature. Glyph table is shared via `AccidentalGlyph` so iOS
            // and Android can't disagree.
            if let accidental = note.accidental {
                emitCenterAnchoredGlyph(
                    codepoint: AccidentalGlyph.codepoint(accidental),
                    cxPt: mox + Double(note.origin.x) - ctx.sp * 1.2 * mag,
                    cyPt: moy + Double(note.origin.y),
                    sizePt: glyphSize,
                    into: &out,
                )
            }
            if dotCount > 0 {
                emitAugmentationDots(
                    anchorX: mox + Double(note.origin.x),
                    anchorY: moy + Double(note.origin.y),
                    count: dotCount,
                    onStaffLine: note.step.isMultiple(of: 2),
                    sp: ctx.sp,
                    into: &out,
                )
            }
            if argb != nil { out.append(.setColor(argb: LayoutBridge.blackARGB)) }
        }
    }

    /// Emit `count` filled-disc augmentation dots after a notehead /
    /// rest anchor. Wire format has no `fillCircle`; approximated as a
    /// filled rect of width `2 * radius` (square reads as a dot to the
    /// eye at typical staff sizes).
    static func emitAugmentationDots(
        anchorX: Double, anchorY: Double,
        count: Int, onStaffLine: Bool,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        let radius = Double(DotGeometry.radiusSp) * sp
        let centers = DotGeometry.centers(
            after: CGPoint(x: CGFloat(anchorX), y: CGFloat(anchorY)),
            count: count, onStaffLine: onStaffLine, sp: CGFloat(sp),
        )
        for center in centers {
            out.append(.fillRect(
                x: (Double(center.x) - radius) * ptToMMScale,
                y: (Double(center.y) - radius) * ptToMMScale,
                w: 2 * radius * ptToMMScale,
                h: 2 * radius * ptToMMScale,
            ))
        }
    }

    /// Stroke the acciaccatura stem-slash for a grace chord. Endpoints come
    /// from the shared `GraceSlashGeometry` (Bravura anchor table) so iOS
    /// and Android draw the identical slash. All metrics are mag-scaled so
    /// the slash matches the reduced grace stem.
    static func emitGraceSlash(
        notes: [LayoutChordNote],
        stem: StemDirection,
        mag: Double,
        measureOriginX mox: Double, measureOriginY moy: Double,
        metrics ctx: MetricsContext,
        into out: inout [DrawCommand],
    ) {
        let origins = notes.map { CGPoint(
            x: CGFloat(mox + Double($0.origin.x)),
            y: CGFloat(moy + Double($0.origin.y)),
        )
        }
        guard let slash = GraceSlashGeometry.slash(
            noteOrigins: origins,
            stem: stem,
            sp: CGFloat(ctx.sp * mag),
            defaultStemLength: CGFloat(ctx.defaultStemLength * mag),
            stemThickness: CGFloat(ctx.stemThickness * mag),
        ) else { return }
        out.append(.moveTo(
            x: Double(slash.from.x) * ptToMMScale,
            y: Double(slash.from.y) * ptToMMScale,
        ))
        out.append(.lineTo(
            x: Double(slash.to.x) * ptToMMScale,
            y: Double(slash.to.y) * ptToMMScale,
        ))
        out.append(.stroke(width: ctx.stemThickness * mag * ptToMMScale))
    }
}
