package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.EditCaretFrame
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.SelectionTint
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The two editing-geometry payloads, against the same `.bin` files the Swift side asserts on
 * (`GoldenBinaryTests.editCaretFrameGoldenMatches` / `selectionTintGoldenMatches`).
 *
 * These codecs are generated from one Swift schema (`Sources/SheetMusicEditWire/Geometry`, the
 * `editGeometry` source set) precisely so no one hand-writes a second spelling of them — but generated
 * from one schema is not the same as agreeing byte-for-byte, and nothing at runtime would notice a
 * disagreement: a mis-encoded tint recolours the wrong notes and a mis-decoded caret floats in the wrong
 * place, both silently. The golden is the only thing that checks.
 */
class EditGeometryCodecTest {

    private fun loadGolden(name: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("golden/$name")!!.readBytes()

    /** Matches `GoldenBinaryTests.canonicalCaretFrame`. */
    private val canonicalCaretFrame = EditCaretFrame(
        xMm = 12.5,
        yMm = 30.25,
        widthMm = 1.5,
        heightMm = 24.0,
    )

    /** Matches `GoldenBinaryTests.canonicalScoreItemIDNote`, the same value the ID goldens use. */
    private val canonicalNote = ScoreItemID.Note(
        NoteID(
            staff = StaffAddress(partIndex = 1, staffIndexInPart = 0),
            measureIndex = 4,
            voiceIndex = 0,
            elementIndex = 2,
            noteIndexInChord = 1,
        ),
    )

    /** Matches `GoldenBinaryTests.canonicalTintArgb`. */
    private val canonicalTint = SelectionTint(
        argb = 0xFF3366CCu,
        items = listOf(canonicalNote),
    )

    @Test
    fun decodesTheCaretFrameGolden() {
        assertEquals(canonicalCaretFrame, EditCaretFrameCodec.decode(loadGolden("editCaretFrame-v1.bin")))
    }

    @Test
    fun encodesTheCaretFrameGolden() {
        assertArrayEqualsNamed(loadGolden("editCaretFrame-v1.bin"), EditCaretFrameCodec.encode(canonicalCaretFrame))
    }

    @Test
    fun decodesTheSelectionTintGolden() {
        assertEquals(canonicalTint, SelectionTintCodec.decode(loadGolden("selectionTint-v1.bin")))
    }

    @Test
    fun encodesTheSelectionTintGolden() {
        assertArrayEqualsNamed(loadGolden("selectionTint-v1.bin"), SelectionTintCodec.encode(canonicalTint))
    }

    private fun assertArrayEqualsNamed(expected: ByteArray, actual: ByteArray) =
        assertEquals(expected.joinToString(" ") { "%02x".format(it) }, actual.joinToString(" ") { "%02x".format(it) })
}
