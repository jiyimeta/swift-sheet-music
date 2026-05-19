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
            let sysWidth = Double(system.size.width)

            // ── 1. Staff lines ──────────────────────────────────────────────
            for staffOrigin in system.staffOrigins {
                let ox = Double(staffOrigin.x) + sysOriginX
                let oy = Double(staffOrigin.y) + sysOriginY
                for line in 0 ..< 5 {
                    let y = oy + Double(line) * context.sp
                    out.append(.moveTo(
                        x: ox * ptToMM,
                        y: y * ptToMM,
                    ))
                    out.append(.lineTo(
                        x: (ox + sysWidth) * ptToMM,
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
            notes, duration, stem, _, _, _, isBeamed, _, stemExtension,
        ):
            encodeChord(
                notes: notes, duration: duration, stem: stem,
                isBeamed: isBeamed, stemExtension: Double(stemExtension),
                mag: 1,
                measureOriginX: mox, measureOriginY: moy,
                metrics: ctx, into: &out,
            )

        case let .graceChord(notes, duration, stem, _, _, _, mag, _):
            encodeChord(
                notes: notes, duration: duration, stem: stem,
                isBeamed: false, stemExtension: 0,
                mag: Double(mag),
                measureOriginX: mox, measureOriginY: moy,
                metrics: ctx, into: &out,
            )

        case let .rest(duration, origin, _, _, _):
            emitCenterAnchoredGlyph(
                codepoint: restCodepoint(duration: duration),
                cxPt: mox + Double(origin.x),
                cyPt: moy + Double(origin.y),
                sizePt: glyphSize,
                into: &out,
            )

        case let .barLine(_, origin):
            // Vertical stroke spanning the staff height (4 sp).
            let bx = (mox + Double(origin.x)) * ptToMM
            let by = (moy + Double(origin.y)) * ptToMM
            out.append(.moveTo(x: bx, y: by))
            out.append(.lineTo(x: bx, y: by + sp * 4 * ptToMM))
            out.append(.stroke(width: 0.5 * ptToMM))

        case let .beam(fromOrigin, toOrigin, _, _):
            let fx = (mox + Double(fromOrigin.x)) * ptToMM
            let fy = (moy + Double(fromOrigin.y)) * ptToMM
            let tx = (mox + Double(toOrigin.x)) * ptToMM
            let ty = (moy + Double(toOrigin.y)) * ptToMM
            out.append(.moveTo(x: fx, y: fy))
            out.append(.lineTo(x: tx, y: ty))
            out.append(.stroke(width: sp * 0.5 * ptToMM))

        case let .textMark(kind, text, origin):
            let pointSize = Double(TextRoleStyle.fontSize(
                for: TextRoleStyle.style(for: kind),
                sp: CGFloat(sp),
            ))
            out.append(.text(
                text,
                x: (mox + Double(origin.x)) * ptToMM,
                y: (moy + Double(origin.y)) * ptToMM,
                size: pointSize * ptToMM,
                fontId: .textRoman,
            ))

        case let .staffText(text, origin, _, isSystemText):
            let role: TextStyleType = isSystemText ? .systemText : .staffText
            let pointSize = Double(TextRoleStyle.fontSize(
                for: role, sp: CGFloat(sp),
            ))
            out.append(.text(
                text,
                x: (mox + Double(origin.x)) * ptToMM,
                y: (moy + Double(origin.y)) * ptToMM,
                size: pointSize * ptToMM,
                fontId: .textRoman,
            ))

        // Fallback for unhandled point-origin cases: tiny placeholder rect.
        case let .note(_, _, _, _, origin, _, _, _):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .fermata(_, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .marker(_, _, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .rehearsalMark(_, origin, _, _):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .jump(_, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .measureRepeat(_, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .multiMeasureRest(_, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .measureNumber(_, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .staffName(_, origin):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        case let .articulation(_, origin, _):
            placeholderRect(at: origin, mox: mox, moy: moy, sp: sp, into: &out)

        // Decorations deferred to a future task — require richer geometry.
        case .harmony, .spannerSegment, .tieArc,
             .lyricsMelisma, .lyricHyphen, .glissandoLine,
             .arpeggioWiggle, .tremoloBars, .tupletLabel:
            break
        }
    }

    // MARK: - Geometry helpers

    private static func placeholderRect(
        at origin: CGPoint,
        mox: Double,
        moy: Double,
        sp: Double,
        into out: inout [DrawCommand],
    ) {
        out.append(.fillRect(
            x: (mox + Double(origin.x)) * ptToMM,
            y: (moy + Double(origin.y)) * ptToMM,
            w: sp * ptToMM,
            h: sp * ptToMM,
        ))
    }

    // MARK: - Rest codepoints

    private static func restCodepoint(duration: NoteDuration) -> UInt32 {
        switch duration {
        case .whole: return SMuFLCodepoint.restWhole
        case .half: return SMuFLCodepoint.restHalf
        case .quarter: return SMuFLCodepoint.restQuarter
        default: return SMuFLCodepoint.rest8th
        }
    }
}
