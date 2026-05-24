package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.wireformat.BinaryReader

import io.github.jiyimeta.sheetmusic.audio.model.ClefAnchor
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.TupletID
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertEquals
import org.junit.Test

class ScoreItemIDDecoderTest {

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

    private val canonicalRestID = RestID(
        staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
        measureIndex = 2,
        voiceIndex = 1,
        elementIndex = 0,
    )

    private val canonicalTupletID = TupletID(
        staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
        measureIndex = 3,
        voiceIndex = 0,
        startElementIndex = 5,
    )

    private val canonicalClefExplicit = ClefAnchor.Explicit(
        VoiceElementID(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
            measureIndex = 1,
            voiceIndex = 0,
            elementIndex = 0,
        ),
    )

    private val canonicalClefStaffDefault = ClefAnchor.StaffDefault(
        StaffAddress(partIndex = 0, staffIndexInPart = 0),
    )

    // MARK: - Note case golden test

    @Test
    fun scoreItemIdNoteGoldenDecodes() {
        val bytes = loadGolden("scoreItemId-v1.bin")
        val decoded = ScoreItemIDCodec.decode(bytes)
        assertEquals(ScoreItemID.Note(canonicalNoteID), decoded)
    }

    // MARK: - Rest case golden test

    @Test
    fun scoreItemIdRestGoldenDecodes() {
        val bytes = loadGolden("scoreItemId-rest-v1.bin")
        val decoded = ScoreItemIDCodec.decode(bytes)
        assertEquals(ScoreItemID.Rest(canonicalRestID), decoded)
    }

    // MARK: - Tuplet case golden test

    @Test
    fun scoreItemIdTupletGoldenDecodes() {
        val bytes = loadGolden("scoreItemId-tuplet-v1.bin")
        val decoded = ScoreItemIDCodec.decode(bytes)
        assertEquals(ScoreItemID.Tuplet(canonicalTupletID), decoded)
    }

    // MARK: - Clef explicit case golden test

    @Test
    fun scoreItemIdClefExplicitGoldenDecodes() {
        val bytes = loadGolden("scoreItemId-clef-explicit-v1.bin")
        val decoded = ScoreItemIDCodec.decode(bytes)
        assertEquals(ScoreItemID.Clef(canonicalClefExplicit), decoded)
    }

    // MARK: - Clef staffDefault case golden test

    @Test
    fun scoreItemIdClefStaffDefaultGoldenDecodes() {
        val bytes = loadGolden("scoreItemId-clef-staffDefault-v1.bin")
        val decoded = ScoreItemIDCodec.decode(bytes)
        assertEquals(ScoreItemID.Clef(canonicalClefStaffDefault), decoded)
    }

    // MARK: - Array decoder

    @Test
    fun decodeArrayDecodesTwoItems() {
        // Build a 2-element array: [Note(canonicalNoteID), Rest(canonicalRestID)]
        // count(4) + Note payload + Rest payload (no version envelope)
        val notePayload = byteArrayOf(
            0x00,  // discriminator = 0 (Note)
            0x01, 0x00, 0x00, 0x00,  // partIndex = 1
            0x00, 0x00, 0x00, 0x00,  // staffIndexInPart = 0
            0x04, 0x00, 0x00, 0x00,  // measureIndex = 4
            0x00, 0x00, 0x00, 0x00,  // voiceIndex = 0
            0x02, 0x00, 0x00, 0x00,  // elementIndex = 2
            0x01, 0x00, 0x00, 0x00,  // noteIndexInChord = 1
        )
        val restPayload = byteArrayOf(
            0x01,  // discriminator = 1 (Rest)
            0x00, 0x00, 0x00, 0x00,  // partIndex = 0
            0x00, 0x00, 0x00, 0x00,  // staffIndexInPart = 0
            0x02, 0x00, 0x00, 0x00,  // measureIndex = 2
            0x01, 0x00, 0x00, 0x00,  // voiceIndex = 1
            0x00, 0x00, 0x00, 0x00,  // elementIndex = 0
        )
        val header = byteArrayOf(0x02, 0x00, 0x00, 0x00) // count = 2
        val bytes = header + notePayload + restPayload
        val r = BinaryReader(bytes)
        val count = r.readI32()
        val decoded = ArrayList<ScoreItemID>(count)
        for (i in 0 until count) decoded.add(ScoreItemIDCodec.decodePayload(r))
        assertEquals(2, decoded.size)
        assertEquals(ScoreItemID.Note(canonicalNoteID), decoded[0])
        assertEquals(ScoreItemID.Rest(canonicalRestID), decoded[1])
    }

    @Test
    fun decodeArrayEmptyList() {
        val bytes = byteArrayOf(0x00, 0x00, 0x00, 0x00) // count = 0
        val r = BinaryReader(bytes)
        val count = r.readI32()
        val decoded = ArrayList<ScoreItemID>(count)
        for (i in 0 until count) decoded.add(ScoreItemIDCodec.decodePayload(r))
        assertEquals(0, decoded.size)
    }
}
