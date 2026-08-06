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
        // Selection re-encode — see `LayoutBridge.buildCommands(layout:tint:)`'s doc comment. Resolved
        // per-note against `LayoutChordNote.noteID` in `emitNoteGlyphs`.
        tint: (argb: UInt32, ids: Set<ScoreItemID>)?,
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
            stem: stem,
            glyphSize: glyphSize, metrics: ctx, mag: mag,
            measureOriginX: mox, measureOriginY: moy,
            honorColor: true, tint: tint, into: &out,
        )
        if !invisibleNotes.isEmpty {
            out.append(.setColor(argb: LayoutBridge.invisibleARGB))
            emitNoteGlyphs(
                invisibleNotes, baseDuration: baseDur, dotCount: dotCount,
                stem: stem,
                glyphSize: glyphSize, metrics: ctx, mag: mag,
                measureOriginX: mox, measureOriginY: moy,
                honorColor: false, tint: tint, resetArgb: LayoutBridge.invisibleARGB, into: &out,
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
    ///
    /// A selected note (`.note(note.noteID)` in `tint.ids`) overrides all of that: its whole visual footprint —
    /// notehead, parenthesis glyphs, accidental, augmentation dots — is bracketed in `tint.argb` instead,
    /// regardless of any author color, mirroring the granularity decision `ScoreLayerBuilder+Chord.swift`
    /// makes (a chord where only one notehead is selected tints that notehead alone, not the whole chord; see
    /// `LayoutBridge.tintColor(for:tint:)`'s doc comment for why this file does not re-derive that rule).
    /// `resetArgb` is the color to restore afterward — `blackARGB` normally, or `invisibleARGB` when this call
    /// is the per-note-invisible pass inside an ambient gray group, so tinting one invisible note doesn't leave
    /// its still-invisible neighbors painting in black.
    static func emitNoteGlyphs( // swiftlint:disable:this function_body_length
        _ notes: [LayoutChordNote],
        baseDuration baseDur: NoteDuration,
        dotCount: Int,
        stem: StemDirection,
        glyphSize: Double,
        metrics ctx: MetricsContext,
        mag: Double,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        honorColor: Bool,
        tint: (argb: UInt32, ids: Set<ScoreItemID>)?,
        resetArgb: UInt32 = LayoutBridge.blackARGB,
        into out: inout [DrawCommand],
    ) {
        for note in notes {
            let selectedArgb = LayoutBridge.tintColor(for: .note(note.noteID), tint: tint)
            let argb = selectedArgb ?? (
                honorColor ? note.color.flatMap(LayoutBridge.argb(from:)) : nil
            )
            if let argb { out.append(.setColor(argb: argb)) }
            emitCenterAnchoredGlyph(
                codepoint: NoteheadGlyph.codepoint(
                    duration: baseDur, headType: note.headType, stemUp: stem == .up,
                ),
                cxPt: mox + Double(note.origin.x),
                cyPt: moy + Double(note.origin.y),
                sizePt: glyphSize,
                into: &out,
            )
            // Round parentheses around the notehead. Shares glyph + offset
            // helpers with the Apple paths so all three renderers agree.
            let (leftParenCp, rightParenCp) = NoteheadParenthesisGlyph.glyphs(
                for: note.parentheses,
            )
            if leftParenCp != nil || rightParenCp != nil {
                let parenFont = LayoutFont(
                    face: SMuFLFamily.bravura,
                    pointSize: CGFloat(glyphSize),
                )
                let noteheadCenterX = mox + Double(note.origin.x)
                let noteheadCenterY = moy + Double(note.origin.y)
                if let leftParenCp, let lSc = UnicodeScalar(leftParenCp) {
                    let adv = Double(FontMetrics.provider.typographicWidth(
                        text: String(lSc), font: parenFont,
                    ))
                    let cx = Double(NoteheadParenthesisPlacement.leftParenCenterX(
                        noteheadCenterX: CGFloat(noteheadCenterX),
                        parenAdvance: CGFloat(adv),
                        sp: CGFloat(ctx.sp * mag),
                    ))
                    emitCenterAnchoredGlyph(
                        codepoint: leftParenCp,
                        cxPt: cx, cyPt: noteheadCenterY,
                        sizePt: glyphSize, into: &out,
                    )
                }
                if let rightParenCp, let rSc = UnicodeScalar(rightParenCp) {
                    let adv = Double(FontMetrics.provider.typographicWidth(
                        text: String(rSc), font: parenFont,
                    ))
                    let cx = Double(NoteheadParenthesisPlacement.rightParenCenterX(
                        noteheadCenterX: CGFloat(noteheadCenterX),
                        parenAdvance: CGFloat(adv),
                        sp: CGFloat(ctx.sp * mag),
                    ))
                    emitCenterAnchoredGlyph(
                        codepoint: rightParenCp,
                        cxPt: cx, cyPt: noteheadCenterY,
                        sizePt: glyphSize, into: &out,
                    )
                }
            }
            // Accidental + optional bracket enclosure: measured-width placement
            // via `AccidentalPlacement.leftEdgeX` so iOS and Android agree on
            // the offset. Glyph table is shared via `AccidentalGlyph`.
            if let accidental = note.accidental {
                let accCp = AccidentalGlyph.codepoint(accidental)
                guard let accSc = UnicodeScalar(accCp) else { continue }
                let glyphFont = LayoutFont(
                    face: SMuFLFamily.bravura,
                    pointSize: CGFloat(glyphSize),
                )
                let accAdv = Double(FontMetrics.provider.typographicWidth(
                    text: String(accSc), font: glyphFont,
                ))
                var leftBracketAdv: Double = 0
                var rightBracketAdv: Double = 0
                var leftBracketCp: UInt32?
                var rightBracketCp: UInt32?
                if let (lCp, rCp) = AccidentalGlyph.enclosure(note.accidentalBracket),
                   let lSc = UnicodeScalar(lCp), let rSc = UnicodeScalar(rCp)
                {
                    leftBracketCp = lCp
                    rightBracketCp = rCp
                    leftBracketAdv = Double(FontMetrics.provider.typographicWidth(
                        text: String(lSc), font: glyphFont,
                    ))
                    rightBracketAdv = Double(FontMetrics.provider.typographicWidth(
                        text: String(rSc), font: glyphFont,
                    ))
                }
                let totalAdv = leftBracketAdv + accAdv + rightBracketAdv
                // Notehead left edge = center - half-advance. Source the
                // half-advance from `StemGeometry.attachDx` (Bravura
                // noteheadBlack half-width) so this matches the Apple
                // render paths exactly even if `attachDx` is retuned. The
                // `sp * mag` argument mirrors Apple's `metrics.sp` (already
                // mag-scaled) — `attachDx` is linear in `sp`, so this equals
                // `attachDx(sp: ctx.sp) * mag`.
                let noteheadHalfAdv = Double(StemGeometry.attachDx(
                    sp: CGFloat(ctx.sp * mag),
                ))
                let noteheadLeftX = mox + Double(note.origin.x) - noteheadHalfAdv
                let leftEdgeX = Double(AccidentalPlacement.leftEdgeX(
                    noteheadLeftX: CGFloat(noteheadLeftX),
                    advanceWidth: CGFloat(totalAdv),
                    sp: CGFloat(ctx.sp * mag),
                ))
                if let lCp = leftBracketCp {
                    emitCenterAnchoredGlyph(
                        codepoint: lCp,
                        cxPt: leftEdgeX + leftBracketAdv / 2,
                        cyPt: moy + Double(note.origin.y),
                        sizePt: glyphSize,
                        into: &out,
                    )
                }
                emitCenterAnchoredGlyph(
                    codepoint: accCp,
                    cxPt: leftEdgeX + leftBracketAdv + accAdv / 2,
                    cyPt: moy + Double(note.origin.y),
                    sizePt: glyphSize,
                    into: &out,
                )
                if let rCp = rightBracketCp {
                    emitCenterAnchoredGlyph(
                        codepoint: rCp,
                        cxPt: leftEdgeX + leftBracketAdv + accAdv + rightBracketAdv / 2,
                        cyPt: moy + Double(note.origin.y),
                        sizePt: glyphSize,
                        into: &out,
                    )
                }
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
            if argb != nil { out.append(.setColor(argb: resetArgb)) }
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
