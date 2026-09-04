import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
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

    // Placeholder filled rect for layout elements the bridge can't
    // fully render yet (fermata, marker, jump, …). Helps spot
    // missing elements visually. Coords are passed as Doubles so the
    // signature stays public-internal-friendly even when
    // `SheetMusicLayout.CGPoint` is the platform stub (Android).
    // swiftlint:disable:next function_parameter_count
    static func placeholderRect(
        atX: Double, atY: Double,
        mox: Double, moy: Double, sp: Double,
        into out: inout [DrawCommand],
    ) {
        out.append(.fillRect(
            x: (mox + atX) * ptToMMScale,
            y: (moy + atY) * ptToMMScale,
            w: sp * ptToMMScale,
            h: sp * ptToMMScale,
        ))
    }

    /// Pack a `ScoreColor` as ARGB (0xAARRGGBB) for the wire-format
    /// `setColor` opcode. Returns `nil` for fully opaque black — the
    /// wire format's default — so we don't emit a redundant
    /// `setColor` for the common "no override" case.
    static func argb(from color: ScoreColor) -> UInt32? {
        let a = UInt32(max(0, min(255, color.alpha)))
        let r = UInt32(max(0, min(255, color.red)))
        let g = UInt32(max(0, min(255, color.green)))
        let b = UInt32(max(0, min(255, color.blue)))
        let packed = (a << 24) | (r << 16) | (g << 8) | b
        return packed == 0xFF00_0000 ? nil : packed
    }

    /// The `setTextStyle` bitmask for a role's MuseScore defaults.
    ///
    /// Only bold and italic are carried. `FontStyleSet` also has `underline` and `strike`, but no
    /// role default in `TextStyleType.museScoreDefault` sets either, and the Apple renderer does not
    /// draw them either — adding wire bits for a decoration nothing produces would be inventing a
    /// contract rather than closing a gap. `TextStyleFlag`'s mask has room when one appears.
    static func styleFlags(for style: TextStyleType) -> UInt8 {
        let set = TextRoleStyle.fontStyle(for: style)
        var flags = DrawCommand.TextStyleFlag.none
        if set.contains(.bold) { flags |= DrawCommand.TextStyleFlag.bold }
        if set.contains(.italic) { flags |= DrawCommand.TextStyleFlag.italic }
        return flags
    }

    /// Run `body` with `flags` active, restoring the neutral style afterwards.
    ///
    /// Emits nothing at all for the neutral style, so an unstyled score's program is byte-identical
    /// to what it was before v7 — which is what makes the golden comparisons in
    /// `DrawProgramRoundTripTests` still mean something.
    static func withTextStyle(
        _ flags: UInt8,
        into out: inout [DrawCommand],
        _ body: (inout [DrawCommand]) -> Void,
    ) {
        guard flags != DrawCommand.TextStyleFlag.none else {
            body(&out)
            return
        }
        out.append(.setTextStyle(flags: flags))
        body(&out)
        out.append(.setTextStyle(flags: DrawCommand.TextStyleFlag.none))
    }

    /// Emit a text element honoring the role's MuseScore anchor.
    /// Splits the string into Bravura-glyph runs (SMuFL PUA codepoints)
    /// and Edwin-text runs via `MusicTextRuns.runs`, advancing X across
    /// each run. The first run anchors at `originX` (adjusted by anchor
    /// offset using the total width).
    ///
    /// The role's bold / italic defaults ride along as a `setTextStyle` pair around the runs. They
    /// are the reason a tempo mark and a rehearsal mark used to render in regular weight everywhere
    /// but Apple: the wire had no way to say "bold", so `ResolvedTextStyle`'s answer stopped at the
    /// Apple renderer's own door.
    static func emitText(
        text: String,
        style: TextStyleType,
        originX: Double,
        originY: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        withTextStyle(styleFlags(for: style), into: &out) { out in
            emitTextRuns(
                text: text, style: style,
                originX: originX, originY: originY, sp: sp, into: &out,
            )
        }
    }

    private static func emitTextRuns(
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
        let weight = measurementWeight(for: style)
        // Total advance across runs so the anchor offset is correct.
        var totalWidth: CGFloat = 0
        let measured: [(run: MusicTextRuns.Run, width: CGFloat)] = runs.map { run in
            let width = FontMetrics.provider.typographicWidth(
                text: run.text,
                font: fontFor(run: run, textPt: textPt, glyphPt: glyphPt, weight: weight),
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
                    text: run.text,
                    x: cursorX * ptToMMScale,
                    y: originY * ptToMMScale,
                    size: Double(glyphPt) * ptToMMScale,
                    fontId: .smufl,
                ))
            case .text:
                out.append(.text(
                    text: run.text,
                    x: cursorX * ptToMMScale,
                    y: originY * ptToMMScale,
                    size: Double(textPt) * ptToMMScale,
                    fontId: .textRoman,
                ))
            }
            cursorX += Double(width)
        }
    }

    /// Emit a dynamic marking. Standard symbol dynamics (p, mf, ff,
    /// sfz, …) draw as bold Bravura SMuFL glyphs at 4 sp — matching
    /// Apple's `TextMarkRenderer.drawDynamic` and the shared
    /// `DynamicSymbolMap`. Free-form text dynamics ("cresc.",
    /// "espressivo") fall back to the generic Edwin text path.
    ///
    /// Apple anchors dynamics at `(0, 0.5)` (leading edge, vertical
    /// center); `Canvas.drawText` anchors at baseline-leading, so the
    /// baseline is shifted down by `(ascent − descent) / 2` to center
    /// the glyph row on `originY`, and the run advances X left-to-right.
    static func emitDynamic(
        text: String,
        originX: Double,
        originY: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        guard let codepoints = DynamicSymbolMap.codepoints(for: text) else {
            emitText(
                text: text, style: .dynamics,
                originX: originX, originY: originY, sp: sp, into: &out,
            )
            return
        }
        // SMuFL music-font convention: 1 em = 4 sp (MuseScore's
        // MUSICAL_SYMBOLS_DEFAULT_FONT_SIZE 10 pt × 2 at 5 pt/sp).
        let glyphSize = sp * 4
        let font = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: CGFloat(glyphSize),
        )
        let ascent = Double(FontMetrics.provider.ascent(font: font))
        let descent = Double(FontMetrics.provider.descent(font: font))
        let baselineY = originY + (ascent - descent) / 2
        var cursorX = originX
        for cp in codepoints {
            out.append(.glyph(
                codepoint: cp,
                x: cursorX * ptToMMScale,
                y: baselineY * ptToMMScale,
                size: glyphSize * ptToMMScale,
                fontId: .smufl,
            ))
            guard let scalar = UnicodeScalar(cp) else { continue }
            cursorX += Double(FontMetrics.provider.typographicWidth(
                text: String(scalar), font: font,
            ))
        }
    }

    private static func fontFor(
        run: MusicTextRuns.Run, textPt: CGFloat, glyphPt: CGFloat, weight: FontWeight = .regular,
    ) -> LayoutFont {
        switch run.kind {
        case .musicSymbol:
            // SMuFL faces have one weight; Bravura has no bold member and MuseScore never asks for
            // one, so the weight stops at the text runs.
            return LayoutFont(face: "Bravura", pointSize: glyphPt)
        case .text:
            return LayoutFont(face: "Edwin", pointSize: textPt, weight: weight)
        }
    }

    /// The `LayoutFont` weight to measure a role's text runs at.
    ///
    /// Measurement has to follow the style, not just the size: `emitText` centers and
    /// anchor-offsets from the total run width, so measuring a bold tempo mark at regular weight
    /// slides it left of where it is drawn. Italic is not a weight and CoreText's italic advances
    /// match the upright ones closely enough that no provider distinguishes them, so only bold
    /// changes what is asked for here.
    static func measurementWeight(for style: TextStyleType) -> FontWeight {
        TextRoleStyle.fontStyle(for: style).contains(.bold) ? .bold : .regular
    }

    /// Emit a SMuFL glyph whose position was computed assuming Apple's
    /// `.center` anchor (typographic frame center at `(cxPt, cyPt)`).
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
        guard let scalar = UnicodeScalar(codepoint) else { return }
        let advance = FontMetrics.provider.typographicWidth(
            text: String(scalar), font: font,
        )
        let (dx, dy) = GlyphAnchor.centerToBaselineLeading(advance: advance)
        out.append(.glyph(
            codepoint: codepoint,
            x: (cxPt + Double(dx)) * ptToMMScale,
            y: (cyPt + Double(dy)) * ptToMMScale,
            size: sizePt * ptToMMScale,
            fontId: .smufl,
        ))
    }

    /// Emit a collapsed multi-measure rest: the SMuFL `restHBar` glyph
    /// (a thick centered bar with vertical end-caps) plus, when
    /// `count > 0`, the run-length number rendered as centered
    /// tempo-style text directly above. Mirrors the Apple renderer's
    /// `drawMultiMeasureRest` (single `restHBar` glyph at native size,
    /// count centered 2.5 sp above). `count == 0` draws the bar only —
    /// lower staves in a multi-staff system reuse that so the label
    /// isn't duplicated per staff.
    static func emitMultiMeasureRest(
        count: Int,
        cxPt: Double,
        cyPt: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        emitCenterAnchoredGlyph(
            codepoint: SMuFLCodepoint.restHBar,
            cxPt: cxPt, cyPt: cyPt,
            sizePt: glyphSize,
            into: &out,
        )
        guard count > 0 else { return }
        // Apple anchors the count at `(0.5, 0.5)` (typographic frame
        // center) 2.5 sp above the bar. Canvas.drawText anchors at the
        // baseline-leading corner, so shift X left by half the advance
        // and place the baseline at the vertical center plus
        // `(ascent - descent) / 2`.
        let label = String(count)
        let textPt = TextRoleStyle.fontSize(for: .tempo, sp: CGFloat(sp))
        let font = LayoutFont(face: "Edwin", pointSize: textPt)
        let advance = Double(FontMetrics.provider.typographicWidth(
            text: label, font: font,
        ))
        let ascent = Double(FontMetrics.provider.ascent(font: font))
        let descent = Double(FontMetrics.provider.descent(font: font))
        let centerY = cyPt - sp * 2.5
        out.append(.text(
            text: label,
            x: (cxPt - advance / 2) * ptToMMScale,
            y: (centerY + (ascent - descent) / 2) * ptToMMScale,
            size: Double(textPt) * ptToMMScale,
            fontId: .textRoman,
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

    // MARK: - Tie arc (tessellated)

    // Emit a tie's cubic Bezier directly via the wire format
    // `.cubicTo` opcode. Compose's native Path.cubicTo renders the
    // curve with proper anti-aliasing — a polyline tessellation of
    // the same curve washes out at the staff-line stroke thickness.
    // Geometry shared with Apple via `TieArcGeometry`.
    // swiftlint:disable:next function_parameter_count
    static func encodeTieArc(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        above: Bool,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        // Shoulder height scales with sqrt(tie length) via the shared
        // `TieArcGeometry.shoulderHeightSp`, so Android matches Apple's
        // TieRenderer (long ties flatten, short ties stay ~0.3 sp)
        // instead of the old fixed 1 sp.
        let tieLengthSp = abs(toX - fromX) / max(sp, .leastNonzeroMagnitude)
        let pts = TieArcGeometry.controlPoints(
            from: CGPoint(x: CGFloat(fromX), y: CGFloat(fromY)),
            to: CGPoint(x: CGFloat(toX), y: CGFloat(toY)),
            above: above,
            heightSp: TieArcGeometry.shoulderHeightSp(
                tieLengthSp: CGFloat(tieLengthSp),
            ),
            sp: CGFloat(sp),
        )
        out.append(.moveTo(
            x: Double(pts.p0.x) * ptToMMScale,
            y: Double(pts.p0.y) * ptToMMScale,
        ))
        out.append(.cubicTo(
            cx1: Double(pts.p1.x) * ptToMMScale,
            cy1: Double(pts.p1.y) * ptToMMScale,
            cx2: Double(pts.p2.x) * ptToMMScale,
            cy2: Double(pts.p2.y) * ptToMMScale,
            x: Double(pts.p3.x) * ptToMMScale,
            y: Double(pts.p3.y) * ptToMMScale,
        ))
        out.append(.stroke(width: sp * 0.13 * ptToMMScale))
    }

    // MARK: - Tuplet bracket

    // swiftlint:disable:next function_parameter_count
    static func encodeTupletBracket(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        text: String,
        hasBracket: Bool,
        isAbove: Bool,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        let segments = TupletBracketGeometry.segments(
            from: CGPoint(x: CGFloat(fromX), y: CGFloat(fromY)),
            to: CGPoint(x: CGFloat(toX), y: CGFloat(toY)),
            isAbove: isAbove,
            sp: CGFloat(sp),
        )
        let fontSize = Double(TupletBracketGeometry.labelFontSizeSp) * sp
        // Label — centered Edwin italic, matching Apple's tuplet digits
        // (`drawTuplet` uses `italic: true`). Emitted as a `.setTextStyle`-wrapped `.text` since v7;
        // `.italicText` said the same thing in a second way and is no longer used.
        let labelFont = LayoutFont(
            face: "Edwin", pointSize: CGFloat(fontSize),
        )
        let labelWidth = Double(FontMetrics.provider.typographicWidth(
            text: text, font: labelFont,
        ))
        let ascent = Double(FontMetrics.provider.ascent(font: labelFont))
        let descent = Double(FontMetrics.provider.descent(font: labelFont))
        // Canvas.drawText anchors at the baseline. The bracket geometry
        // hands back the label's visual center Y, so shift baseline
        // down by half of (ascent − descent) to vertically center the
        // digit on `labelCenter.y`.
        let baselineY = Double(segments.labelCenter.y) + (ascent - descent) / 2
        withTextStyle(DrawCommand.TextStyleFlag.italic, into: &out) { out in
            out.append(.text(
                text: text,
                x: (Double(segments.labelCenter.x) - labelWidth / 2) * ptToMMScale,
                y: baselineY * ptToMMScale,
                size: fontSize * ptToMMScale,
                fontId: .textRoman,
            ))
        }
        guard hasBracket else { return }
        let lineWidth = Double(TupletBracketGeometry.lineThicknessSp) * sp
        emitSegment(
            segments.leftHookFrom,
            segments.leftHookTo,
            width: lineWidth,
            into: &out,
        )
        emitSegment(
            segments.rightHookFrom,
            segments.rightHookTo,
            width: lineWidth,
            into: &out,
        )
        emitSegment(
            segments.leftSegFrom,
            segments.leftSegTo,
            width: lineWidth,
            into: &out,
        )
        emitSegment(
            segments.rightSegFrom,
            segments.rightSegTo,
            width: lineWidth,
            into: &out,
        )
    }

    private static func emitSegment(
        _ from: CGPoint, _ to: CGPoint, width: Double,
        into out: inout [DrawCommand],
    ) {
        out.append(.moveTo(
            x: Double(from.x) * ptToMMScale,
            y: Double(from.y) * ptToMMScale,
        ))
        out.append(.lineTo(
            x: Double(to.x) * ptToMMScale,
            y: Double(to.y) * ptToMMScale,
        ))
        out.append(.stroke(width: width * ptToMMScale))
    }

    // MARK: - Spanners

    // swiftlint:disable:next function_parameter_count function_body_length
    static func encodeSpanner(
        kind: LayoutElement.SpannerKind,
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        continuesLeft: Bool, continuesRight: Bool,
        text: String,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        let from = CGPoint(x: CGFloat(fromX), y: CGFloat(fromY))
        let to = CGPoint(x: CGFloat(toX), y: CGFloat(toY))
        let stroke = Double(sp)
            * Double(SpannerGeometry.strokeThicknessSp)
        let line = Double(sp) * Double(SpannerGeometry.lineThicknessSp)
        switch kind {
        case .slur:
            let control = SpannerGeometry.slurControlPoint(
                from: from, to: to, sp: CGFloat(sp),
            )
            // Convert quad(P0, C, P1) → cubic(P0, C1, C2, P1).
            //   C1 = (P0 + 2C) / 3
            //   C2 = (P1 + 2C) / 3
            let c1 = CGPoint(
                x: (from.x + 2 * control.x) / 3,
                y: (from.y + 2 * control.y) / 3,
            )
            let c2 = CGPoint(
                x: (to.x + 2 * control.x) / 3,
                y: (to.y + 2 * control.y) / 3,
            )
            out.append(.moveTo(
                x: Double(from.x) * ptToMMScale,
                y: Double(from.y) * ptToMMScale,
            ))
            out.append(.cubicTo(
                cx1: Double(c1.x) * ptToMMScale,
                cy1: Double(c1.y) * ptToMMScale,
                cx2: Double(c2.x) * ptToMMScale,
                cy2: Double(c2.y) * ptToMMScale,
                x: Double(to.x) * ptToMMScale,
                y: Double(to.y) * ptToMMScale,
            ))
            out.append(.stroke(width: stroke * ptToMMScale))

        case let .volta(endings):
            let pts = SpannerGeometry.voltaBracketPoints(
                from: from, to: to,
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                sp: CGFloat(sp),
            )
            emitPolyline(pts, lineWidth: stroke, into: &out)
            if let label = SpannerGeometry.voltaLabel(
                from: from, to: to, endings: endings,
                continuesLeft: continuesLeft, sp: CGFloat(sp),
            ) {
                encodeNotationText(
                    text: label.text, role: .markerText,
                    originX: Double(label.origin.x),
                    originY: Double(label.origin.y),
                    sp: sp,
                    into: &out,
                )
            }

        case .hairpinOpen, .hairpinClose:
            let segs = SpannerGeometry.hairpin(
                from: from, to: to,
                open: kind == .hairpinOpen,
                sp: CGFloat(sp),
            )
            emitSegment(
                from: segs.upperFrom, to: segs.upperTo,
                lineWidth: stroke, into: &out,
            )
            emitSegment(
                from: segs.lowerFrom, to: segs.lowerTo,
                lineWidth: stroke, into: &out,
            )

        case let .hairpinLine(crescendo):
            let parts = SpannerGeometry.hairpinLine(
                from: from, to: to,
                crescendo: crescendo, sp: CGFloat(sp),
            )
            encodeNotationText(
                text: parts.label, role: .jump,
                originX: Double(parts.labelOrigin.x),
                originY: Double(parts.labelOrigin.y),
                sp: sp, into: &out,
            )
            if parts.lineEnd.x > parts.lineStart.x {
                let onMM = Double(parts.dashPattern.first ?? 3) * ptToMMScale
                let offMM = Double(
                    parts.dashPattern.count > 1
                        ? parts.dashPattern[1]
                        : (parts.dashPattern.first ?? 3),
                ) * ptToMMScale
                out.append(.setDash(onMM: onMM, offMM: offMM))
                emitSegment(
                    from: parts.lineStart, to: parts.lineEnd,
                    lineWidth: line, into: &out,
                )
                out.append(.setDash(onMM: 0, offMM: 0))
            }

        case .pedal:
            let parts = SpannerGeometry.pedal(from: from, to: to)
            // Canvas.drawText anchors at baseline-leading. Apple uses
            // `(0, 0.5)` (vertical center, leading); shift by the
            // glyph half-height.
            let glyphFont = LayoutFont(
                face: SMuFLFamily.bravura, pointSize: CGFloat(glyphSize),
            )
            let ascent = Double(
                FontMetrics.provider.ascent(font: glyphFont),
            )
            let descent = Double(
                FontMetrics.provider.descent(font: glyphFont),
            )
            let dy = (ascent - descent) / 2
            out.append(.glyph(
                codepoint: parts.downCodepoint,
                x: Double(parts.downOrigin.x) * ptToMMScale,
                y: (Double(parts.downOrigin.y) + dy) * ptToMMScale,
                size: glyphSize * ptToMMScale,
                fontId: .smufl,
            ))
            out.append(.glyph(
                codepoint: parts.upCodepoint,
                x: Double(parts.upOrigin.x) * ptToMMScale,
                y: (Double(parts.upOrigin.y) + dy) * ptToMMScale,
                size: glyphSize * ptToMMScale,
                fontId: .smufl,
            ))

        case let .ottava(subtype, numbersOnly):
            let parts = SpannerGeometry.ottava(
                from: from, to: to, sp: CGFloat(sp), subtype: subtype,
                numbersOnly: numbersOnly,
            )
            out.append(.glyph(
                codepoint: parts.labelCodepoint,
                x: Double(parts.labelOrigin.x) * ptToMMScale,
                y: (
                    Double(parts.labelOrigin.y)
                        + glyphBaselineShift(glyphSize: glyphSize),
                ) * ptToMMScale,
                size: glyphSize * ptToMMScale,
                fontId: .smufl,
            ))
            // Dashed line — mirror Apple's `StrokeStyle(dash:)`. The
            // pattern is in layout points (Apple applies it un-scaled),
            // so convert to mm like every other coordinate. Bracket the
            // stroke with the state opcode and clear it afterwards.
            let dashOn = Double(parts.dashPattern.first ?? 3) * ptToMMScale
            let dashOff = Double(
                parts.dashPattern.count > 1
                    ? parts.dashPattern[1]
                    : (parts.dashPattern.first ?? 3),
            ) * ptToMMScale
            out.append(.setDash(onMM: dashOn, offMM: dashOff))
            emitSegment(
                from: parts.lineStart, to: parts.lineEnd,
                lineWidth: line, into: &out,
            )
            out.append(.setDash(onMM: 0, offMM: 0))

        case .textLine, .palmMute, .letRing:
            let parts = SpannerGeometry.textLine(
                from: from, to: to, text: text, sp: CGFloat(sp),
                dashed: kind != .textLine,
            )
            if !parts.label.isEmpty {
                encodeNotationText(
                    text: parts.label, role: .jump,
                    originX: Double(parts.labelOrigin.x),
                    originY: Double(parts.labelOrigin.y),
                    sp: sp, into: &out,
                )
            }
            if parts.lineEnd.x > parts.lineStart.x {
                if !parts.dashPattern.isEmpty {
                    let onMM = Double(parts.dashPattern[0]) * ptToMMScale
                    let offMM = Double(
                        parts.dashPattern.count > 1
                            ? parts.dashPattern[1]
                            : parts.dashPattern[0],
                    ) * ptToMMScale
                    out.append(.setDash(onMM: onMM, offMM: offMM))
                }
                emitSegment(
                    from: parts.lineStart, to: parts.lineEnd,
                    lineWidth: line, into: &out,
                )
                if !parts.dashPattern.isEmpty {
                    out.append(.setDash(onMM: 0, offMM: 0))
                }
            }

        case let .trill(type):
            let symbols = SpannerGeometry.trillSymbols(
                type: type, continuesLeft: continuesLeft,
            )
            let trillFont = LayoutFont(
                face: SMuFLFamily.bravura, pointSize: CGFloat(glyphSize),
            )
            func trillAdvance(_ codepoint: UInt32) -> CGFloat {
                guard let scalar = UnicodeScalar(codepoint) else { return 0 }
                return FontMetrics.provider.typographicWidth(
                    text: String(Character(scalar)), font: trillFont,
                )
            }
            let dy = glyphBaselineShift(glyphSize: glyphSize)
            for (codepoint, origin) in SpannerGeometry.trillGlyphRun(
                from: from, to: to, symbols: symbols,
                startAdvance: trillAdvance(symbols.start),
                fillAdvance: trillAdvance(symbols.fill),
                endAdvance: symbols.end.map(trillAdvance) ?? 0,
            ) {
                out.append(.glyph(
                    codepoint: codepoint,
                    x: Double(origin.x) * ptToMMScale,
                    y: (Double(origin.y) + dy) * ptToMMScale,
                    size: glyphSize * ptToMMScale,
                    fontId: .smufl,
                ))
            }

        case let .vibrato(type):
            let codepoint = SpannerGeometry.vibratoCodepoint(type: type)
            let glyphFont = LayoutFont(
                face: SMuFLFamily.bravura, pointSize: CGFloat(glyphSize),
            )
            // swiftlint:disable:next force_unwrapping
            let ch = Character(UnicodeScalar(codepoint)!)
            let advance = CGFloat(FontMetrics.provider.typographicWidth(
                text: String(ch), font: glyphFont,
            ))
            let run = SpannerGeometry.vibratoGlyphRun(
                from: from, to: to, type: type, sp: CGFloat(sp), advance: advance,
            )
            let ascent = Double(FontMetrics.provider.ascent(font: glyphFont))
            let descent = Double(FontMetrics.provider.descent(font: glyphFont))
            let dy = (ascent - descent) / 2
            for origin in run.origins {
                out.append(.glyph(
                    codepoint: codepoint,
                    x: Double(origin.x) * ptToMMScale,
                    y: (Double(origin.y) + dy) * ptToMMScale,
                    size: glyphSize * ptToMMScale,
                    fontId: .smufl,
                ))
            }
        }
    }

    /// Canvas.drawText anchors a glyph at its baseline; Apple anchors
    /// at `(0, 0.5)` (vertical center). Shift by the glyph's half
    /// height so both back-ends land on the same pixel row.
    private static func glyphBaselineShift(glyphSize: Double) -> Double {
        let font = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: CGFloat(glyphSize),
        )
        let ascent = Double(FontMetrics.provider.ascent(font: font))
        let descent = Double(FontMetrics.provider.descent(font: font))
        return (ascent - descent) / 2
    }

    private static func emitPolyline(
        _ points: [CGPoint], lineWidth: Double,
        into out: inout [DrawCommand],
    ) {
        guard let first = points.first else { return }
        out.append(.moveTo(
            x: Double(first.x) * ptToMMScale,
            y: Double(first.y) * ptToMMScale,
        ))
        for pt in points.dropFirst() {
            out.append(.lineTo(
                x: Double(pt.x) * ptToMMScale,
                y: Double(pt.y) * ptToMMScale,
            ))
        }
        out.append(.stroke(width: lineWidth * ptToMMScale))
    }

    private static func emitSegment(
        from: CGPoint, to: CGPoint, lineWidth: Double,
        into out: inout [DrawCommand],
    ) {
        out.append(.moveTo(
            x: Double(from.x) * ptToMMScale,
            y: Double(from.y) * ptToMMScale,
        ))
        out.append(.lineTo(
            x: Double(to.x) * ptToMMScale,
            y: Double(to.y) * ptToMMScale,
        ))
        out.append(.stroke(width: lineWidth * ptToMMScale))
    }

    // MARK: - Glissando line

    // swiftlint:disable:next function_parameter_count
    static func encodeGlissandoLine(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        wavy: Bool,
        text: String?,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        let from = CGPoint(x: CGFloat(fromX), y: CGFloat(fromY))
        let to = CGPoint(x: CGFloat(toX), y: CGFloat(toY))
        let length = GlissandoGeometry.length(from: from, to: to)
        guard length > 0.01 else { return }
        let angle = GlissandoGeometry.angle(from: from, to: to)
        if wavy {
            encodeWavyGlissandoGlyphs(
                from: from, length: length, angle: angle, sp: sp, into: &out,
            )
        } else {
            // Straight line: build in local frame, transform to world.
            let lineWidth = Double(sp) * Double(GlissandoGeometry.lineThicknessSp)
            let worldFrom = GlissandoGeometry.toWorld(
                local: .zero, from: from, angle: angle,
            )
            let worldTo = GlissandoGeometry.toWorld(
                local: CGPoint(x: length, y: 0), from: from, angle: angle,
            )
            out.append(.moveTo(
                x: Double(worldFrom.x) * ptToMMScale,
                y: Double(worldFrom.y) * ptToMMScale,
            ))
            out.append(.lineTo(
                x: Double(worldTo.x) * ptToMMScale,
                y: Double(worldTo.y) * ptToMMScale,
            ))
            out.append(.stroke(width: lineWidth * ptToMMScale))
        }
        encodeGlissandoText(
            text: text, from: from, length: length, angle: angle,
            wavy: wavy, sp: sp, into: &out,
        )
    }

    /// Emit repeated wiggleGlissando (U+EAAF) glyphs centred along the
    /// glissando line. Each glyph is positioned at its world-space origin
    /// and rotated to match the line slope via `setRotation`.
    ///
    /// C++: tdraw.cpp:1585-1596
    private static func encodeWavyGlissandoGlyphs(
        from: CGPoint, length: CGFloat, angle: CGFloat, sp: Double,
        into out: inout [DrawCommand],
    ) {
        let codepoint = SMuFLCodepoint.wiggleGlissando
        let glyphSize = sp * 4
        let glyphFont = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: CGFloat(glyphSize),
        )
        // swiftlint:disable:next force_unwrapping
        let ch = Character(UnicodeScalar(codepoint)!)
        let advance = CGFloat(FontMetrics.provider.typographicWidth(
            text: String(ch), font: glyphFont,
        ))
        let run = GlissandoGeometry.wavyGlyphRun(length: length, advance: advance)
        let ascent = Double(FontMetrics.provider.ascent(font: glyphFont))
        let descent = Double(FontMetrics.provider.descent(font: glyphFont))
        let dy = (ascent - descent) / 2
        for i in 0 ..< run.count {
            let localX = run.startX + CGFloat(i) * advance
            let world = GlissandoGeometry.toWorld(
                local: CGPoint(x: localX, y: 0), from: from, angle: angle,
            )
            out.append(.setRotation(
                radians: Double(angle),
                pivotX: Double(world.x) * ptToMMScale,
                pivotY: Double(world.y) * ptToMMScale,
            ))
            out.append(.glyph(
                codepoint: codepoint,
                x: Double(world.x) * ptToMMScale,
                y: (Double(world.y) + dy) * ptToMMScale,
                size: glyphSize * ptToMMScale,
                fontId: .smufl,
            ))
        }
        // Reset canvas rotation after the glyph run (no-op if count==0).
        out.append(.setRotation(radians: 0, pivotX: 0, pivotY: 0))
    }

    /// Centered italic label above the glissando line, rotated to follow
    /// the line. Mirrors `ScoreLayerBuilder.drawGlissandoText`: Edwin 8 pt
    /// italic (`TextStyleType.glissando`), bottom-center anchored at the
    /// line midpoint with its descender clearing the line, and gated to
    /// the line length so a too-wide label is dropped (`tdraw.cpp:1580`).
    private static func encodeGlissandoText(
        text: String?, from: CGPoint, length: CGFloat, angle: CGFloat,
        wavy: Bool, sp: Double, into out: inout [DrawCommand],
    ) {
        guard let text, !text.isEmpty else { return }
        let fontSize = TextRoleStyle.fontSize(
            for: .glissando, sp: CGFloat(sp),
        )
        let font = LayoutFont(face: "Edwin", pointSize: fontSize)
        let textWidth = FontMetrics.provider.typographicWidth(
            text: text, font: font,
        )
        // MuseScore drops the label when it can't fit on the line.
        guard textWidth < length else { return }
        let descent = FontMetrics.provider.descent(font: font)
        let anchorLocal = GlissandoGeometry.textAnchorLocal(
            length: length, wavy: wavy, sp: CGFloat(sp),
        )
        let world = GlissandoGeometry.toWorld(
            local: anchorLocal, from: from, angle: angle,
        )
        // Rotate the canvas about the bottom-center anchor, then place the
        // baseline-leading text so its bottom-center lands on `world`.
        out.append(.setRotation(
            radians: Double(angle),
            pivotX: Double(world.x) * ptToMMScale,
            pivotY: Double(world.y) * ptToMMScale,
        ))
        // `.glissando`'s MuseScore default is italic (`styledef.cpp:1484-1488`), so the style comes
        // from the role rather than being spelled here — one answer for what a role looks like.
        withTextStyle(styleFlags(for: .glissando), into: &out) { out in
            out.append(.text(
                text: text,
                x: Double(world.x - textWidth / 2) * ptToMMScale,
                y: Double(world.y - descent) * ptToMMScale,
                size: Double(fontSize) * ptToMMScale,
                fontId: .textRoman,
            ))
        }
        out.append(.setRotation(radians: 0, pivotX: 0, pivotY: 0))
    }

    // MARK: - Harmony (chord symbol)

    /// Emit a pre-laid-out `LayoutHarmony`. Walks the `runs` array
    /// emitting Edwin text for `.text` runs and Bravura glyphs for
    /// `.accidental` runs at their pre-computed X offsets. Mirrors the
    /// Apple `HarmonyRenderer` walk.
    static func encodeHarmony(
        harmony lh: LayoutHarmony,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        guard !lh.runs.isEmpty else { return }
        let argb = lh.harmony.color.flatMap(argb(from:))
        if let argb { out.append(.setColor(argb: argb)) }
        let style = lh.harmony.styleType
        let textPt = TextRoleStyle.fontSize(for: style, sp: CGFloat(sp))
        let glyphPt = HarmonyRendering.glyphPointSize(
            for: lh.harmony,
            metrics: StaffMetrics(staffSize: CGFloat(sp) * 4),
        )
        // `.chordSymbolB` — MuseScore's jazz chord-symbol style — is italic, and Apple's
        // `HarmonyRenderer` applies it through `ResolvedTextStyle.font`. Without this the same score
        // reads upright here and slanted there.
        let styleFlags = styleFlags(for: style)
        let textFont = LayoutFont(
            face: "Edwin", pointSize: textPt, weight: measurementWeight(for: style),
        )
        let glyphFont = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: glyphPt,
        )
        let textAscent = Double(
            FontMetrics.provider.ascent(font: textFont),
        )
        let textDescent = Double(
            FontMetrics.provider.descent(font: textFont),
        )
        let glyphAscent = Double(
            FontMetrics.provider.ascent(font: glyphFont),
        )
        let glyphDescent = Double(
            FontMetrics.provider.descent(font: glyphFont),
        )
        let originX = mox + lh.anchorX
        let originY = moy + lh.y
        withTextStyle(styleFlags, into: &out) { out in
            emitHarmonyRuns(
                lh.runs,
                originX: originX, originY: originY,
                text: HarmonyFaceMetrics(
                    pointSize: Double(textPt),
                    baselineShift: (textAscent - textDescent) / 2,
                ),
                glyph: HarmonyFaceMetrics(
                    pointSize: Double(glyphPt),
                    baselineShift: (glyphAscent - glyphDescent) / 2,
                ),
                into: &out,
            )
        }
        if argb != nil {
            out.append(.setColor(argb: 0xFF00_0000))
        }
    }

    /// Point size and baseline shift for one of a harmony's two faces.
    ///
    /// Apple anchors each run at `.leading` (vertical center, leading edge) while `Canvas.drawText`
    /// anchors at the baseline, so the shift is `(ascent − descent) / 2` for that face. Paired in a
    /// struct because the two always travel together, and a run walk taking four loose `Double`s is
    /// four chances to hand it the text size with the glyph's baseline.
    struct HarmonyFaceMetrics {
        let pointSize: Double
        let baselineShift: Double
    }

    /// Walk a harmony's pre-laid-out runs.
    private static func emitHarmonyRuns(
        _ runs: [HarmonyRun],
        originX: Double,
        originY: Double,
        text textFace: HarmonyFaceMetrics,
        glyph glyphFace: HarmonyFaceMetrics,
        into out: inout [DrawCommand],
    ) {
        for run in runs {
            let runX = originX + run.x
            switch run.kind {
            case .text:
                out.append(.text(
                    text: run.content,
                    x: runX * ptToMMScale,
                    y: (originY + textFace.baselineShift) * ptToMMScale,
                    size: textFace.pointSize * ptToMMScale,
                    fontId: .textRoman,
                ))
            case let .accidental(acc):
                out.append(.glyph(
                    codepoint: acc.codepoint.unicodeScalars.first.map {
                        UInt32($0.value)
                    } ?? 0,
                    x: runX * ptToMMScale,
                    y: (originY + glyphFace.baselineShift) * ptToMMScale,
                    size: glyphFace.pointSize * ptToMMScale,
                    fontId: .smufl,
                ))
            }
        }
    }

    // MARK: - Notation text labels

    /// Emit a plain text label (jump / measure number / staff name /
    /// part label) using the `NotationTextStyle` constants. Computes a
    /// baseline Y from the role's anchor + the platform-measured
    /// ascent/descent so Canvas.drawText lands where SwiftUI's anchored
    /// `Text` would on Apple.
    static func encodeNotationText(
        text: String,
        role: NotationTextStyle.Role,
        originX: Double,
        originY: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        guard !text.isEmpty else { return }
        let textPt = NotationTextStyle.fontSize(
            for: role, sp: CGFloat(sp),
        )
        let font = LayoutFont(face: "Edwin", pointSize: textPt)
        let advance = Double(FontMetrics.provider.typographicWidth(
            text: text, font: font,
        ))
        let ascent = Double(FontMetrics.provider.ascent(font: font))
        let descent = Double(FontMetrics.provider.descent(font: font))
        let anchor = NotationTextStyle.anchor(for: role)
        let dx: Double
        let baselineY: Double
        switch anchor {
        case .leadingCenter:
            // SwiftUI `.leading` = `(0, 0.5)`. Vertical center is at
            // `(ascent - descent) / 2` above the baseline.
            dx = 0
            baselineY = originY + (ascent - descent) / 2
        case .bottomLeading:
            // SwiftUI `(0, 1)` puts the typographic frame's BOTTOM at
            // `originY`. The descender hangs below the baseline by
            // `descent`, so the baseline is `originY - descent`.
            dx = 0
            baselineY = originY - descent
        case .trailingCenter:
            // SwiftUI `.trailing` = `(1, 0.5)`. Shift the X by the
            // negative of the advance so the right edge lands at
            // `originX`.
            dx = -advance
            baselineY = originY + (ascent - descent) / 2
        }
        out.append(.text(
            text: text,
            x: (originX + dx) * ptToMMScale,
            y: baselineY * ptToMMScale,
            size: Double(textPt) * ptToMMScale,
            fontId: .textRoman,
        ))
    }

    // MARK: - Rehearsal mark

    // swiftlint:disable:next function_parameter_count
    static func encodeRehearsalMark(
        text: String,
        originX: Double,
        originY: Double,
        frame: TextFrameType,
        color: ScoreColor?,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        guard !text.isEmpty else { return }
        let argb = color.flatMap(argb(from:))
        if let argb { out.append(.setColor(argb: argb)) }
        let pad = Double(RehearsalMarkFrame.paddingSp(sp: CGFloat(sp)))
        let textPt = TextRoleStyle.fontSize(
            for: .rehearsalMark, sp: CGFloat(sp),
        )
        // Measured at the weight it is DRAWN at. `.rehearsalMark`'s MuseScore default is bold
        // (`TextStyle.swift`), and the frame below is sized from this measurement — so measuring
        // regular while drawing bold puts the letters through the right-hand edge of their own box.
        // That is the failure the weight-aware `FontMetricsTable.face(for:)` lookup exists for.
        let styleFlags = styleFlags(for: .rehearsalMark)
        let font = LayoutFont(
            face: "Edwin", pointSize: textPt, weight: measurementWeight(for: .rehearsalMark),
        )
        let advance = Double(FontMetrics.provider.typographicWidth(
            text: text, font: font,
        ))
        let ascent = Double(FontMetrics.provider.ascent(font: font))
        let descent = Double(FontMetrics.provider.descent(font: font))
        let textWidth = max(advance, Double(textPt) * 0.5)
        let textHeight = ascent + descent
        // Apple anchors the text at bottom-leading inside the box;
        // Canvas.drawText anchors at baseline, so the baseline Y is
        // `origin.y - pad - descent`.
        let textOriginX = originX + pad
        let baselineY = originY - pad - descent
        withTextStyle(styleFlags, into: &out) { out in
            out.append(.text(
                text: text,
                x: textOriginX * ptToMMScale,
                y: baselineY * ptToMMScale,
                size: Double(textPt) * ptToMMScale,
                fontId: .textRoman,
            ))
        }
        let boxRect = RehearsalMarkFrame.boxRect(
            textWidth: CGFloat(textWidth),
            textHeight: CGFloat(textHeight),
            origin: CGPoint(x: CGFloat(originX), y: CGFloat(originY)),
            pad: CGFloat(pad),
        )
        let strokeWidth = Double(
            RehearsalMarkFrame.strokeWidthSp(sp: CGFloat(sp)),
        )
        switch RehearsalMarkFrame.shape(for: frame, around: boxRect) {
        case .none:
            break
        case let .rectangle(rect):
            emitRectStroke(
                rect: rect, lineWidth: strokeWidth, into: &out,
            )
        case let .ellipse(rect):
            // Approximate an ellipse with four cubic Bezier arcs. The
            // wire format has no native ellipse opcode; this matches
            // SVG's standard 4-arc approximation (kappa = 0.5522847498).
            emitEllipseStroke(
                rect: rect, lineWidth: strokeWidth, into: &out,
            )
        }
        if argb != nil {
            out.append(.setColor(argb: 0xFF00_0000))
        }
    }

    private static func emitRectStroke(
        rect: CGRect, lineWidth: Double,
        into out: inout [DrawCommand],
    ) {
        let x0 = Double(rect.minX) * ptToMMScale
        let y0 = Double(rect.minY) * ptToMMScale
        let x1 = Double(rect.maxX) * ptToMMScale
        let y1 = Double(rect.maxY) * ptToMMScale
        out.append(.moveTo(x: x0, y: y0))
        out.append(.lineTo(x: x1, y: y0))
        out.append(.lineTo(x: x1, y: y1))
        out.append(.lineTo(x: x0, y: y1))
        out.append(.lineTo(x: x0, y: y0))
        out.append(.stroke(width: lineWidth * ptToMMScale))
    }

    private static func emitEllipseStroke(
        rect: CGRect, lineWidth: Double,
        into out: inout [DrawCommand],
    ) {
        // Standard 4-arc cubic Bezier approximation of an ellipse.
        let kappa = 0.5522847498
        let cx = Double(rect.midX) * ptToMMScale
        let cy = Double(rect.midY) * ptToMMScale
        let rx = Double(rect.width) / 2 * ptToMMScale
        let ry = Double(rect.height) / 2 * ptToMMScale
        let ox: Double = rx * kappa
        let oy: Double = ry * kappa
        out.append(.moveTo(x: cx - rx, y: cy))
        emitCubic(
            out: &out,
            cx1: cx - rx, cy1: cy - oy,
            cx2: cx - ox, cy2: cy - ry,
            x: cx, y: cy - ry,
        )
        emitCubic(
            out: &out,
            cx1: cx + ox, cy1: cy - ry,
            cx2: cx + rx, cy2: cy - oy,
            x: cx + rx, y: cy,
        )
        emitCubic(
            out: &out,
            cx1: cx + rx, cy1: cy + oy,
            cx2: cx + ox, cy2: cy + ry,
            x: cx, y: cy + ry,
        )
        emitCubic(
            out: &out,
            cx1: cx - ox, cy1: cy + ry,
            cx2: cx - rx, cy2: cy + oy,
            x: cx - rx, y: cy,
        )
        out.append(.stroke(width: lineWidth * ptToMMScale))
    }

    // swiftlint:disable:next function_parameter_count
    private static func emitCubic(
        out: inout [DrawCommand],
        cx1: Double, cy1: Double,
        cx2: Double, cy2: Double,
        x: Double, y: Double,
    ) {
        out.append(.cubicTo(
            cx1: cx1, cy1: cy1, cx2: cx2, cy2: cy2, x: x, y: y,
        ))
    }

    // MARK: - Key signature

    // `naturals` are pre-resolved steps (the layout engine matched them
    // to the clef); they are drawn FIRST, ahead of the new signature,
    // exactly as the two Apple renderers do.
    // swiftlint:disable:next function_parameter_count
    static func encodeKeySignature(
        sharps: Int,
        flats: Int,
        clef: NotatedClef,
        naturals: [Int] = [],
        originX: Double,
        originY: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        let codepoint = sharps > 0
            ? SMuFLCodepoint.accidentalSharp
            : SMuFLCodepoint.accidentalFlat
        let steps = KeySignatureSteps.steps(
            sharps: sharps, flats: flats, clef: clef,
        )
        let advance = Double(KeySignatureSteps.advance(sp: CGFloat(sp)))
        let run = naturals.map { ($0, SMuFLCodepoint.accidentalNatural) }
            + steps.map { ($0, codepoint) }
        for (i, entry) in run.enumerated() {
            let stepDy = Double(KeySignatureSteps.stepDy(
                step: entry.0, sp: CGFloat(sp),
            ))
            emitCenterAnchoredGlyph(
                codepoint: entry.1,
                cxPt: originX + Double(i) * advance,
                cyPt: originY + stepDy,
                sizePt: glyphSize,
                into: &out,
            )
        }
    }
}
