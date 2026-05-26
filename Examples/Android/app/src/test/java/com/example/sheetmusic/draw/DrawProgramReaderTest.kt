package com.example.sheetmusic.draw

import com.example.sheetmusic.draw.model.DrawCommand
import com.example.sheetmusic.draw.model.DrawProgramWire
import com.example.sheetmusic.draw.model.EncodablePage
import com.example.sheetmusic.draw.model.FontID
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Exercises the auto-generated [DrawProgramWireCodec] / [EncodablePageCodec] /
 * [DrawCommandCodec] / [FontIDCodec] objects via the [DrawProgramReader]
 * façade.
 *
 * NOTE: The raw-byte helpers below use the old *positional* wire format
 * (magic | version | pageCount as little-endian Int32 fields). The wirelet
 * plugin emits a TLV-based format instead, so the header-validation tests
 * that call [encodeRaw] will fail at runtime until Task 11 regenerates
 * fixtures for the new format. That is expected and acceptable.
 */
class DrawProgramReaderTest {

    @Test
    fun singlePageWithLineAndGlyphRoundTrips() {
        val wire = DrawProgramWire(
            magic = 0x534D_4450u,
            version = 4u,
            pages = listOf(
                EncodablePage(
                    widthMM = 210.0,
                    heightMM = 297.0,
                    commands = listOf(
                        DrawCommand.MoveTo(20.0, 40.0),
                        DrawCommand.LineTo(190.0, 40.0),
                        DrawCommand.Stroke(0.5),
                        DrawCommand.Glyph(
                            codepoint = 0xE050u,
                            x = 30.0, y = 60.0,
                            size = 24.0,
                            fontId = FontID.SMUFL,
                        ),
                    ),
                ),
            ),
        )
        val bytes = DrawProgramWireCodec.encode(wire)
        val decoded = DrawProgramReader.decode(bytes)

        assertEquals(1, decoded.pages.size)
        val page = decoded.pages[0]
        assertEquals(210.0, page.widthMM, 0.0)
        assertEquals(297.0, page.heightMM, 0.0)
        assertEquals(4, page.commands.size)
        val glyph = page.commands[3] as DrawCommand.Glyph
        assertEquals(0xE050u, glyph.codepoint)
        assertEquals(30.0, glyph.x, 0.0)
        assertEquals(FontID.SMUFL, glyph.fontId)
    }

    @Test
    fun textCommandRoundTrips() {
        val wire = DrawProgramWire(
            magic = 0x534D_4450u,
            version = 4u,
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
        val decoded = DrawProgramReader.decode(DrawProgramWireCodec.encode(wire))
        val cmd = decoded.pages[0].commands[0] as DrawCommand.Text
        assertEquals("Allegro", cmd.text)
        assertEquals(10.0, cmd.x, 0.0)
        assertEquals(FontID.TEXT_ROMAN, cmd.fontId)
    }

    @Test(expected = DrawProgramReader.BadMagicException::class)
    fun corruptMagicThrows() {
        // NOTE: encodeRaw produces old positional format — will fail at the
        // TLV decode step before reaching magic validation. Acceptable until
        // Task 11 updates fixtures for the wirelet TLV format.
        val bytes = encodeRaw(magic = 0xCAFE_BABE.toInt(), version = 4, pageCount = 0)
        DrawProgramReader.decode(bytes)
    }

    @Test(expected = DrawProgramReader.UnsupportedVersionException::class)
    fun wrongVersionThrows() {
        // NOTE: encodeRaw produces old positional format — will fail at the
        // TLV decode step before reaching version validation. Acceptable until
        // Task 11 updates fixtures for the wirelet TLV format.
        val bytes = encodeRaw(version = 99, pageCount = 0)
        DrawProgramReader.decode(bytes)
    }

    /** Builds a 12-byte header-only program in the *old* positional format. */
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
