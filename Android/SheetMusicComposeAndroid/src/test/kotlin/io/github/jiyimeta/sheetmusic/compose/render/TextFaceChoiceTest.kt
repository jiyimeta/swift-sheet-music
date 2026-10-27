package io.github.jiyimeta.sheetmusic.compose.render

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand.TextStyleFlag.BOLD
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand.TextStyleFlag.ITALIC
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand.TextStyleFlag.SEMIBOLD
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Strings stand in for typefaces: "R" the text face, "B" / "I" / "BI" the real bold, italic and bold-italic faces.
 * With styled faces given, a styled run draws in its own face with no synthesis; without them, in the text face with
 * the synthesis the renderer has always applied.
 */
class TextFaceChoiceTest {
    @Test
    fun `a bold run draws the real bold face when one is given`() =
        assertEquals(TextFaceChoice("B", false, false), chooseTextFace(BOLD, "R", "B", "I", "BI"))

    @Test
    fun `without styled faces bold is synthesized as before`() =
        assertEquals(TextFaceChoice("R", true, false), chooseTextFace(BOLD, "R", null, null, null))

    @Test
    fun `an italic run draws the real italic face when one is given`() =
        assertEquals(TextFaceChoice("I", false, false), chooseTextFace(ITALIC, "R", "B", "I", "BI"))

    @Test
    fun `without styled faces italic is skewed as before`() =
        assertEquals(TextFaceChoice("R", false, true), chooseTextFace(ITALIC, "R", null, null, null))

    @Test
    fun `bold italic picks the bold italic face`() =
        assertEquals(TextFaceChoice("BI", false, false), chooseTextFace(BOLD or ITALIC, "R", "B", "I", "BI"))

    @Test
    fun `without styled faces bold italic synthesizes both`() =
        assertEquals(TextFaceChoice("R", true, true), chooseTextFace(BOLD or ITALIC, "R", null, null, null))

    @Test
    fun `semibold draws regular`() =
        assertEquals(TextFaceChoice("R", false, false), chooseTextFace(SEMIBOLD, "R", "B", "I", "BI"))

    @Test
    fun `semibold draws regular without styled faces too`() =
        assertEquals(TextFaceChoice("R", false, false), chooseTextFace(SEMIBOLD, "R", null, null, null))
}
