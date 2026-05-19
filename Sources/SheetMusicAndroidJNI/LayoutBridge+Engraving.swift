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

    /// Emit a text element honoring the role's MuseScore anchor.
    /// Splits the string into Bravura-glyph runs (SMuFL PUA codepoints)
    /// and Edwin-text runs via `MusicTextRuns.runs`, advancing X across
    /// each run. The first run anchors at `originX` (adjusted by anchor
    /// offset using the total width).
    static func emitText(
        text: String,
        style: TextStyleType,
        originX: Double,
        originY: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        let textPt = TextRoleStyle.fontSize(for: style, sp: CGFloat(sp))
        // Inline music symbols (e.g. metNoteQuarterUp in a tempo) render
        // at the surrounding text's point size, NOT at the SMuFL 1-em
        // staff size — MuseScore styles them as inline glyphs so they
        // sit proportionate to the text characters.
        let glyphPt = textPt
        let runs = MusicTextRuns.runs(in: text)
        // Total advance across runs so the anchor offset is correct.
        var totalWidth: CGFloat = 0
        let measured: [(run: MusicTextRuns.Run, width: CGFloat)] = runs.map { run in
            let width = FontMetrics.provider.typographicWidth(
                text: run.text,
                font: fontFor(run: run, textPt: textPt, glyphPt: glyphPt),
            )
            totalWidth += width
            return (run, width)
        }
        let anchor = TextRoleStyle.horizontalAnchor(for: style)
        let anchorDx: Double = switch anchor {
        case .leading: 0
        case .center: -Double(totalWidth) / 2
        case .trailing: -Double(totalWidth)
        }
        var cursorX = originX + anchorDx
        for (run, width) in measured {
            switch run.kind {
            case .musicSymbol:
                out.append(.text(
                    run.text,
                    x: cursorX * ptToMMScale,
                    y: originY * ptToMMScale,
                    size: Double(glyphPt) * ptToMMScale,
                    fontId: .smufl,
                ))
            case .text:
                out.append(.text(
                    run.text,
                    x: cursorX * ptToMMScale,
                    y: originY * ptToMMScale,
                    size: Double(textPt) * ptToMMScale,
                    fontId: .textRoman,
                ))
            }
            cursorX += Double(width)
        }
    }

    private static func fontFor(
        run: MusicTextRuns.Run, textPt: CGFloat, glyphPt: CGFloat,
    ) -> LayoutFont {
        switch run.kind {
        case .musicSymbol:
            return LayoutFont(face: "Bravura", pointSize: glyphPt)
        case .text:
            return LayoutFont(face: "Edwin", pointSize: textPt)
        }
    }

    /// Emit a SMuFL glyph whose position was computed assuming Apple's
    /// `.center` anchor (typographic frame centre at `(cxPt, cyPt)`).
    /// `Canvas.drawText` on Android anchors at the baseline-leading
    /// corner; the offset comes from the glyph's typographic metrics
    /// (advance, ascent, descent) via `GlyphAnchor.centerToBaselineLeading`.
    static func emitCenterAnchoredGlyph(
        codepoint: UInt32,
        cxPt: Double,
        cyPt: Double,
        sizePt: Double,
        into out: inout [DrawCommand],
    ) {
        let font = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: CGFloat(sizePt),
        )
        // Single-character advance from the typographic width API.
        // SMuFL codepoints in the Private Use Area always produce
        // valid Unicode scalars (the bridge filters non-glyph values
        // upstream).
        guard let scalar = UnicodeScalar(codepoint) else { return }
        let advance = FontMetrics.provider.typographicWidth(
            text: String(scalar), font: font,
        )
        let ascent = FontMetrics.provider.ascent(font: font)
        let descent = FontMetrics.provider.descent(font: font)
        let (dx, dy) = GlyphAnchor.centerToBaselineLeading(
            advance: advance, ascent: ascent, descent: descent,
        )
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
