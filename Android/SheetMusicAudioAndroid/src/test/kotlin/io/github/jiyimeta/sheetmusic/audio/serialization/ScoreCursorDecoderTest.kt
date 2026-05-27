package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.wirelet.WireFormatException

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
        val decoded = ScoreCursorCodec.decode(bytes)
        assertEquals(canonicalCursorItem, decoded)
    }

    // MARK: - Beat case golden test

    @Test
    fun scoreCursorBeatGoldenDecodes() {
        val bytes = loadGolden("scoreCursor-beat-v1.bin")
        val decoded = ScoreCursorCodec.decode(bytes)
        assertEquals(canonicalCursorBeat, decoded)
    }

    // MARK: - Beat case inline TLV test

    @Test
    fun beatCaseInlineDecodes() {
        // ScoreCursor.Beat(measureIndex=7, tickInMeasure=960) encoded with TLV codec
        val value = ScoreCursor.Beat(measureIndex = 7, tickInMeasure = 960)
        val encoded = ScoreCursorCodec.encode(value)
        val decoded = ScoreCursorCodec.decode(encoded)
        assertEquals(value, decoded)
    }

    // MARK: - Unknown discriminator

    @Test
    fun unknownDiscriminatorThrows() {
        // Build a TLV payload with discriminator=2 (unknown)
        val outer = BinaryWriter()
        outer.writeLengthPrefixed {
            writeVarint(2L) // discriminator = 2 (unknown)
        }
        try {
            ScoreCursorCodec.decode(outer.toByteArray())
            fail("Expected error for unknown discriminator")
        } catch (_: WireFormatException.UnknownChoiceDiscriminator) {
            // expected — TLV codecs throw UnknownChoiceDiscriminator for out-of-range discriminators
        }
    }
}
