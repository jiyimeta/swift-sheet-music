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
    // swiftlint:disable:next function_parameter_count
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
        into out: inout [DrawCommand],
    ) {
        let glyphSize = ctx.glyphSize * mag
        // Split base duration + dot count for both notehead glyph and
        // augmentation-dot emit.
        let (baseDur, dotCount) = DurationInterpretation.split(duration)
        // ── Noteheads ────────────────────────────────────────────────
        for note in notes {
            emitCenterAnchoredGlyph(
                codepoint: NoteheadGlyph.codepoint(
                    duration: baseDur, headType: note.headType,
                ),
                cxPt: mox + Double(note.origin.x),
                cyPt: moy + Double(note.origin.y),
                sizePt: glyphSize,
                into: &out,
            )
        }
        // ── Augmentation dots ───────────────────────────────────────
        if dotCount > 0 {
            for note in notes {
                emitAugmentationDots(
                    anchorX: mox + Double(note.origin.x),
                    anchorY: moy + Double(note.origin.y),
                    count: dotCount,
                    onStaffLine: note.step.isMultiple(of: 2),
                    sp: ctx.sp,
                    into: &out,
                )
            }
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
            sp: CGFloat(ctx.sp),
        ) else { return }
        let xStem = Double(geometry.xStem)
        let startY = Double(geometry.startY)
        let endY = Double(geometry.endY)
        out.append(.moveTo(x: xStem * ptToMMScale, y: startY * ptToMMScale))
        out.append(.lineTo(x: xStem * ptToMMScale, y: endY * ptToMMScale))
        out.append(.stroke(width: ctx.stemThickness * mag * ptToMMScale))
        // ── Flag (unbeamed only) ─────────────────────────────────────
        guard !isBeamed,
              let flagCp = FlagGlyph.codepoint(duration: baseDur, stem: stem)
        else { return }
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
}
