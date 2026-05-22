package com.example.sheetmusic.draw

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class DrawProgramDecoderTest {

    @Test
    fun emptyProgramHasZeroPages() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x53_4D_44_50.toInt())   // magic "SMDP"
            putInt(4)                       // version
            putInt(0)                       // pageCount (i32)
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

    @Test
    fun textCommandDecodesUtf8WithInt32LengthPrefix() {
        val bytes = buildProgram {
            page(widthMM = 100.0, heightMM = 100.0) {
                text("Allegro", x = 10.0, y = 20.0,
                     size = 12.0, fontId = 0)
            }
        }

        val program = DrawProgramDecoder.decode(bytes)
        val cmd = program.pages[0].commands[0] as DrawCommand.Text
        assertEquals("Allegro", cmd.text)
        assertEquals(10.0, cmd.x, 0.0)
        assertEquals(0, cmd.fontId)
    }

    @Test(expected = DrawProgramDecoder.BadMagicException::class)
    fun corruptMagicThrows() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0xCAFEBABE.toInt())
            putInt(4); putInt(0)
        }.array()
        DrawProgramDecoder.decode(bytes)
    }

    @Test(expected = DrawProgramDecoder.UnsupportedVersionException::class)
    fun wrongVersionThrows() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x53_4D_44_50.toInt())
            putInt(99); putInt(0)
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
        var capacity = 12 // magic + version + pageCount
        for (p in pages) capacity += p.byteSize
        val buf = ByteBuffer.allocate(capacity).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(0x53_4D_44_50.toInt()); buf.putInt(4); buf.putInt(pages.size)
        for (p in pages) p.writeTo(buf)
        return buf.array()
    }
}

private class PageBuilder(val widthMM: Double, val heightMM: Double) {
    private val cmds = mutableListOf<ByteArray>()
    val byteSize: Int get() = 8 + 8 + 4 + cmds.sumOf { it.size }

    fun moveTo(x: Double, y: Double)   = emit { it.put(0); it.putDouble(x); it.putDouble(y) }
    fun lineTo(x: Double, y: Double)   = emit { it.put(1); it.putDouble(x); it.putDouble(y) }
    fun stroke(w: Double)              = emit { it.put(2); it.putDouble(w) }
    fun glyph(codepoint: UInt, x: Double, y: Double, size: Double, fontId: Int) =
        emit {
            it.put(4); it.putInt(codepoint.toInt())
            it.putDouble(x); it.putDouble(y); it.putDouble(size); it.put(fontId.toByte())
        }
    fun text(s: String, x: Double, y: Double, size: Double, fontId: Int) =
        emit {
            val utf8 = s.toByteArray(Charsets.UTF_8)
            it.put(5); it.putInt(utf8.size); it.put(utf8)
            it.putDouble(x); it.putDouble(y); it.putDouble(size); it.put(fontId.toByte())
        }

    private fun emit(write: (ByteBuffer) -> Unit) {
        val tmp = ByteBuffer.allocate(128).order(ByteOrder.LITTLE_ENDIAN)
        write(tmp); tmp.flip()
        val arr = ByteArray(tmp.remaining()); tmp.get(arr); cmds.add(arr)
    }

    fun writeTo(buf: ByteBuffer) {
        buf.putDouble(widthMM); buf.putDouble(heightMM)
        buf.putInt(cmds.size)
        for (c in cmds) buf.put(c)
    }
}
