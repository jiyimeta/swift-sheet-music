import Foundation
import SheetMusicCore
import SheetMusicLayout

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

    // MARK: - SMuFL codepoints (subset)

    private enum SMuFL {
        static let gClef: UInt32 = 0xE050
        static let cClef: UInt32 = 0xE05C
        static let fClef: UInt32 = 0xE062
        static let noteheadBlack: UInt32 = 0xE0A4
        static let noteheadHalf: UInt32 = 0xE0A3
        static let noteheadWhole: UInt32 = 0xE0A2
        static let restWhole: UInt32 = 0xE4E3
        static let restHalf: UInt32 = 0xE4E4
        static let restQuarter: UInt32 = 0xE4E5
        static let restEighth: UInt32 = 0xE4E6
        static let timeSig0: UInt32 = 0xE080
        static let keyFlat: UInt32 = 0xE260
        static let keySharp: UInt32 = 0xE262
    }

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
        // Staff line spacing in pt.
        let sp = Double(metrics.sp)
        let staffLineThickness = Double(metrics.staffLineThickness)
        let glyphSize = Double(metrics.glyphFontSize)

        for system in layout.systems {
            let sysOriginX = Double(system.origin.x)
            let sysOriginY = Double(system.origin.y)
            let sysWidth = Double(system.size.width)

            // ── 1. Staff lines ──────────────────────────────────────────────
            for staffOrigin in system.staffOrigins {
                let ox = Double(staffOrigin.x) + sysOriginX
                let oy = Double(staffOrigin.y) + sysOriginY
                for line in 0 ..< 5 {
                    let y = oy + Double(line) * sp
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
                        sp: sp,
                        glyphSize: glyphSize,
                        into: &out,
                    )
                }
            }
        }
        return out
    }

    // MARK: - Per-element encoder

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func encodeElement(
        _ element: LayoutElement,
        measureOriginX mox: Double,
        measureOriginY moy: Double,
        sp: Double,
        glyphSize: Double,
        into out: inout [DrawCommand],
    ) {
        switch element {
        case let .clef(rawType, origin, _):
            let cp = clefCodepoint(rawType: rawType)
            out.append(.glyph(
                codepoint: cp,
                x: (mox + Double(origin.x)) * ptToMM,
                y: (moy + Double(origin.y)) * ptToMM,
                size: glyphSize * ptToMM,
                fontId: .smufl,
            ))

        case let .timeSignature(numerator, denominator, origin):
            let ox = mox + Double(origin.x)
            let oy = moy + Double(origin.y)
            // Numerator above, denominator below — each offset by sp.
            for (idx, digit) in [numerator, denominator].enumerated() {
                let cp = SMuFL.timeSig0 + UInt32(digit)
                out.append(.glyph(
                    codepoint: cp,
                    x: ox * ptToMM,
                    y: (oy + Double(idx) * sp * 2) * ptToMM,
                    size: glyphSize * ptToMM,
                    fontId: .smufl,
                ))
            }

        case let .keySignature(sharps, flats, origin):
            let ox = mox + Double(origin.x)
            let oy = moy + Double(origin.y)
            if sharps > 0 {
                for i in 0 ..< sharps {
                    out.append(.glyph(
                        codepoint: SMuFL.keySharp,
                        x: (ox + Double(i) * sp * 0.7) * ptToMM,
                        y: oy * ptToMM,
                        size: glyphSize * ptToMM,
                        fontId: .smufl,
                    ))
                }
            } else if flats > 0 {
                for i in 0 ..< flats {
                    out.append(.glyph(
                        codepoint: SMuFL.keyFlat,
                        x: (ox + Double(i) * sp * 0.7) * ptToMM,
                        y: oy * ptToMM,
                        size: glyphSize * ptToMM,
                        fontId: .smufl,
                    ))
                }
            }

        case let .chord(notes, duration, _, _, _, _, _, _, _):
            let cp = noteheadCodepoint(duration: duration)
            for note in notes {
                out.append(.glyph(
                    codepoint: cp,
                    x: (mox + Double(note.origin.x)) * ptToMM,
                    y: (moy + Double(note.origin.y)) * ptToMM,
                    size: glyphSize * ptToMM,
                    fontId: .smufl,
                ))
            }

        case let .graceChord(notes, duration, _, _, _, _, mag, _):
            let cp = noteheadCodepoint(duration: duration)
            for note in notes {
                out.append(.glyph(
                    codepoint: cp,
                    x: (mox + Double(note.origin.x)) * ptToMM,
                    y: (moy + Double(note.origin.y)) * ptToMM,
                    size: glyphSize * Double(mag) * ptToMM,
                    fontId: .smufl,
                ))
            }

        case let .rest(duration, origin, _, _, _):
            let cp = restCodepoint(duration: duration)
            out.append(.glyph(
                codepoint: cp,
                x: (mox + Double(origin.x)) * ptToMM,
                y: (moy + Double(origin.y)) * ptToMM,
                size: glyphSize * ptToMM,
                fontId: .smufl,
            ))

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

        case let .textMark(_, text, origin):
            out.append(.text(
                text,
                x: (mox + Double(origin.x)) * ptToMM,
                y: (moy + Double(origin.y)) * ptToMM,
                size: sp * 4 * ptToMM,
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

        case let .staffText(_, origin, _, _):
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

    // MARK: - Codepoint helpers

    private static func clefCodepoint(rawType: String) -> UInt32 {
        switch rawType {
        case "G", "G2", "GClef": return SMuFL.gClef
        case "F", "F3", "F4", "FClef": return SMuFL.fClef
        default: return SMuFL.cClef
        }
    }

    private static func noteheadCodepoint(duration: NoteDuration) -> UInt32 {
        switch duration {
        case .whole: return SMuFL.noteheadWhole
        case .half: return SMuFL.noteheadHalf
        default: return SMuFL.noteheadBlack
        }
    }

    private static func restCodepoint(duration: NoteDuration) -> UInt32 {
        switch duration {
        case .whole: return SMuFL.restWhole
        case .half: return SMuFL.restHalf
        case .quarter: return SMuFL.restQuarter
        default: return SMuFL.restEighth
        }
    }
}
