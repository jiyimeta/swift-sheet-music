// swiftlint:disable file_length
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
        computeWithDocument(
            score: score,
            pageWidthMM: pageWidthMM,
            pageHeightMM: pageHeightMM,
            options: .verticalDefault,
        ).encoded
    }

    // MARK: - Command builder

    static func buildCommands(layout: LayoutDocument) -> [DrawCommand] {
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
            notes, duration, stem, stemOrigin, _, _, isBeamed, _, stemExtension, _,
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

        case let .beam(fromOrigin, toOrigin, direction, level, _):
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

        case let .multiMeasureRest(_, origin):
            placeholderRect(atX: Double(origin.x), atY: Double(origin.y), mox: mox, moy: moy, sp: sp, into: &out)

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

        case let .glissandoLine(fromOrigin, toOrigin, wavy, _):
            // Text label is omitted on Android until we can measure
            // text in the rotated frame; the line itself is the
            // visually-dominant element of the glissando.
            encodeGlissandoLine(
                fromX: mox + Double(fromOrigin.x),
                fromY: moy + Double(fromOrigin.y),
                toX: mox + Double(toOrigin.x),
                toY: moy + Double(toOrigin.y),
                wavy: wavy,
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

        // Arpeggio defers until a rotation opcode lands in the wire
        // format — the wiggle glyphs are designed for a horizontal
        // baseline and need a -90° rotation to read as a vertical
        // arpeggio.
        case .arpeggioWiggle:
            break
        }
    }
}
