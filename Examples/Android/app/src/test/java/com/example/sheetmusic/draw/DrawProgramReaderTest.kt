package com.example.sheetmusic.draw

import com.example.sheetmusic.draw.model.DrawCommand
import com.example.sheetmusic.draw.model.DrawProgramWire
import com.example.sheetmusic.draw.model.EncodablePage
import com.example.sheetmusic.draw.model.FontID
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.wirelet.WireFormatException
import io.github.jiyimeta.wirelet.WireType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

private const val MAGIC: UInt = 0x534D_4450u // "SMDP"
private const val VERSION: UInt = 8u

/**
 * Exercises the auto-generated [DrawProgramWireCodec] / [EncodablePageCodec] /
 * [DrawCommandCodec] / [FontIDCodec] objects via the [DrawProgramReader]
 * façade, against wire v8.
 *
 * Two kinds of input: round trips through the generated encoder, and streams
 * built by hand with the runtime's [BinaryWriter] in the TLV layout the Swift
 * `@WireFormat` / `@WireFormatChoice` macros write (see [program]). Only a
 * hand-built stream can carry what no model value expresses — a foreign
 * magic, an old version, discriminator 13, font id 3 — and
 * [handBuiltV8StreamDecodes] is the control showing the builder itself is
 * sound, so each rejection test differs from it in the one value under test.
 */
class DrawProgramReaderTest {

    @Test
    fun singlePageWithLineAndGlyphRoundTrips() {
        val wire = DrawProgramWire(
            magic = MAGIC,
            version = VERSION,
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
            magic = MAGIC,
            version = VERSION,
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

    @Test
    fun beamFillAndSystemFaceRoundTrip() {
        // What v8 added: a beam drawn as a filled quad, and a part label in the system face at semibold.
        val commands = listOf(
            DrawCommand.MoveTo(10.0, 20.0),
            DrawCommand.LineTo(30.0, 18.0),
            DrawCommand.LineTo(30.0, 18.5),
            DrawCommand.LineTo(10.0, 20.5),
            DrawCommand.FillPath,
            DrawCommand.SetTextStyle(DrawCommand.TextStyleFlag.SEMIBOLD),
            DrawCommand.Text("Violin", 5.0, 40.0, 3.0, FontID.SYSTEM),
            DrawCommand.SetTextStyle(DrawCommand.TextStyleFlag.NONE),
        )
        val wire = DrawProgramWire(MAGIC, VERSION, listOf(EncodablePage(100.0, 100.0, commands)))
        val decoded = DrawProgramReader.decode(DrawProgramWireCodec.encode(wire))
        assertEquals(commands, decoded.pages.single().commands)
    }

    @Test
    fun handBuiltV8StreamDecodes() {
        // fillPath is discriminator 12 with no payload; setTextStyle is 11 now that the italic text run is
        // gone; the system face is font id 2.
        val bytes = program {
            command(12)
            command(11) {
                writeTag(1, WireType.VARINT)
                writeVarint(DrawCommand.TextStyleFlag.SEMIBOLD.toLong())
            }
            glyph(fontId = 2)
        }
        assertEquals(
            listOf(
                DrawCommand.FillPath,
                DrawCommand.SetTextStyle(DrawCommand.TextStyleFlag.SEMIBOLD),
                DrawCommand.Glyph(0xE050u, 30.0, 60.0, 24.0, FontID.SYSTEM),
            ),
            DrawProgramReader.decode(bytes).pages.single().commands,
        )
    }

    @Test(expected = DrawProgramReader.BadMagicException::class)
    fun corruptMagicThrows() {
        DrawProgramReader.decode(program(magic = 0xCAFE_BABE) { command(12) })
    }

    @Test
    fun v7StreamIsRefusedAlthoughItParses() {
        // In v7, discriminator 12 was setTextStyle and carried flags. A v8 decoder reads the same bytes as
        // fillPath and drops the flags — structurally valid, silently wrong. The version field is the only
        // thing that stops it, which is why removing a case bumped it.
        val bytes = program(version = 7L) {
            command(12) {
                writeTag(1, WireType.VARINT)
                writeVarint(DrawCommand.TextStyleFlag.BOLD.toLong())
            }
        }
        assertEquals(listOf(DrawCommand.FillPath), DrawProgramWireCodec.decode(bytes).pages.single().commands)
        assertThrows(DrawProgramReader.UnsupportedVersionException::class.java) {
            DrawProgramReader.decode(bytes)
        }
    }

    @Test(expected = WireFormatException.UnknownChoiceDiscriminator::class)
    fun unknownOpcodeThrows() {
        // 12 (fillPath) is v8's last case, so 13 is a command this reader cannot draw.
        DrawProgramReader.decode(program { command(13) })
    }

    @Test(expected = WireFormatException.InvalidCount::class)
    fun unknownFontIdThrows() {
        // 2 (system) is v8's last face; the generated FontIDCodec refuses an ordinal past `entries`.
        DrawProgramReader.decode(program { glyph(fontId = 3) })
    }

    /**
     * A one-page program in the layout the Swift macros write. `DrawProgramWire` is length-prefixed and
     * carries its fields as TLV records — magic 1, version 2, pages 3 — as does each `EncodablePage`
     * (widthMM 1, heightMM 2, commands 3). An array is length-prefixed, and so is each element in it.
     */
    private fun program(
        magic: Long = MAGIC.toLong(),
        version: Long = VERSION.toLong(),
        commands: BinaryWriter.() -> Unit,
    ): ByteArray {
        val w = BinaryWriter()
        w.writeLengthPrefixed {
            writeTag(1, WireType.VARINT)
            writeVarint(magic)
            writeTag(2, WireType.VARINT)
            writeVarint(version)
            writeTag(3, WireType.LENGTH_DELIMITED)
            writeLengthPrefixed { // [EncodablePage]
                writeLengthPrefixed { // the one page
                    writeTag(1, WireType.FIXED64)
                    writeF64(210.0)
                    writeTag(2, WireType.FIXED64)
                    writeF64(297.0)
                    writeTag(3, WireType.LENGTH_DELIMITED)
                    writeLengthPrefixed(commands) // [DrawCommand]
                }
            }
        }
        return w.toByteArray()
    }

    /**
     * One `DrawCommand` array element: its declaration-order [discriminator] as a varint, then the case's
     * associated values as TLV records tagged 1…N. A payload-free case is the discriminator alone.
     */
    private fun BinaryWriter.command(discriminator: Long, fields: BinaryWriter.() -> Unit = {}) {
        writeLengthPrefixed {
            writeVarint(discriminator)
            fields()
        }
    }

    /** A `glyph` (discriminator 4) whose `fontId` — a bare varint, like every `@WireFormatEnum` — is [fontId]. */
    private fun BinaryWriter.glyph(fontId: Long) = command(4) {
        writeTag(1, WireType.VARINT)
        writeVarint(0xE050L)
        writeTag(2, WireType.FIXED64)
        writeF64(30.0)
        writeTag(3, WireType.FIXED64)
        writeF64(60.0)
        writeTag(4, WireType.FIXED64)
        writeF64(24.0)
        writeTag(5, WireType.VARINT)
        writeVarint(fontId)
    }
}
