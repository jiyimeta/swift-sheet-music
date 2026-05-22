package com.example.sheetmusic.draw

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes the little-endian draw-program byte stream produced by the
 * SheetMusicAndroidJNI Swift target. Format spec lives at
 * Sources/SheetMusicAndroidJNI/DrawProgram.swift — keep both sides in sync.
 *
 * ### Wire layout (v4)
 *
 * ```
 * u32 magic       = 0x534D4450 ("SMDP")
 * u32 version     = 4
 * i32 pageCount
 * [page] × pageCount:
 *     f64 widthMM
 *     f64 heightMM
 *     i32 commandCount
 *     [command] × commandCount   ← u8 discriminator + payload
 *         0 moveTo   (f64 x, f64 y)
 *         1 lineTo   (f64 x, f64 y)
 *         2 stroke   (f64 width)
 *         3 fillRect (f64 x, f64 y, f64 w, f64 h)
 *         4 glyph    (u32 codepoint, f64 x, f64 y, f64 size, u8 fontId)
 *         5 text     (i32 byteLen, utf8, f64 x, f64 y, f64 size, u8 fontId)
 *         6 setColor (u32 argb)
 *         7 cubicTo  (f64 cx1, f64 cy1, f64 cx2, f64 cy2, f64 x, f64 y)
 * ```
 *
 * Discriminators are the declaration-order index from the Swift
 * `@WireFormatChoice` macro on `DrawCommand`. Reordering breaks the
 * wire — bump `version` on the Swift side and update this file in
 * lockstep.
 */
object DrawProgramDecoder {

    private const val MAGIC = 0x53_4D_44_50   // "SMDP"
    private const val VERSION = 4

    class BadMagicException(actual: Int) :
        RuntimeException("bad draw-program magic: 0x${actual.toString(16)}")

    class UnsupportedVersionException(actual: Int) :
        RuntimeException("unsupported draw-program version: $actual")

    class UnknownOpcodeException(actual: Int) :
        RuntimeException("unknown opcode: 0x${actual.toString(16)}")

    fun decode(bytes: ByteArray): DrawProgram {
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val magic = buf.int
        if (magic != MAGIC) throw BadMagicException(magic)
        val version = buf.int
        if (version != VERSION) throw UnsupportedVersionException(version)
        val pageCount = buf.int
        val pages = ArrayList<DrawPage>(pageCount)
        repeat(pageCount) { pages.add(decodePage(buf)) }
        return DrawProgram(pages)
    }

    private fun decodePage(buf: ByteBuffer): DrawPage {
        val w = buf.double
        val h = buf.double
        val n = buf.int
        val cmds = ArrayList<DrawCommand>(n)
        repeat(n) { cmds.add(decodeCommand(buf)) }
        return DrawPage(w, h, cmds)
    }

    private fun decodeCommand(buf: ByteBuffer): DrawCommand =
        when (val op = buf.get().toInt() and 0xFF) {
            0 -> DrawCommand.MoveTo(buf.double, buf.double)
            1 -> DrawCommand.LineTo(buf.double, buf.double)
            2 -> DrawCommand.Stroke(buf.double)
            3 -> DrawCommand.FillRect(buf.double, buf.double,
                                     buf.double, buf.double)
            4 -> DrawCommand.Glyph(
                    codepoint = buf.int.toUInt(),
                    x = buf.double, y = buf.double,
                    size = buf.double,
                    fontId = buf.get().toInt() and 0xFF)
            5 -> {
                val len = buf.int
                val bytes = ByteArray(len); buf.get(bytes)
                DrawCommand.Text(
                    text = String(bytes, Charsets.UTF_8),
                    x = buf.double, y = buf.double,
                    size = buf.double,
                    fontId = buf.get().toInt() and 0xFF)
            }
            6 -> DrawCommand.SetColor(argb = buf.int.toUInt())
            7 -> DrawCommand.CubicTo(
                cx1 = buf.double, cy1 = buf.double,
                cx2 = buf.double, cy2 = buf.double,
                x = buf.double, y = buf.double,
            )
            else -> throw UnknownOpcodeException(op)
        }
}

data class DrawProgram(val pages: List<DrawPage>)
data class DrawPage(val widthMM: Double, val heightMM: Double,
                    val commands: List<DrawCommand>)

sealed interface DrawCommand {
    data class MoveTo(val x: Double, val y: Double) : DrawCommand
    data class LineTo(val x: Double, val y: Double) : DrawCommand
    data class Stroke(val width: Double) : DrawCommand
    data class FillRect(val x: Double, val y: Double,
                        val w: Double, val h: Double) : DrawCommand
    data class Glyph(val codepoint: UInt, val x: Double, val y: Double,
                     val size: Double, val fontId: Int) : DrawCommand
    data class Text(val text: String, val x: Double, val y: Double,
                    val size: Double, val fontId: Int) : DrawCommand
    /** Active paint colour as packed ARGB (0xAARRGGBB). */
    data class SetColor(val argb: UInt) : DrawCommand
    /** Cubic Bezier curve from current path point to (x, y). */
    data class CubicTo(val cx1: Double, val cy1: Double,
                       val cx2: Double, val cy2: Double,
                       val x: Double, val y: Double) : DrawCommand
}
