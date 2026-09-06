package io.github.jiyimeta.sheetmusic.compose.draw.model

/**
 * One painter command. Subclass declaration order must match the Swift
 * `@WireFormatChoice DrawCommand` cases in
 * `Sources/SheetMusicAndroidJNI/DrawProgram.swift` — the wire
 * discriminator is the declaration-order index emitted by the
 * macro-driven codec.
 */
sealed class DrawCommand {
    data class MoveTo(val x: Double, val y: Double) : DrawCommand()
    data class LineTo(val x: Double, val y: Double) : DrawCommand()
    data class Stroke(val width: Double) : DrawCommand()
    data class FillRect(
        val x: Double, val y: Double,
        val w: Double, val h: Double,
    ) : DrawCommand()
    data class Glyph(
        val codepoint: UInt,
        val x: Double, val y: Double,
        val size: Double,
        val fontId: FontID,
    ) : DrawCommand()
    data class Text(
        val text: String,
        val x: Double, val y: Double,
        val size: Double,
        val fontId: FontID,
    ) : DrawCommand()
    /** Active paint colour as packed ARGB (0xAARRGGBB). */
    data class SetColor(val argb: UInt) : DrawCommand()
    /** Cubic Bezier curve from current path point to (x, y). */
    data class CubicTo(
        val cx1: Double, val cy1: Double,
        val cx2: Double, val cy2: Double,
        val x: Double, val y: Double,
    ) : DrawCommand()
    /**
     * A SMuFL glyph stretched non-uniformly to fit a vertical span — the
     * system brace at a system's left edge. The renderer measures the glyph
     * at [fontSize], scales Y so its bounding box spans [[topY], [bottomY]],
     * scales X by [xScale], and positions the box's right edge at
     * [rightEdgeX]. A plain [Glyph] (uniform size) can't express this.
     */
    data class StretchedGlyph(
        val codepoint: UInt,
        val rightEdgeX: Double,
        val topY: Double,
        val bottomY: Double,
        val fontSize: Double,
        val xScale: Double,
        val fontId: FontID,
    ) : DrawCommand()
    /**
     * Rotate the canvas by [radians] about the pivot (document mm) for every
     * subsequent command, until reset with `radians == 0`. A state command
     * like [SetColor]: emit the non-zero rotation, draw the rotated content,
     * then emit `SetRotation(0, 0, 0)` to restore. Arpeggio wiggles (90°)
     * and glissando labels (gliss angle) use this.
     */
    data class SetRotation(
        val radians: Double,
        val pivotX: Double,
        val pivotY: Double,
    ) : DrawCommand()
    /**
     * Dash pattern for subsequent stroked paths, in document mm. `(0, 0)`
     * clears it (solid). State command; reset after the dashed stroke. The
     * ottava line uses this.
     */
    data class SetDash(
        val onMM: Double,
        val offMM: Double,
    ) : DrawCommand()
    /**
     * Italic text run — same payload as [Text], but the renderer slants the
     * glyphs.
     *
     * SUPERSEDED by [SetTextStyle] in wire v7 and no longer emitted. Kept so
     * the discriminators after it do not move and so this renderer keeps
     * handling any stream that still carries it.
     */
    data class ItalicText(
        val text: String,
        val x: Double,
        val y: Double,
        val size: Double,
        val fontId: FontID,
    ) : DrawCommand()

    /**
     * Font style for every subsequent [Text] and [Glyph], until the next
     * [SetTextStyle]. A state command like [SetColor] / [SetDash] /
     * [SetRotation]: set the style, draw, then `SetTextStyle(0u)`.
     *
     * [flags] is a bitmask — see [TextStyleFlag] — rather than two booleans,
     * so a third trait costs no wire change.
     *
     * MuseScore's own role defaults set tempo marks, rehearsal marks and
     * instrument-change text bold. Before this command the wire could not say
     * so, and this renderer drew them in regular weight while the Apple one
     * drew them bold.
     */
    data class SetTextStyle(val flags: UByte) : DrawCommand()

    /** Bit positions in [SetTextStyle.flags]. Mirrors Swift's `DrawCommand.TextStyleFlag`. */
    object TextStyleFlag {
        const val BOLD: UByte = 1u
        const val ITALIC: UByte = 2u

        /** The neutral style — what each page starts in, and what a styled run restores. */
        const val NONE: UByte = 0u
    }
}
