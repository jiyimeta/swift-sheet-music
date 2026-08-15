import Foundation
import SheetMusicCore
import SheetMusicLayout

/// System-start decorations for the Android draw-command bridge: the
/// vertical system barline joining all staves at the left edge, plus each
/// `BracketItem`'s brace / bracket. Mirrors the Apple renderer's
/// `ScoreCanvasDrawing.drawSystem` (barline) and `StaffRenderer.drawBrackets`
/// (braces / brackets) so both platforms engrave the same geometry. Before
/// this was added the bridge walked staff lines, measure elements, and
/// spanners only — `system.brackets` and the barline were silently dropped,
/// so Android showed neither.
extension LayoutBridge {
    static func appendSystemStart(
        for system: LayoutSystem,
        sysOriginX: Double,
        sysOriginY: Double,
        sp: Double,
        staffLineThickness: Double,
        into out: inout [DrawCommand],
    ) {
        guard let firstStaff = system.staffOrigins.first else { return }

        // ── System barline: a vertical line at the staff-left edge from the
        //    top of the first staff to the bottom of the last staff, each end
        //    taken from that staff's own line count (see
        //    `LayoutSystem.systemStartBarLine`). ──
        if let span = system.systemStartBarLine {
            let barX = (sysOriginX + Double(span.x)) * ptToMMScale
            let barTop = (sysOriginY + Double(span.top)) * ptToMMScale
            let barBottom = (sysOriginY + Double(span.bottom)) * ptToMMScale
            out.append(.moveTo(x: barX, y: barTop))
            out.append(.lineTo(x: barX, y: barBottom))
            out.append(.stroke(width: staffLineThickness * ptToMMScale))
        }

        // ── Part / instrument labels at the system's left edge. ──
        // `label.origin.x` already encodes the right-edge X (clearing any
        // bracket columns); `.partLabel`'s `.trailingCenter` anchor lands the
        // text's right edge there, matching the Apple `PartLabelRenderer`.
        for label in system.partLabels {
            encodeNotationText(
                text: label.text,
                role: .partLabel,
                originX: sysOriginX + Double(label.origin.x),
                originY: sysOriginY + Double(label.origin.y),
                sp: sp,
                into: &out,
            )
        }

        // ── Brackets / braces, dispatching on each item's type. ──
        guard !system.brackets.isEmpty else { return }
        let staffOriginX = sysOriginX + Double(firstStaff.x)
        for b in system.brackets {
            let topY = sysOriginY + Double(b.topY)
            let bottomY = sysOriginY + Double(b.bottomY)
            switch b.type {
            case .noBracket:
                continue
            case .brace:
                appendBrace(
                    staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    staffCount: b.staffCount, sp: sp, into: &out,
                )
            case .normal:
                appendNormalBracket(
                    column: b.column, staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY, sp: sp, into: &out,
                )
            case .square:
                appendSquareBracket(
                    column: b.column, staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    sp: sp, staffLineThickness: staffLineThickness, into: &out,
                )
            case .line:
                appendLineBracket(
                    column: b.column, staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    sp: sp, staffLineThickness: staffLineThickness, into: &out,
                )
            }
        }
    }

    /// Horizontal column of the bracket spine. Column 0 sits closest to the
    /// staff; higher columns stack further left. Mirrors
    /// `StaffRenderer.bracketSpineX`.
    private static func bracketSpineX(
        column: Int, staffOriginX: Double, sp: Double,
    ) -> Double {
        staffOriginX - sp * 0.5 - Double(column) * sp
    }

    /// Thick bracket: a 0.45 sp spine plus the SMuFL `bracketTop` /
    /// `bracketBottom` cap glyphs at each end (baseline-leading, which is the
    /// Android `.glyph` anchor and matches `StaffRenderer.drawNormalBracket`).
    private static func appendNormalBracket(
        column: Int, staffOriginX: Double,
        topY: Double, bottomY: Double, sp: Double,
        into out: inout [DrawCommand],
    ) {
        let x = bracketSpineX(column: column, staffOriginX: staffOriginX, sp: sp)
        let w = sp * 0.45
        let bd = sp * 0.25
        out.append(.moveTo(
            x: x * ptToMMScale, y: (topY - bd - w * 0.5) * ptToMMScale,
        ))
        out.append(.lineTo(
            x: x * ptToMMScale, y: (bottomY + bd + w * 0.5) * ptToMMScale,
        ))
        out.append(.stroke(width: w * ptToMMScale))
        let glyphLeftX = x - w * 0.5
        let fontSize = sp * 4
        out.append(.glyph(
            codepoint: SMuFLCodepoint.bracketTop,
            x: glyphLeftX * ptToMMScale,
            y: (topY - bd) * ptToMMScale,
            size: fontSize * ptToMMScale,
            fontId: .smufl,
        ))
        out.append(.glyph(
            codepoint: SMuFLCodepoint.bracketBottom,
            x: glyphLeftX * ptToMMScale,
            y: (bottomY + bd) * ptToMMScale,
            size: fontSize * ptToMMScale,
            fontId: .smufl,
        ))
    }

    /// Thin square bracket: a spine plus top + bottom serifs, all at
    /// `staffLineThickness` (mirrors `StaffRenderer.drawSquareBracket`).
    private static func appendSquareBracket(
        column: Int, staffOriginX: Double,
        topY: Double, bottomY: Double,
        sp: Double, staffLineThickness: Double,
        into out: inout [DrawCommand],
    ) {
        let x = bracketSpineX(column: column, staffOriginX: staffOriginX, sp: sp)
        let lineW = staffLineThickness
        let serifLength = sp * 0.45
        out.append(.moveTo(x: x * ptToMMScale, y: topY * ptToMMScale))
        out.append(.lineTo(x: x * ptToMMScale, y: bottomY * ptToMMScale))
        out.append(.stroke(width: lineW * ptToMMScale))
        for y in [topY, bottomY] {
            out.append(.moveTo(
                x: (x - lineW * 0.5) * ptToMMScale, y: y * ptToMMScale,
            ))
            out.append(.lineTo(
                x: (x + serifLength) * ptToMMScale, y: y * ptToMMScale,
            ))
            out.append(.stroke(width: lineW * ptToMMScale))
        }
    }

    /// Plain vertical line bracket: 0.67 × bracket width, ends extending
    /// `staffLineThickness / 2` past the span (mirrors
    /// `StaffRenderer.drawLineBracket`).
    private static func appendLineBracket(
        column: Int, staffOriginX: Double,
        topY: Double, bottomY: Double,
        sp: Double, staffLineThickness: Double,
        into out: inout [DrawCommand],
    ) {
        let x = bracketSpineX(column: column, staffOriginX: staffOriginX, sp: sp)
        let w = 0.67 * sp * 0.45
        let bd = staffLineThickness * 0.5
        out.append(.moveTo(x: x * ptToMMScale, y: (topY - bd) * ptToMMScale))
        out.append(.lineTo(x: x * ptToMMScale, y: (bottomY + bd) * ptToMMScale))
        out.append(.stroke(width: w * ptToMMScale))
    }

    /// Curly brace via the appropriate Bravura variant glyph, stretched in Y
    /// to fit the span and in X by MuseScore's `magx`. Emitted as a
    /// `.stretchedGlyph` so the Kotlin renderer measures the glyph and applies
    /// the non-uniform transform — a uniform `.glyph` can't express it.
    /// Mirrors `StaffRenderer.drawBrace`; `BraceMetrics.variant` is the same
    /// shared source of truth the Apple brace renderer consults.
    private static func appendBrace(
        staffOriginX: Double,
        topY: Double, bottomY: Double,
        staffCount: Int, sp: Double,
        into out: inout [DrawCommand],
    ) {
        let rightEdge = staffOriginX - sp * 0.3
        let (codepoint, magx) = BraceMetrics.variant(staffCount: staffCount)
        out.append(.stretchedGlyph(
            codepoint: UInt32(codepoint),
            rightEdgeX: rightEdge * ptToMMScale,
            topY: topY * ptToMMScale,
            bottomY: bottomY * ptToMMScale,
            fontSize: sp * 4 * ptToMMScale,
            xScale: Double(magx),
            fontId: .smufl,
        ))
    }
}
