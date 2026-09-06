package io.github.jiyimeta.sheetmusic.compose.render

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.draw.model.FontID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ScoreBandsTest {

    private fun page(vararg commands: DrawCommand) = EncodablePage(210.0, 2000.0, commands.toList())

    /** A filled rect is the simplest command with an exact, un-padded vertical extent. */
    private fun rect(y: Double, height: Double = 1.0) = DrawCommand.FillRect(0.0, y, 10.0, height)

    @Test
    fun `empty page yields no bands`() {
        assertEquals(emptyList<ScoreBand>(), page().splitIntoBands(80.0))
    }

    @Test
    fun `short page stays a single band`() {
        val bands = page(rect(0.0), rect(10.0), rect(20.0)).splitIntoBands(80.0)
        assertEquals(1, bands.size)
        assertEquals(0.0, bands[0].topMM, 1e-9)
        assertEquals(21.0, bands[0].heightMM, 1e-9)
    }

    @Test
    fun `tall page splits once the minimum height is exceeded`() {
        val commands = (0 until 40).map { rect(it * 10.0) }
        val bands = page(*commands.toTypedArray()).splitIntoBands(80.0)
        assertTrue("expected several bands, got ${bands.size}", bands.size >= 4)
        bands.forEach { assertTrue("band shorter than nothing", it.heightMM > 0.0) }
    }

    @Test
    fun `every drawing command lands in exactly one band`() {
        val commands = (0 until 40).map { rect(it * 10.0) }
        val bands = page(*commands.toTypedArray()).splitIntoBands(80.0)
        val emitted = bands.flatMap { band -> band.commands.filterIsInstance<DrawCommand.FillRect>() }
        assertEquals(commands, emitted)
    }

    @Test
    fun `bands cover the page top to bottom in order`() {
        val commands = (0 until 40).map { rect(it * 10.0) }
        val bands = page(*commands.toTypedArray()).splitIntoBands(80.0)
        assertEquals(0.0, bands.first().topMM, 1e-9)
        assertEquals(390.0 + 1.0, bands.last().topMM + bands.last().heightMM, 1e-9)
        bands.zipWithNext { a, b -> assertTrue("bands out of order", b.topMM >= a.topMM) }
    }

    @Test
    fun `each band draws in the colour that was in force where it starts`() {
        val commands = buildList {
            add(DrawCommand.SetColor(0xFFFF_0000u))
            repeat(40) { add(rect(it * 10.0)) }
        }
        val bands = EncodablePage(210.0, 2000.0, commands).splitIntoBands(80.0)
        assertTrue("expected a split", bands.size > 1)
        bands.forEach { band ->
            // Every band opens with a SetColor prefix, so a band is drawable on its own. The FIRST band
            // restates the program's initial black and then replays the real SetColor that follows it;
            // later bands carry the red forward. What must hold for all of them is the same thing: by the
            // time the band paints anything, red is in force.
            assertTrue("band does not open with SetColor", band.commands.first() is DrawCommand.SetColor)
            assertEquals(0xFFFF_0000u, band.colourAtFirstPaint())
        }
    }

    /** Colour in force when this band paints its first [DrawCommand.FillRect]. */
    private fun ScoreBand.colourAtFirstPaint(): UInt {
        var argb = 0xFF00_0000u
        commands.forEach { cmd ->
            when (cmd) {
                is DrawCommand.SetColor -> argb = cmd.argb
                is DrawCommand.FillRect -> return argb
                else -> Unit
            }
        }
        throw AssertionError("band paints nothing")
    }

    @Test
    fun `each band restates an active dash`() {
        val commands = buildList {
            add(DrawCommand.SetDash(2.0, 1.0))
            repeat(40) { add(rect(it * 10.0)) }
        }
        val bands = EncodablePage(210.0, 2000.0, commands).splitIntoBands(80.0)
        assertTrue("expected a split", bands.size > 1)
        bands.forEach { band ->
            val dash = band.commands.filterIsInstance<DrawCommand.SetDash>().first()
            assertEquals(2.0, dash.onMM, 1e-9)
            assertEquals(1.0, dash.offMM, 1e-9)
        }
    }

    @Test
    fun `each band restates an active text style`() {
        // The band cut happens BEFORE a command is appended, so it can land between a
        // SetTextStyle(bold) and the text it styles. Without the restated prefix the second band
        // would draw a bold tempo mark or rehearsal mark at regular weight — and its frame, which
        // the Swift side sized from bold metrics, would no longer fit the letters inside it.
        val commands = buildList {
            add(DrawCommand.SetTextStyle(DrawCommand.TextStyleFlag.BOLD))
            repeat(40) { add(rect(it * 10.0)) }
        }
        val bands = EncodablePage(210.0, 2000.0, commands).splitIntoBands(80.0)
        assertTrue("expected a split", bands.size > 1)
        bands.forEach { band ->
            val style = band.commands.filterIsInstance<DrawCommand.SetTextStyle>().first()
            assertEquals(DrawCommand.TextStyleFlag.BOLD, style.flags)
        }
    }

    @Test
    fun `the neutral text style is not restated`() {
        // Restating the neutral style would put a SetTextStyle(0) at the head of every band of every
        // unstyled score — pure noise in the common case, and it would make the banded command
        // stream differ from the flat one for a program that carries no styling at all.
        val commands = (0 until 40).map { rect(it * 10.0) }
        val bands = EncodablePage(210.0, 2000.0, commands).splitIntoBands(80.0)
        assertTrue("expected a split", bands.size > 1)
        bands.forEach { band ->
            assertTrue(
                "unstyled band carries a style prefix",
                band.commands.none { it is DrawCommand.SetTextStyle },
            )
        }
    }

    @Test
    fun `a state command contributes no vertical extent`() {
        // SetTextStyle paints nothing, so it must not widen a band's painted extent — a band whose
        // bounds grew for a state command would over-report its height and the host would size a
        // layer larger than the ink in it.
        val plain = EncodablePage(210.0, 2000.0, listOf(rect(10.0))).splitIntoBands(80.0)
        val styled = EncodablePage(
            210.0,
            2000.0,
            listOf(DrawCommand.SetTextStyle(DrawCommand.TextStyleFlag.BOLD), rect(10.0)),
        ).splitIntoBands(80.0)
        assertEquals(plain.size, styled.size)
        assertEquals(plain[0].topMM, styled[0].topMM, 1e-9)
        assertEquals(plain[0].heightMM, styled[0].heightMM, 1e-9)
    }

    @Test
    fun `a path under construction is never split across bands`() {
        // One very tall path: its MoveTo..Stroke run alone exceeds the band height, so a naive splitter
        // would cut inside it and strand the tail in a band with no MoveTo.
        val commands = buildList {
            add(DrawCommand.MoveTo(0.0, 0.0))
            repeat(40) { add(DrawCommand.LineTo(1.0, it * 10.0)) }
            add(DrawCommand.Stroke(0.5))
            repeat(40) { add(rect(500.0 + it * 10.0)) }
        }
        val bands = EncodablePage(210.0, 2000.0, commands).splitIntoBands(80.0)
        bands.forEach { band ->
            var open = false
            band.commands.forEach { cmd ->
                when (cmd) {
                    is DrawCommand.MoveTo -> open = true
                    is DrawCommand.Stroke -> {
                        assertTrue("Stroke without a MoveTo in this band", open)
                        open = false
                    }
                    is DrawCommand.LineTo -> assertTrue("LineTo outside a path", open)
                    is DrawCommand.CubicTo -> assertTrue("CubicTo outside a path", open)
                    else -> Unit
                }
            }
            assertTrue("band ends with a path still open", !open)
        }
    }

    @Test
    fun `a rotated run is never split across bands`() {
        val commands = buildList {
            add(DrawCommand.SetRotation(1.57, 0.0, 0.0))
            repeat(40) { add(rect(it * 10.0)) }
            add(DrawCommand.SetRotation(0.0, 0.0, 0.0))
            repeat(40) { add(rect(500.0 + it * 10.0)) }
        }
        val bands = EncodablePage(210.0, 2000.0, commands).splitIntoBands(80.0)
        bands.forEach { band ->
            var rotated = false
            band.commands.forEach { cmd ->
                if (cmd is DrawCommand.SetRotation) rotated = cmd.radians != 0.0
            }
            assertTrue("band ends inside a rotation", !rotated)
        }
    }

    @Test
    fun `band extent covers a stroke's width`() {
        val bands = page(
            DrawCommand.MoveTo(0.0, 10.0),
            DrawCommand.LineTo(10.0, 10.0),
            DrawCommand.Stroke(4.0),
        ).splitIntoBands(80.0)
        assertEquals(1, bands.size)
        assertTrue("stroke width not reflected above the line", bands[0].topMM <= 10.0 - 2.0)
        assertTrue(
            "stroke width not reflected below the line",
            bands[0].topMM + bands[0].heightMM >= 10.0 + 2.0,
        )
    }

    @Test
    fun `band extent covers a glyph above its baseline`() {
        val bands = page(DrawCommand.Glyph(0xE0A4u, 5.0, 50.0, 7.0, FontID.SMUFL)).splitIntoBands(80.0)
        assertEquals(1, bands.size)
        assertTrue("glyph ascent not covered", bands[0].topMM < 50.0)
        assertTrue("glyph descent not covered", bands[0].topMM + bands[0].heightMM > 50.0)
    }
}
