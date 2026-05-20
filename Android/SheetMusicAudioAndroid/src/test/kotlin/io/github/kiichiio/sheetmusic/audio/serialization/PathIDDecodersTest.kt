package io.github.kiichiio.sheetmusic.audio.serialization

import io.github.kiichiio.sheetmusic.audio.model.NoteID
import io.github.kiichiio.sheetmusic.audio.model.RestID
import io.github.kiichiio.sheetmusic.audio.model.StaffAddress
import io.github.kiichiio.sheetmusic.audio.model.TupletID
import io.github.kiichiio.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class PathIDDecodersTest {

    private fun loadGolden(name: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("golden/$name")!!.readBytes()

    // MARK: - Canonical values (matching GoldenBinaryTests.swift)

    private val canonicalStaffAddress = StaffAddress(partIndex = 1, staffIndexInPart = 0)

    private val canonicalNoteID = NoteID(
        staff = StaffAddress(partIndex = 1, staffIndexInPart = 0),
        measureIndex = 4,
        voiceIndex = 0,
        elementIndex = 2,
        noteIndexInChord = 1,
    )

    // MARK: - StaffAddress golden tests

    @Test
    fun staffAddressGoldenDecodes() {
        val bytes = loadGolden("staffAddress-v1.bin")
        // staffAddress-v1.bin: version(2) + partIndex(4) + staffIndexInPart(4) = 10 bytes
        val decoded = StaffAddressDecoder.decode(bytes)
        assertEquals(canonicalStaffAddress, decoded)
    }

    @Test
    fun staffAddressGoldenPayloadLength() {
        val bytes = loadGolden("staffAddress-v1.bin")
        assertEquals(10, bytes.size)
    }

    // MARK: - NoteID golden tests

    @Test
    fun noteIdGoldenDecodes() {
        val bytes = loadGolden("noteId-v1.bin")
        val decoded = NoteIDDecoder.decode(bytes)
        assertEquals(canonicalNoteID, decoded)
    }

    @Test
    fun noteIdGoldenPayloadLength() {
        val bytes = loadGolden("noteId-v1.bin")
        // version(2) + StaffAddress(8) + measureIndex(4) + voiceIndex(4)
        // + elementIndex(4) + noteIndexInChord(4) = 26 bytes
        assertEquals(26, bytes.size)
    }

    // MARK: - Payload-only decoder tests (inline byte arrays)

    @Test
    fun staffAddressPayloadDecodes() {
        // partIndex=3, staffIndexInPart=1
        val bytes = byteArrayOf(
            0x03, 0x00, 0x00, 0x00,  // partIndex = 3
            0x01, 0x00, 0x00, 0x00,  // staffIndexInPart = 1
        )
        val r = BinaryReader(bytes)
        val decoded = StaffAddressDecoder.decodePayload(r)
        assertEquals(StaffAddress(partIndex = 3, staffIndexInPart = 1), decoded)
    }

    @Test
    fun voiceElementIDPayloadDecodes() {
        // StaffAddress(2,0) + measureIndex=5 + voiceIndex=1 + elementIndex=3
        val bytes = byteArrayOf(
            0x02, 0x00, 0x00, 0x00,  // partIndex = 2
            0x00, 0x00, 0x00, 0x00,  // staffIndexInPart = 0
            0x05, 0x00, 0x00, 0x00,  // measureIndex = 5
            0x01, 0x00, 0x00, 0x00,  // voiceIndex = 1
            0x03, 0x00, 0x00, 0x00,  // elementIndex = 3
        )
        val r = BinaryReader(bytes)
        val decoded = VoiceElementIDDecoder.decodePayload(r)
        assertEquals(
            VoiceElementID(
                staff = StaffAddress(2, 0),
                measureIndex = 5,
                voiceIndex = 1,
                elementIndex = 3,
            ),
            decoded,
        )
    }

    @Test
    fun restIDPayloadDecodes() {
        // StaffAddress(0,0) + measureIndex=2 + voiceIndex=1 + elementIndex=0
        val bytes = byteArrayOf(
            0x00, 0x00, 0x00, 0x00,  // partIndex = 0
            0x00, 0x00, 0x00, 0x00,  // staffIndexInPart = 0
            0x02, 0x00, 0x00, 0x00,  // measureIndex = 2
            0x01, 0x00, 0x00, 0x00,  // voiceIndex = 1
            0x00, 0x00, 0x00, 0x00,  // elementIndex = 0
        )
        val r = BinaryReader(bytes)
        val decoded = RestIDDecoder.decodePayload(r)
        assertEquals(
            RestID(
                staff = StaffAddress(0, 0),
                measureIndex = 2,
                voiceIndex = 1,
                elementIndex = 0,
            ),
            decoded,
        )
    }

    @Test
    fun tupletIDPayloadDecodes() {
        // StaffAddress(0,0) + measureIndex=3 + voiceIndex=0 + startElementIndex=5
        val bytes = byteArrayOf(
            0x00, 0x00, 0x00, 0x00,  // partIndex = 0
            0x00, 0x00, 0x00, 0x00,  // staffIndexInPart = 0
            0x03, 0x00, 0x00, 0x00,  // measureIndex = 3
            0x00, 0x00, 0x00, 0x00,  // voiceIndex = 0
            0x05, 0x00, 0x00, 0x00,  // startElementIndex = 5
        )
        val r = BinaryReader(bytes)
        val decoded = TupletIDDecoder.decodePayload(r)
        assertEquals(
            TupletID(
                staff = StaffAddress(0, 0),
                measureIndex = 3,
                voiceIndex = 0,
                startElementIndex = 5,
            ),
            decoded,
        )
    }

    // MARK: - Version mismatch

    @Test
    fun noteIdVersionMismatchThrows() {
        // Version 2 where 1 is expected
        val bytes = byteArrayOf(0x02, 0x00) + ByteArray(24)
        try {
            NoteIDDecoder.decode(bytes)
            fail("Expected VersionMismatchException")
        } catch (e: BinaryReader.VersionMismatchException) {
            assertEquals("Codec version mismatch: expected 1, found 2", e.message)
        }
    }
}
