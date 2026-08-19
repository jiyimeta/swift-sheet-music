import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGPoint`
    /// and `CGFloat`, clashing with SheetMusicLayout's stubs. Anchor to the
    /// Layout definitions so that `LayoutElement` associated values and
    /// `StaffLineGeometry`'s arguments match the parameter types.
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Converts a `Score` into a binary draw-program payload for the Android
/// Compose renderer.
///
/// ### Coordinate units
/// `LayoutEngine` works in typographic points (pt). This bridge converts all
/// coordinates to millimetres before encoding so that the Kotlin renderer can
/// work in physical units directly.
///   1 pt = 25.4 / 72 mm ≈ 0.3528 mm
///
/// ### Pagination
/// `LayoutDocument` has no built-in pagination boundary — it is a flat list
/// of `LayoutSystem` values stacked vertically. For Phase 4 (audio-deferred)
/// this bridge emits **one page** containing all systems. The `pageWidthMM`
/// and `pageHeightMM` parameters are used as the page dimensions in the
/// draw-program header and as the `availableWidth` hint to `LayoutEngine`
/// (converted back to pt). Real multi-page pagination is a future task.
///
/// ### Draw commands emitted
/// For each `LayoutSystem` the bridge emits:
/// 1. Each staff's own lines — `StaffLineGeometry.lineCount` of them, which
///    is five only for a standard staff (moveTo + lineTo + stroke triples).
/// 2. Per `LayoutMeasure`: its elements — clef glyphs, time-sig glyphs,
///    note-head glyphs, rest glyphs, and barline strokes. Unknown/unhandled
///    element types fall back to a small `fillRect` placeholder.
public enum LayoutBridge { // swiftlint:disable:this type_body_length
    // MARK: - Unit conversion

    /// Points to millimetres: 1 pt = 25.4 / 72 mm.
    private static let ptToMM = 25.4 / 72.0

    // MARK: - Public API

    /// Lay out `score` and encode the result as a draw-program payload.
    ///
    /// - Parameters:
    ///   - score: The parsed score.
    ///   - pageWidthMM: Viewport / page width in millimetres.
    ///   - pageHeightMM: Viewport / page height in millimetres.
    /// - Returns: Encoded draw program bytes (magic + version + page list).
    public static func compute(
        score: Score,
        pageWidthMM: Double,
        pageHeightMM: Double,
    ) -> Data {
        computeWithDocument(
            score: score,
            pageWidthMM: pageWidthMM,
            pageHeightMM: pageHeightMM,
            options: .verticalDefault,
        ).encoded
    }

    // MARK: - Command builder

    // swiftlint:disable:next function_body_length
    static func buildCommands(
        layout: LayoutDocument,
        // Selection re-encode: `nil` (the default) reproduces today's output byte-for-byte — every
        // `tintColor(for:tint:)` lookup below short-circuits to `nil` and no `.setColor` bracket is emitted
        // that wasn't already. Non-nil brackets the draw commands for every `ScoreItemID` in `ids` with
        // `.setColor(argb: argb)` … `.setColor(argb: blackARGB)`. `ids` is expected to already be expanded
        // (see `LayoutBridge+Selection.swift`'s doc comment) — this function does no expansion of its own.
        tint: (argb: UInt32, ids: Set<ScoreItemID>)? = nil,
    ) -> [DrawCommand] {
        var out: [DrawCommand] = []
        let metrics = layout.metrics
        let context = MetricsContext(
            sp: Double(metrics.sp),
            glyphSize: Double(metrics.glyphFontSize),
            defaultStemLength: Double(metrics.defaultStemLength),
            stemThickness: Double(metrics.stemThickness),
        )
        let staffLineThickness = Double(metrics.staffLineThickness)

        // ── 0. Title block ──────────────────────────────────────────────────
        // The leading `<VBox>` (title / subtitle / composer / lyricist) sits at
        // y = 0 … `titleFrame.height`; the systems below were already shifted
        // down by that height. Mirrors the Apple `TitleFrameView`.
        if let titleFrame = layout.titleFrame {
            appendTitleFrame(titleFrame, into: &out)
        }

        for system in layout.systems {
            let sysOriginX = Double(system.origin.x)
            let sysOriginY = Double(system.origin.y)
            // Stop the staff lines at the rightmost stroke of the system
            // terminal barline so the staff doesn't trail past it through
            // the per-measure gutter.
            let endX = Double(BarLineGeometry.staffLineEndX(for: system))

            // ── 1. Staff lines ──────────────────────────────────────────────
            for (staffIndex, staffOrigin) in system.staffOrigins.enumerated() {
                let ox = Double(staffOrigin.x) + sysOriginX
                let oy = Double(staffOrigin.y) + sysOriginY
                let rightX = endX + sysOriginX
                let geometry = system.geometry(atFlatIndex: staffIndex)
                for line in 0 ..< geometry.lineCount {
                    let y = oy + Double(
                        geometry.lineY(line, sp: CGFloat(context.sp)),
                    )
                    out.append(.moveTo(
                        x: ox * ptToMM,
                        y: y * ptToMM,
                    ))
                    out.append(.lineTo(
                        x: rightX * ptToMM,
                        y: y * ptToMM,
                    ))
                    out.append(.stroke(width: staffLineThickness * ptToMM))
                }
            }

            // ── 2. Measure elements ─────────────────────────────────────────
            for measure in system.measures {
                let mox = Double(measure.origin.x) + sysOriginX
                let moy = Double(measure.origin.y) + sysOriginY

                for element in measure.elements {
                    encodeElement(
                        element,
                        measureOriginX: mox,
                        measureOriginY: moy,
                        metrics: context,
                        showsInvisible: system.showsInvisibleElements,
                        tint: tint,
                        into: &out,
                    )
                }

                // Markers (measure numbers, coda / segno, …) and jumps
                // (D.S. / D.C. / Fine, …) live in their own per-measure
                // arrays, not `elements`. The Apple renderer walks them
                // separately (see `ScoreCanvasDrawing.drawSystem`); mirror
                // that so they don't silently vanish on Android.
                for element in measure.markers + measure.jumps {
                    encodeElement(
                        element,
                        measureOriginX: mox,
                        measureOriginY: moy,
                        metrics: context,
                        showsInvisible: system.showsInvisibleElements,
                        tint: tint,
                        into: &out,
                    )
                }
            }

            // ── 3. System spanners ──────────────────────────────────────────
            // Tie arcs, slurs, hairpins, etc. that attachTies/spanners
            // hang off the system after the per-measure walk. Their
            // origins are in system-local coords, so pass sysOriginX/Y
            // as the "measure" origin and zero-relative element offsets
            // will resolve correctly.
            for element in system.spanners {
                encodeElement(
                    element,
                    measureOriginX: sysOriginX,
                    measureOriginY: sysOriginY,
                    metrics: context,
                    showsInvisible: system.showsInvisibleElements,
                    tint: tint,
                    into: &out,
                )
            }

            // ── 4. System start: barline + brackets / braces ────────────────
            // The vertical bar joining all staves at the left edge plus each
            // `BracketItem`'s brace / bracket — see `LayoutBridge+Brackets`.
            appendSystemStart(
                for: system,
                sysOriginX: sysOriginX,
                sysOriginY: sysOriginY,
                sp: context.sp,
                staffLineThickness: staffLineThickness,
                into: &out,
            )

            // ── 4. Invisible elements (MuseScore "Show Invisible") ──────────
            appendInvisibleElements(
                of: system,
                systemOriginX: sysOriginX,
                systemOriginY: sysOriginY,
                metrics: context,
                tint: tint,
                into: &out,
            )
        }
        return out
    }

    /// Draw the system's invisible-container elements in MuseScore gray.
    ///
    /// With `showsInvisibleElements` on, the layout engine parks elements
    /// authored `visible == false` in parallel `invisibleElements` /
    /// `invisibleSpanners` containers instead of dropping them. Mirror the
    /// Apple renderers (`ScoreCanvas` / `ScoreLayerBuilder`): draw them in
    /// MuseScore's `invisibleColor()` = #808080 (50 % black on white), then
    /// restore black. The DrawProgram has no group-opacity opcode, so the
    /// gray is applied via `setColor` around the whole invisible pass.
    /// No-op when the system has nothing parked as invisible.
    private static func appendInvisibleElements(
        of system: LayoutSystem,
        systemOriginX sysOriginX: Double,
        systemOriginY sysOriginY: Double,
        metrics context: MetricsContext,
        tint: (argb: UInt32, ids: Set<ScoreItemID>)?,
        into out: inout [DrawCommand],
    ) {
        let hasInvisible = system.measures.contains { !$0.invisibleElements.isEmpty }
            || !system.invisibleSpanners.isEmpty
        guard hasInvisible else { return }
        out.append(.setColor(argb: invisibleARGB))
        for measure in system.measures where !measure.invisibleElements.isEmpty {
            let mox = Double(measure.origin.x) + sysOriginX
            let moy = Double(measure.origin.y) + sysOriginY
            for element in measure.invisibleElements {
                encodeElement(
                    element,
                    measureOriginX: mox,
                    measureOriginY: moy,
                    metrics: context,
                    showsInvisible: true,
                    tint: tint,
                    into: &out,
                )
            }
        }
        for element in system.invisibleSpanners {
            encodeElement(
                element,
                measureOriginX: sysOriginX,
                measureOriginY: sysOriginY,
                metrics: context,
                showsInvisible: true,
                tint: tint,
                into: &out,
            )
        }
        out.append(.setColor(argb: blackARGB))
    }

    /// MuseScore `invisibleColor()` = #808080 — 50 % black on white. Opaque
    /// gray ARGB (0xAARRGGBB) for the `setColor` opcode, used to draw
    /// elements parked in the invisible containers and per-note-invisible
    /// noteheads when the "Show Invisible" toggle is on.
    static let invisibleARGB: UInt32 = 0xFF80_8080
    /// Plain opaque black — the default paint, re-asserted after a colored
    /// or invisible run so subsequent commands paint normally.
    static let blackARGB: UInt32 = 0xFF00_0000

    /// Scalar metrics passed down to per-element encoders so they don't
    /// each re-derive sp / glyph size / stem geometry from `StaffMetrics`.
    struct MetricsContext {
        let sp: Double
        let glyphSize: Double
        let defaultStemLength: Double
        let stemThickness: Double
    }

    // MARK: - Per-element encoder

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func encodeElement(
        _ element: LayoutElement,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        metrics ctx: MetricsContext,
        // When true, a chord's per-note-invisible noteheads are drawn grayed
        // (the caller has already set the ambient color for the invisible
        // pass); when false they are dropped. Only chord/graceChord consult it.
        showsInvisible: Bool,
        // Selection re-encode — see `buildCommands(layout:tint:)`'s doc comment. Threaded down so
        // chord/graceChord/rest/tupletLabel can bracket their own draw commands with `.setColor`.
        tint: (argb: UInt32, ids: Set<ScoreItemID>)?,
        into out: inout [DrawCommand],
    ) {
        let sp = ctx.sp
        let glyphSize = ctx.glyphSize
        switch element {
        case let .clef(rawType, origin, _):
            let (codepoint, yOffsetSp) = ClefGlyph.glyph(
                for: NotatedClef(rawType: rawType),
            )
            emitCenterAnchoredGlyph(
                codepoint: codepoint,
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y) + Double(yOffsetSp) * sp,
                sizePt: glyphSize,
                into: &out,
            )

        case let .timeSignature(numerator, denominator, origin):
            encodeTimeSignature(
                numerator: numerator,
                denominator: denominator,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                glyphSize: glyphSize,
                into: &out,
            )

        case let .keySignature(sharps, flats, clef, origin):
            encodeKeySignature(
                sharps: sharps,
                flats: flats,
                clef: clef,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                glyphSize: glyphSize,
                into: &out,
            )

        case let .chord(
            notes, duration, stem, stemOrigin, _, _, isBeamed, _, stemExtension, _, mag,
        ):
            encodeChord(
                notes: notes, duration: duration, stem: stem,
                stemOriginY: Double(stemOrigin.y),
                isBeamed: isBeamed, stemExtension: Double(stemExtension),
                mag: Double(mag),
                measureOriginX: mox, measureOriginY: moy,
                metrics: ctx, showsInvisible: showsInvisible, tint: tint, into: &out,
            )

        case let .graceChord(notes, duration, stem, stemOrigin, _, hasSlash, mag, _):
            encodeChord(
                notes: notes, duration: duration, stem: stem,
                stemOriginY: Double(stemOrigin.y),
                isBeamed: false, stemExtension: 0,
                mag: Double(mag),
                measureOriginX: mox, measureOriginY: moy,
                metrics: ctx, showsInvisible: showsInvisible, tint: tint, into: &out,
            )
            // Acciaccatura slash across the (reduced) grace stem.
            if hasSlash {
                emitGraceSlash(
                    notes: notes, stem: stem, mag: Double(mag),
                    measureOriginX: mox, measureOriginY: moy,
                    metrics: ctx, into: &out,
                )
            }

        case let .rest(duration, origin, _, restID, hasLegerLine):
            // Split base duration + dot count, mirroring `encodeChord` and
            // iOS `ScoreCanvas`. `RestGlyph.codepoint` only understands base
            // durations; passing a dotted `.fraction(...)` straight through
            // falls back to a 64th rest. Render the base glyph, then emit the
            // augmentation dots separately. iOS uses `onStaffLine: true` for
            // all rest dots, so match that.
            let (baseDur, dotCount) = DurationInterpretation.split(duration)
            // Selection tint brackets the rest glyph only, never its augmentation dots — mirrors Apple's
            // `drawRest` (`ScoreLayerBuilder+Notation.swift`), which returns only the glyph layer for
            // `+Element.swift` to `context.attach` to `.rest(rid)`; `drawRest`'s own `drawDots` call is a
            // sibling that attaches nothing, so a selected rest's dots stay at the ambient color on Apple too.
            let restArgb = LayoutBridge.tintColor(for: .rest(restID), tint: tint)
            if let restArgb { out.append(.setColor(argb: restArgb)) }
            emitCenterAnchoredGlyph(
                codepoint: RestGlyph.codepoint(
                    duration: baseDur, hasLegerLine: hasLegerLine,
                ),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )
            if restArgb != nil { out.append(.setColor(argb: LayoutBridge.blackARGB)) }
            if dotCount > 0 {
                emitAugmentationDots(
                    anchorX: mox + Double(origin.x),
                    anchorY: moy + Double(origin.y),
                    count: dotCount,
                    onStaffLine: true,
                    sp: ctx.sp,
                    into: &out,
                )
            }

        case let .barLine(_, origin, halfHeightPt):
            // Barline origin sits at the middle of its own stroke, and
            // the engine hands over the half-height so the span follows
            // the staff's line count (4 sp tall on five lines, 2 sp on
            // three, and 4 sp centered on the line for one). Width =
            // 0.15 sp (the thin-stroke engraving default).
            // Subtype-specific extras (double, end, repeat dots) are a
            // follow-up.
            let halfHeight = Double(halfHeightPt)
            let bx = (mox + Double(origin.x)) * ptToMM
            let byMid = (moy + Double(origin.y)) * ptToMM
            out.append(.moveTo(x: bx, y: byMid - halfHeight * ptToMM))
            out.append(.lineTo(x: bx, y: byMid + halfHeight * ptToMM))
            out.append(.stroke(
                width: Double(BarLineGeometry.thinThicknessSp) * sp * ptToMM,
            ))

        case let .ledgerLine(from, to, thickness):
            // `LedgerLinePass` owns the geometry (it is the only place
            // that can see the staff's line count), so the bridge just
            // strokes the segment it was handed — the same
            // moveTo / lineTo / stroke triple used for staff lines.
            out.append(.moveTo(
                x: (mox + Double(from.x)) * ptToMM,
                y: (moy + Double(from.y)) * ptToMM,
            ))
            out.append(.lineTo(
                x: (mox + Double(to.x)) * ptToMM,
                y: (moy + Double(to.y)) * ptToMM,
            ))
            out.append(.stroke(width: Double(thickness) * ptToMM))

        case let .beam(fromOrigin, toOrigin, direction, level, color):
            // Each beam emit at a given level: shift Y by the level
            // offset so secondaries stack inward from the primary,
            // matching Apple BeamRenderer's geometry.
            let dy = Double(BeamGeometry.levelOffsetDy(
                level: level, stemDirection: direction, sp: CGFloat(sp),
            ))
            // Draw the center of the beam stroke at `dy + beamThickness/2`
            // so the stroke's outer edge aligns with the chord's stem
            // tip (matching Apple's filled-rectangle geometry).
            let thickness = Double(BeamGeometry.beamThicknessSp) * sp
            let stackSign: Double = direction == .up ? 1 : -1
            let centerDy = dy + (thickness / 2) * stackSign
            let fx = (mox + Double(fromOrigin.x)) * ptToMM
            let fy = (moy + Double(fromOrigin.y) + centerDy) * ptToMM
            let tx = (mox + Double(toOrigin.x)) * ptToMM
            let ty = (moy + Double(toOrigin.y) + centerDy) * ptToMM
            // Beams honor the author beam <color> (matches Apple's
            // BeamRenderer); default ink otherwise.
            let beamARGB = color.flatMap(LayoutBridge.argb(from:))
            if let beamARGB { out.append(.setColor(argb: beamARGB)) }
            out.append(.moveTo(x: fx, y: fy))
            out.append(.lineTo(x: tx, y: ty))
            out.append(.stroke(width: thickness * ptToMM))
            if beamARGB != nil {
                out.append(.setColor(argb: LayoutBridge.blackARGB))
            }

        case let .textMark(kind, text, origin):
            // Standard dynamics (p, mf, ff, sfz, …) render as bold
            // Bravura SMuFL glyphs, NOT Edwin text — mirrors Apple's
            // `TextMarkRenderer.drawDynamic`. `emitText` alone would
            // emit the literal letters in Edwin (the bug this fixes).
            // Non-symbol / other text marks keep the generic path.
            if kind == .dynamic {
                emitDynamic(
                    text: text,
                    originX: mox + Double(origin.x),
                    originY: moy + Double(origin.y),
                    sp: sp,
                    into: &out,
                )
            } else {
                emitText(
                    text: text,
                    style: TextRoleStyle.style(for: kind),
                    originX: mox + Double(origin.x),
                    originY: moy + Double(origin.y),
                    sp: sp,
                    into: &out,
                )
            }

        case let .staffText(text, origin, color, style):
            let argb = color.flatMap(LayoutBridge.argb(from:))
            if let argb { out.append(.setColor(argb: argb)) }
            emitText(
                text: text,
                style: style,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                into: &out,
            )
            if argb != nil {
                out.append(.setColor(argb: 0xFF00_0000))
            }

        // Fallback for unhandled point-origin cases: tiny placeholder rect.
        case let .note(_, _, _, _, origin, _, _, _):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .fermata(subtype, origin):
            emitCenterAnchoredGlyph(
                codepoint: FermataGlyph.codepoint(forSubtype: subtype),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )

        case let .breath(kind, origin):
            emitCenterAnchoredGlyph(
                codepoint: BreathGlyph.codepoint(forKind: kind),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )

        case let .marker(kind, text, origin):
            switch MarkerGlyph.variant(for: kind, text: text) {
            case let .glyph(codepoint):
                emitCenterAnchoredGlyph(
                    codepoint: codepoint,
                    cxPt: mox + Double(origin.x),
                    cyPt: moy + Double(origin.y),
                    sizePt: glyphSize,
                    into: &out,
                )
            case let .text(label):
                encodeNotationText(
                    text: label, role: .markerText,
                    originX: mox + Double(origin.x),
                    originY: moy + Double(origin.y),
                    sp: sp,
                    into: &out,
                )
            }

        case let .rehearsalMark(text, origin, frame, color):
            encodeRehearsalMark(
                text: text,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                frame: frame,
                color: color,
                sp: sp,
                into: &out,
            )

        case let .jump(text, origin):
            encodeNotationText(
                text: text, role: .jump,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                into: &out,
            )

        case let .measureRepeat(count, origin):
            emitCenterAnchoredGlyph(
                codepoint: MeasureRepeatGlyph.codepoint(forCount: count),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )

        case let .multiMeasureRest(count, origin):
            emitMultiMeasureRest(
                count: count,
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sp: sp,
                glyphSize: glyphSize,
                into: &out,
            )

        case let .measureNumber(text, origin):
            encodeNotationText(
                text: text, role: .measureNumber,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                into: &out,
            )

        case let .staffName(text, origin):
            encodeNotationText(
                text: text, role: .staffName,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                into: &out,
            )

        case let .articulation(kind, origin, isAbove):
            emitCenterAnchoredGlyph(
                codepoint: ArticulationGlyph.codepoint(
                    kind: kind, isAbove: isAbove,
                ),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )

        case let .chordLine(shape, origin, thickness):
            encodeChordLine(
                shape: shape,
                originXPt: mox + Double(origin.x),
                originYPt: moy + Double(origin.y),
                thicknessPt: Double(thickness),
                glyphSizePt: glyphSize,
                into: &out,
            )

        case let .tieArc(fromOrigin, toOrigin, above):
            encodeTieArc(
                fromX: mox + Double(fromOrigin.x),
                fromY: moy + Double(fromOrigin.y),
                toX: mox + Double(toOrigin.x),
                toY: moy + Double(toOrigin.y),
                above: above,
                sp: sp,
                into: &out,
            )

        case let .lyricsMelisma(fromOrigin, toOrigin):
            // Thin horizontal underscore-style rule from the syllable's
            // tail to the end of the last covered note. Apple uses
            // `staffLineThickness` here.
            let fx = (mox + Double(fromOrigin.x)) * ptToMM
            let fy = (moy + Double(fromOrigin.y)) * ptToMM
            let tx = (mox + Double(toOrigin.x)) * ptToMM
            let ty = (moy + Double(toOrigin.y)) * ptToMM
            out.append(.moveTo(x: fx, y: fy))
            out.append(.lineTo(x: tx, y: ty))
            out.append(.stroke(width: sp * 0.13 * ptToMM))

        case let .lyricHyphen(fromOrigin, toOrigin):
            // Short hyphen between two adjacent syllables. Same
            // thickness as the melisma.
            let fx = (mox + Double(fromOrigin.x)) * ptToMM
            let fy = (moy + Double(fromOrigin.y)) * ptToMM
            let tx = (mox + Double(toOrigin.x)) * ptToMM
            let ty = (moy + Double(toOrigin.y)) * ptToMM
            out.append(.moveTo(x: fx, y: fy))
            out.append(.lineTo(x: tx, y: ty))
            out.append(.stroke(width: sp * 0.13 * ptToMM))

        case let .tupletLabel(fromOrigin, toOrigin, text, hasBracket, isAbove, tid):
            // The whole tuplet marking (number + bracket hooks/segments) is one visual unit under a single
            // `.tuplet(tid)` ID — matches Apple's `ScoreLayerBuilder.drawTuplet`, which attaches every one of
            // those layers to the same ID (see `ScoreLayerBuilder+Misc.swift`'s `drawTuplet`).
            let tupletArgb = tid.flatMap { LayoutBridge.tintColor(for: .tuplet($0), tint: tint) }
            if let tupletArgb { out.append(.setColor(argb: tupletArgb)) }
            encodeTupletBracket(
                fromX: mox + Double(fromOrigin.x),
                fromY: moy + Double(fromOrigin.y),
                toX: mox + Double(toOrigin.x),
                toY: moy + Double(toOrigin.y),
                text: text,
                hasBracket: hasBracket,
                isAbove: isAbove,
                sp: sp,
                into: &out,
            )
            if tupletArgb != nil { out.append(.setColor(argb: LayoutBridge.blackARGB)) }

        case let .harmony(lh):
            encodeHarmony(
                harmony: lh,
                measureOriginX: mox, measureOriginY: moy,
                sp: sp,
                into: &out,
            )

        case let .tremoloBars(anchor, barCount):
            let shiftedAnchor: TremoloAnchor
            switch anchor {
            case let .single(c):
                shiftedAnchor = .single(center: CGPoint(
                    x: CGFloat(mox) + c.x,
                    y: CGFloat(moy) + c.y,
                ))
            case let .between(left, right):
                shiftedAnchor = .between(
                    leftStemMid: CGPoint(
                        x: CGFloat(mox) + left.x,
                        y: CGFloat(moy) + left.y,
                    ),
                    rightStemMid: CGPoint(
                        x: CGFloat(mox) + right.x,
                        y: CGFloat(moy) + right.y,
                    ),
                )
            }
            let bars = TremoloGeometry.bars(
                anchor: shiftedAnchor, barCount: barCount,
                sp: CGFloat(sp),
            )
            let thickness = Double(
                TremoloGeometry.barThickness(sp: CGFloat(sp)),
            )
            for bar in bars {
                out.append(.moveTo(
                    x: Double(bar.from.x) * ptToMM,
                    y: Double(bar.from.y) * ptToMM,
                ))
                out.append(.lineTo(
                    x: Double(bar.to.x) * ptToMM,
                    y: Double(bar.to.y) * ptToMM,
                ))
                out.append(.stroke(width: thickness * ptToMM))
            }

        case let .glissandoLine(fromOrigin, toOrigin, wavy, text):
            encodeGlissandoLine(
                fromX: mox + Double(fromOrigin.x),
                fromY: moy + Double(fromOrigin.y),
                toX: mox + Double(toOrigin.x),
                toY: moy + Double(toOrigin.y),
                wavy: wavy,
                text: text,
                sp: sp,
                into: &out,
            )

        case let .spannerSegment(
            kind, fromOrigin, toOrigin, continuesLeft, continuesRight, text,
        ):
            encodeSpanner(
                kind: kind,
                fromX: mox + Double(fromOrigin.x),
                fromY: moy + Double(fromOrigin.y),
                toX: mox + Double(toOrigin.x),
                toY: moy + Double(toOrigin.y),
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                text: text,
                sp: sp,
                glyphSize: glyphSize,
                into: &out,
            )

        // Arpeggio — vertical stack of wiggle glyphs to the left of the
        // chord. The SMuFL glyphs are drawn horizontally in the font, so
        // each segment is rotated -90° about its anchor (mirrors
        // `ArpeggioRenderer.drawRotated` / MuseScore's `painter->rotate(-90)`).
        // The `.setRotation` state opcode rotates the canvas about the
        // glyph anchor; emit the glyph, then clear the rotation.
        case let .arpeggioWiggle(top, bottom, subtype):
            let segments = ArpeggioGeometry.segments(
                top: CGPoint(x: mox + Double(top.x), y: moy + Double(top.y)),
                bottom: CGPoint(
                    x: mox + Double(bottom.x), y: moy + Double(bottom.y),
                ),
                subtype: subtype,
                sp: CGFloat(sp),
            )
            for segment in segments {
                let pivotX = Double(segment.origin.x) * ptToMM
                let pivotY = Double(segment.origin.y) * ptToMM
                out.append(.setRotation(
                    radians: -Double.pi / 2, pivotX: pivotX, pivotY: pivotY,
                ))
                out.append(.glyph(
                    codepoint: segment.codepoint,
                    x: pivotX,
                    y: pivotY,
                    size: glyphSize * ptToMM,
                    fontId: .smufl,
                ))
                out.append(.setRotation(radians: 0, pivotX: 0, pivotY: 0))
            }
        }
    }
}
