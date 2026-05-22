package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class ScoreCursorDecoderTest {

    private fun loadGolden(name: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("golden/$name")!!.readBytes()

    // MARK: - Canonical values (matching GoldenBinaryTests.swift)

    private val canonicalNoteID = NoteID(
        staff = StaffAddress(partIndex = 1, staffIndexInPart = 0),
        measureIndex = 4,
        voiceIndex = 0,
        elementIndex = 2,
        noteIndexInChord = 1,
    )

    private val canonicalCursorItem = ScoreCursor.Item(ScoreItemID.Note(canonicalNoteID))

    // ScoreCursor.beat(measureIndex: 2, tickInMeasure: 480)
    private val canonicalCursorBeat = ScoreCursor.Beat(measureIndex = 2, tickInMeasure = 480)

    // MARK: - Item case golden test

    @Test
    fun scoreCursorItemGoldenDecodes() {
        val bytes = loadGolden("scoreCursor-v1.bin")
        val decoded = ScoreCursorDecoder.decode(bytes)
        assertEquals(canonicalCursorItem, decoded)
    }

    // MARK: - Beat case golden test

    @Test
    fun scoreCursorBeatGoldenDecodes() {
        val bytes = loadGolden("scoreCursor-beat-v1.bin")
        val decoded = ScoreCursorDecoder.decode(bytes)
        assertEquals(canonicalCursorBeat, decoded)
    }

    // MARK: - Beat case inline test

    @Test
    fun beatCaseInlineDecodes() {
        // discriminator=1 (Beat), measureIndex=7, tickInMeasure=960
        val bytes = byteArrayOf(
            0x01,                    // discriminator = 1 (Beat)
            0x07, 0x00, 0x00, 0x00,  // measureIndex = 7
            0xC0.toByte(), 0x03, 0x00, 0x00,  // tickInMeasure = 960
        )
        val decoded = ScoreCursorDecoder.decode(bytes)
        assertEquals(ScoreCursor.Beat(measureIndex = 7, tickInMeasure = 960), decoded)
    }

    // MARK: - Unknown discriminator

    @Test
    fun unknownDiscriminatorThrows() {
        val bytes = byteArrayOf(0x02) // discriminator = 2 (unknown)
        try {
            ScoreCursorDecoder.decode(bytes)
            fail("Expected error for unknown discriminator")
        } catch (_: IllegalStateException) {
            // expected
        }
    }
}
