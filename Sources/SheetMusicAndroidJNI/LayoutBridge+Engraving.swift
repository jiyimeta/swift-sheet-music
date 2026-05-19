import Foundation
import SheetMusicCore
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Per-element encoders for the time-signature and key-signature
/// branches of `LayoutBridge.encodeElement`. Split out of the main file
/// only to keep the bridge under the per-file length cap; the helpers
/// remain `internal` and are not part of any public API.
extension LayoutBridge {
    /// Points to millimetres scale factor — same constant as
    /// `LayoutBridge.ptToMM`, re-declared here to avoid widening that
    /// constant's visibility just for this split.
    static let ptToMMScale = 25.4 / 72.0

    /// Emit a SMuFL glyph whose position was computed assuming Apple's
    /// `.center` anchor (visual ink centre at `(cxPt, cyPt)`).
    /// `Canvas.drawText` on Android anchors at the baseline-leading
    /// corner; the offset comes from the glyph's y-up bbox half-extent
    /// via `GlyphAnchor.centerToBaselineLeading`.
    static func emitCenterAnchoredGlyph(
        codepoint: UInt32,
        cxPt: Double,
        cyPt: Double,
        sizePt: Double,
        into out: inout [DrawCommand],
    ) {
        let bbox = FontMetrics.provider.glyphPathBoundingBox(
            font: LayoutFont(
                face: SMuFLFamily.bravura, pointSize: CGFloat(sizePt),
            ),
            codepoint: UInt16(codepoint),
        )
        let (dx, dy) = GlyphAnchor.centerToBaselineLeading(bbox: bbox)
        out.append(.glyph(
            codepoint: codepoint,
            x: (cxPt + Double(dx)) * ptToMMScale,
            y: (cyPt + Double(dy)) * ptToMMScale,
            size: sizePt * ptToMMScale,
            fontId: .smufl,
        ))
    }

    // swiftlint:disable:next function_parameter_count
    static func encodeTimeSignature(
        numerator: Int,
        denominator: Int,
        originX: Double,
        originY: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        let advance = TimeSignatureLayout.digitAdvance(sp: CGFloat(sp))
        let (numDx, denDx, _) = TimeSignatureLayout.rowOffsets(
            numerator: numerator, denominator: denominator,
            sp: CGFloat(sp),
        )
        let numY = originY
            + Double(TimeSignatureLayout.numeratorDy(sp: CGFloat(sp)))
        let denY = originY
            + Double(TimeSignatureLayout.denominatorDy(sp: CGFloat(sp)))
        emitTimeSigRow(
            value: numerator,
            rowOriginX: originX + Double(numDx),
            rowY: numY,
            advance: Double(advance),
            glyphSize: glyphSize,
            into: &out,
        )
        emitTimeSigRow(
            value: denominator,
            rowOriginX: originX + Double(denDx),
            rowY: denY,
            advance: Double(advance),
            glyphSize: glyphSize,
            into: &out,
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func emitTimeSigRow(
        value: Int,
        rowOriginX: Double,
        rowY: Double,
        advance: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        for (i, ch) in String(value).enumerated() {
            let digit = Int(String(ch)) ?? 0
            emitCenterAnchoredGlyph(
                codepoint: SMuFLCodepoint.timeSigDigit(digit),
                cxPt: rowOriginX + Double(i) * advance,
                cyPt: rowY,
                sizePt: glyphSize,
                into: &out,
            )
        }
    }

    // MARK: - Chord (noteheads + stem + flag)

    // swiftlint:disable:next function_parameter_count
    static func encodeChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        isBeamed: Bool,
        stemExtension: Double,
        mag: Double,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        metrics ctx: MetricsContext,
        into out: inout [DrawCommand],
    ) {
        let glyphSize = ctx.glyphSize * mag
        // ── Noteheads ────────────────────────────────────────────────
        let headCp = noteheadCodepoint(duration: duration)
        for note in notes {
            emitCenterAnchoredGlyph(
                codepoint: headCp,
                cxPt: mox + Double(note.origin.x),
                cyPt: moy + Double(note.origin.y),
                sizePt: glyphSize,
                into: &out,
            )
        }
        // Whole notes (and lower-resolution rests) are stemless.
        if case .whole = duration { return }
        // ── Stem ─────────────────────────────────────────────────────
        let noteOrigins = notes.map { CGPoint(
            x: CGFloat(mox + Double($0.origin.x)),
            y: CGFloat(moy + Double($0.origin.y)),
        )
        }
        guard let geometry = StemGeometry.compute(
            noteOrigins: noteOrigins,
            direction: stem,
            beamY: nil,
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
              let flagCp = FlagGlyph.codepoint(duration: duration, stem: stem)
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

    static func noteheadCodepoint(duration: NoteDuration) -> UInt32 {
        switch duration {
        case .whole: return SMuFLCodepoint.noteheadWhole
        case .half: return SMuFLCodepoint.noteheadHalf
        default: return SMuFLCodepoint.noteheadBlack
        }
    }

    // MARK: - Key signature

    // swiftlint:disable:next function_parameter_count
    static func encodeKeySignature(
        sharps: Int,
        flats: Int,
        originX: Double,
        originY: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return }
        let isSharp = sharps > 0
        let codepoint = isSharp
            ? SMuFLCodepoint.accidentalSharp
            : SMuFLCodepoint.accidentalFlat
        let steps = isSharp
            ? KeySignatureSteps.sharps
            : KeySignatureSteps.flats
        let advance = Double(KeySignatureSteps.advance(sp: CGFloat(sp)))
        for i in 0 ..< min(count, steps.count) {
            let stepDy = Double(KeySignatureSteps.stepDy(
                step: steps[i], sp: CGFloat(sp),
            ))
            emitCenterAnchoredGlyph(
                codepoint: codepoint,
                cxPt: originX + Double(i) * advance,
                cyPt: originY + stepDy,
                sizePt: glyphSize,
                into: &out,
            )
        }
    }
}
