import Foundation
import SheetMusicCore
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGPoint`,
    /// clashing with SheetMusicLayout's stub. Anchor to the Layout definition
    /// so that `LayoutElement` associated values match the parameter type.
    private typealias CGPoint = SheetMusicLayout.CGPoint
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
/// 1. Five staff lines per staff origin (moveTo + lineTo + stroke triples).
/// 2. Per `LayoutMeasure`: its elements — clef glyphs, time-sig glyphs,
///    note-head glyphs, rest glyphs, and barline strokes. Unknown/unhandled
///    element types fall back to a small `fillRect` placeholder.
public enum LayoutBridge {
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
        // Convert mm → pt for the layout engine's availableWidth.
        let mmToPt = 72.0 / 25.4
        let availableWidthPt = Double(pageWidthMM) * mmToPt

        let options = ScoreViewOptions(
            wrapToViewWidth: true,
            includeTitleFrame: false,
        )
        let layout = LayoutEngine.layout(
            score: score,
            options: options,
            availableWidth: availableWidthPt,
        )

        let commands = buildCommands(layout: layout)
        let page = EncodablePage(
            widthMM: pageWidthMM,
            heightMM: pageHeightMM,
            commands: commands,
        )
        return DrawProgramEncoder.encode(pages: [page])
    }

    // MARK: - Command builder

    private static func buildCommands(layout: LayoutDocument) -> [DrawCommand] {
        var out: [DrawCommand] = []
        let metrics = layout.metrics
        let context = MetricsContext(
            sp: Double(metrics.sp),
            glyphSize: Double(metrics.glyphFontSize),
            defaultStemLength: Double(metrics.defaultStemLength),
            stemThickness: Double(metrics.stemThickness),
        )
        let staffLineThickness = Double(metrics.staffLineThickness)

        for system in layout.systems {
            let sysOriginX = Double(system.origin.x)
            let sysOriginY = Double(system.origin.y)
            // Stop the staff lines at the rightmost stroke of the system
            // terminal barline so the staff doesn't trail past it through
            // the per-measure gutter.
            let endX = Double(BarLineGeometry.staffLineEndX(for: system))

            // ── 1. Staff lines ──────────────────────────────────────────────
            for staffOrigin in system.staffOrigins {
                let ox = Double(staffOrigin.x) + sysOriginX
                let oy = Double(staffOrigin.y) + sysOriginY
                let rightX = endX + sysOriginX
                for line in 0 ..< 5 {
                    let y = oy + Double(line) * context.sp
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
                    into: &out,
                )
            }
        }
        return out
    }

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

        case let .keySignature(sharps, flats, origin):
            encodeKeySignature(
                sharps: sharps,
                flats: flats,
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                glyphSize: glyphSize,
                into: &out,
            )

        case let .chord(
            notes, duration, stem, stemOrigin, _, _, isBeamed, _, stemExtension,
        ):
            encodeChord(
                notes: notes, duration: duration, stem: stem,
                stemOriginY: Double(stemOrigin.y),
                isBeamed: isBeamed, stemExtension: Double(stemExtension),
                mag: 1,
                measureOriginX: mox, measureOriginY: moy,
                metrics: ctx, into: &out,
            )

        case let .graceChord(notes, duration, stem, stemOrigin, _, _, mag, _):
            encodeChord(
                notes: notes, duration: duration, stem: stem,
                stemOriginY: Double(stemOrigin.y),
                isBeamed: false, stemExtension: 0,
                mag: Double(mag),
                measureOriginX: mox, measureOriginY: moy,
                metrics: ctx, into: &out,
            )

        case let .rest(duration, origin, _, _, hasLegerLine):
            emitCenterAnchoredGlyph(
                codepoint: RestGlyph.codepoint(
                    duration: duration, hasLegerLine: hasLegerLine,
                ),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )

        case let .barLine(_, origin):
            // Barline origin sits at the staff middle; strokes extend
            // ±2 sp from that point. Width = 0.15 sp (the thin-stroke
            // engraving default). Subtype-specific extras (double,
            // end, repeat dots) are a follow-up.
            let halfHeight = Double(BarLineGeometry.halfHeightSp) * sp
            let bx = (mox + Double(origin.x)) * ptToMM
            let byMid = (moy + Double(origin.y)) * ptToMM
            out.append(.moveTo(x: bx, y: byMid - halfHeight * ptToMM))
            out.append(.lineTo(x: bx, y: byMid + halfHeight * ptToMM))
            out.append(.stroke(
                width: Double(BarLineGeometry.thinThicknessSp) * sp * ptToMM,
            ))

        case let .beam(fromOrigin, toOrigin, direction, level):
            // Each beam emit at a given level: shift Y by the level
            // offset so secondaries stack inward from the primary,
            // matching Apple BeamRenderer's geometry.
            let dy = Double(BeamGeometry.levelOffsetDy(
                level: level, stemDirection: direction, sp: CGFloat(sp),
            ))
            // Draw the centre of the beam stroke at `dy + beamThickness/2`
            // so the stroke's outer edge aligns with the chord's stem
            // tip (matching Apple's filled-rectangle geometry).
            let thickness = Double(BeamGeometry.beamThicknessSp) * sp
            let stackSign: Double = direction == .up ? 1 : -1
            let centerDy = dy + (thickness / 2) * stackSign
            let fx = (mox + Double(fromOrigin.x)) * ptToMM
            let fy = (moy + Double(fromOrigin.y) + centerDy) * ptToMM
            let tx = (mox + Double(toOrigin.x)) * ptToMM
            let ty = (moy + Double(toOrigin.y) + centerDy) * ptToMM
            out.append(.moveTo(x: fx, y: fy))
            out.append(.lineTo(x: tx, y: ty))
            out.append(.stroke(width: thickness * ptToMM))

        case let .textMark(kind, text, origin):
            emitText(
                text: text,
                style: TextRoleStyle.style(for: kind),
                originX: mox + Double(origin.x),
                originY: moy + Double(origin.y),
                sp: sp,
                into: &out,
            )

        case let .staffText(text, origin, color, isSystemText):
            let argb = color.flatMap(LayoutBridge.argb(from:))
            if let argb { out.append(.setColor(argb: argb)) }
            emitText(
                text: text,
                style: isSystemText ? .systemText : .staffText,
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

        case let .fermata(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .marker(_, _, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .rehearsalMark(_, origin, _, _):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .jump(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .measureRepeat(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .multiMeasureRest(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .measureNumber(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .staffName(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

        case let .articulation(_, origin, _):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

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

        case let .tupletLabel(fromOrigin, toOrigin, text, hasBracket, isAbove, _):
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

        // Decorations deferred to a future task — require richer geometry.
        case .harmony, .spannerSegment, .glissandoLine,
             .arpeggioWiggle, .tremoloBars:
            break
        }
    }
}
