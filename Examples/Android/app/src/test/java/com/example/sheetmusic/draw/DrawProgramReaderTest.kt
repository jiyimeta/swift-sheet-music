package com.example.sheetmusic.draw

import com.example.sheetmusic.draw.model.DrawCommand
import com.example.sheetmusic.draw.model.DrawProgram
import com.example.sheetmusic.draw.model.EncodablePage
import com.example.sheetmusic.draw.model.FontID
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Exercises the auto-generated `DrawProgramCodec` / `EncodablePageCodec` /
 * `DrawCommandCodec` / `FontIDCodec` objects via the `DrawProgramReader`
 * façade. Round-trips real programs through encode → decode to confirm
 * the macro-driven codec matches the wire layout consumed on the Swift
 * side; raw-byte fixtures verify magic / version validation.
 */
class DrawProgramReaderTest {

    @Test
    fun emptyProgramHasZeroPages() {
        val bytes = encodeRaw(version = 4, pageCount = 0)
        val program = DrawProgramReader.decode(bytes)
        assertEquals(0, program.pages.size)
    }

    @Test
    fun singlePageWithLineAndGlyphRoundTrips() {
        val program = DrawProgram(
            magic = 0x534D_4450L,
            version = 4L,
            pages = listOf(
                EncodablePage(
                    widthMM = 210.0,
                    heightMM = 297.0,
                    commands = listOf(
                        DrawCommand.MoveTo(20.0, 40.0),
                        DrawCommand.LineTo(190.0, 40.0),
                        DrawCommand.Stroke(0.5),
                        DrawCommand.Glyph(
                            codepoint = 0xE050L,
                            x = 30.0, y = 60.0,
                            size = 24.0,
                            fontId = FontID.SMUFL,
                        ),
                    ),
                ),
            ),
        )
        val bytes = DrawProgramCodec.encode(program)
        val decoded = DrawProgramReader.decode(bytes)

        assertEquals(1, decoded.pages.size)
        val page = decoded.pages[0]
        assertEquals(210.0, page.widthMM, 0.0)
        assertEquals(297.0, page.heightMM, 0.0)
        assertEquals(4, page.commands.size)
        val glyph = page.commands[3] as DrawCommand.Glyph
        assertEquals(0xE050L, glyph.codepoint)
        assertEquals(30.0, glyph.x, 0.0)
        assertEquals(FontID.SMUFL, glyph.fontId)
    }

    @Test
    fun textCommandRoundTrips() {
        val program = DrawProgram(
            magic = 0x534D_4450L,
            version = 4L,
            pages = listOf(
                EncodablePage(
                    widthMM = 100.0, heightMM = 100.0,
                    commands = listOf(
                        DrawCommand.Text(
                            text = "Allegro",
                            x = 10.0, y = 20.0,
                            size = 12.0,
                            fontId = FontID.TEXT_ROMAN,
                        ),
                    ),
                ),
            ),
        )
        val decoded = DrawProgramReader.decode(DrawProgramCodec.encode(program))
        val cmd = decoded.pages[0].commands[0] as DrawCommand.Text
        assertEquals("Allegro", cmd.text)
        assertEquals(10.0, cmd.x, 0.0)
        assertEquals(FontID.TEXT_ROMAN, cmd.fontId)
    }

    @Test(expected = DrawProgramReader.BadMagicException::class)
    fun corruptMagicThrows() {
        val bytes = encodeRaw(magic = 0xCAFE_BABE.toInt(), version = 4, pageCount = 0)
        DrawProgramReader.decode(bytes)
    }

    @Test(expected = DrawProgramReader.UnsupportedVersionException::class)
    fun wrongVersionThrows() {
        val bytes = encodeRaw(version = 99, pageCount = 0)
        DrawProgramReader.decode(bytes)
    }

    /** Builds a 12-byte header-only program. Used for header validation tests. */
    private fun encodeRaw(
        magic: Int = 0x534D_4450,
        version: Int,
        pageCount: Int,
    ): ByteArray = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
        putInt(magic)
        putInt(version)
        putInt(pageCount)
    }.array()
}
