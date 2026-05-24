package com.example.sheetmusic.draw.model

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
        val codepoint: Long,
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
    data class SetColor(val argb: Long) : DrawCommand()
    /** Cubic Bezier curve from current path point to (x, y). */
    data class CubicTo(
        val cx1: Double, val cy1: Double,
        val cx2: Double, val cy2: Double,
        val x: Double, val y: Double,
    ) : DrawCommand()
}
