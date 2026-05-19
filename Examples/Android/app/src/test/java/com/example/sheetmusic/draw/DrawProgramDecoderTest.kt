package com.example.sheetmusic.draw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class DrawProgramDecoderTest {

    @Test
    fun emptyProgramHasZeroPages() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x53_4D_44_50.toInt())   // magic "SMDP"
            putInt(1)                       // version
            putInt(0)                       // pageCount
        }.array()

        val program = DrawProgramDecoder.decode(bytes)

        assertEquals(0, program.pages.size)
    }

    @Test
    fun singlePageWithLineAndGlyphDecodes() {
        val bytes = buildProgram {
            page(widthMM = 210.0, heightMM = 297.0) {
                moveTo(20.0, 40.0)
                lineTo(190.0, 40.0)
                stroke(0.5)
                glyph(codepoint = 0xE050u, x = 30.0, y = 60.0,
                      size = 24.0, fontId = 1)
            }
        }

        val program = DrawProgramDecoder.decode(bytes)

        assertEquals(1, program.pages.size)
        val page = program.pages[0]
        assertEquals(210.0, page.widthMM, 0.0)
        assertEquals(297.0, page.heightMM, 0.0)
        assertEquals(4, page.commands.size)
        val glyph = page.commands[3] as DrawCommand.Glyph
        assertEquals(0xE050u, glyph.codepoint)
        assertEquals(30.0, glyph.x, 0.0)
        assertEquals(1, glyph.fontId)
    }

    @Test(expected = DrawProgramDecoder.BadMagicException::class)
    fun corruptMagicThrows() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0xCAFEBABE.toInt())
            putInt(1); putInt(0)
        }.array()
        DrawProgramDecoder.decode(bytes)
    }
}

/** Small fluent builder used only by this test. Mirrors the spec format. */
private fun buildProgram(block: ProgramBuilder.() -> Unit): ByteArray {
    val b = ProgramBuilder()
    b.block()
    return b.toBytes()
}

private class ProgramBuilder {
    private val pages = mutableListOf<PageBuilder>()
    fun page(widthMM: Double, heightMM: Double, block: PageBuilder.() -> Unit) {
        val p = PageBuilder(widthMM, heightMM)
        p.block(); pages.add(p)
    }
    fun toBytes(): ByteArray {
        var capacity = 12
        for (p in pages) capacity += p.byteSize
        val buf = ByteBuffer.allocate(capacity).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(0x53_4D_44_50.toInt()); buf.putInt(1); buf.putInt(pages.size)
        for (p in pages) p.writeTo(buf)
        return buf.array()
    }
}

private class PageBuilder(val widthMM: Double, val heightMM: Double) {
    private val cmds = mutableListOf<ByteArray>()
    val byteSize: Int get() = 8 + 8 + 4 + cmds.sumOf { it.size }

    fun moveTo(x: Double, y: Double)   = emit { it.put(0x01); it.putDouble(x); it.putDouble(y) }
    fun lineTo(x: Double, y: Double)   = emit { it.put(0x02); it.putDouble(x); it.putDouble(y) }
    fun stroke(w: Double)              = emit { it.put(0x03); it.putDouble(w) }
    fun glyph(codepoint: UInt, x: Double, y: Double, size: Double, fontId: Int) =
        emit {
            it.put(0x05); it.putInt(codepoint.toInt())
            it.putDouble(x); it.putDouble(y); it.putDouble(size); it.put(fontId.toByte())
        }

    private fun emit(write: (ByteBuffer) -> Unit) {
        val tmp = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN)
        write(tmp); tmp.flip()
        val arr = ByteArray(tmp.remaining()); tmp.get(arr); cmds.add(arr)
    }

    fun writeTo(buf: ByteBuffer) {
        buf.putDouble(widthMM); buf.putDouble(heightMM)
        buf.putInt(cmds.size)
        for (c in cmds) buf.put(c)
    }
}
