package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter

import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.TupletID
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertEquals
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
        val decoded = StaffAddressCodec.decode(bytes)
        assertEquals(canonicalStaffAddress, decoded)
    }

    @Test
    fun staffAddressGoldenPayloadLength() {
        val bytes = loadGolden("staffAddress-v1.bin")
        // TLV format: varint(4) + tag(1,varint) zigzag(partIndex=1) + tag(2,varint) zigzag(staffIndexInPart=0) = 5 bytes
        assertEquals(5, bytes.size)
    }

    // MARK: - NoteID golden tests

    @Test
    fun noteIdGoldenDecodes() {
        val bytes = loadGolden("noteId-v1.bin")
        val decoded = NoteIDCodec.decode(bytes)
        assertEquals(canonicalNoteID, decoded)
    }

    @Test
    fun noteIdGoldenPayloadLength() {
        val bytes = loadGolden("noteId-v1.bin")
        // TLV format: varint(len) + nested StaffAddress(5) + 4 zigzag varint fields = 15 bytes
        assertEquals(15, bytes.size)
    }

    // MARK: - Payload-only decoder tests (TLV-encoded inline byte arrays)

    @Test
    fun staffAddressPayloadDecodes() {
        // Build TLV payload for StaffAddress(partIndex=3, staffIndexInPart=1) using codec
        val w = BinaryWriter()
        StaffAddressCodec.encodePayload(StaffAddress(partIndex = 3, staffIndexInPart = 1), w)
        val bytes = w.toByteArray()
        val r = BinaryReader(bytes)
        val decoded = StaffAddressCodec.decodePayload(r)
        assertEquals(StaffAddress(partIndex = 3, staffIndexInPart = 1), decoded)
    }

    @Test
    fun voiceElementIDPayloadDecodes() {
        // Build TLV payload for VoiceElementID(StaffAddress(2,0), measureIndex=5, voiceIndex=1, elementIndex=3)
        val value = VoiceElementID(
            staff = StaffAddress(2, 0),
            measureIndex = 5,
            voiceIndex = 1,
            elementIndex = 3,
        )
        val w = BinaryWriter()
        VoiceElementIDCodec.encodePayload(value, w)
        val bytes = w.toByteArray()
        val r = BinaryReader(bytes)
        val decoded = VoiceElementIDCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

    @Test
    fun restIDPayloadDecodes() {
        // Build TLV payload for RestID(StaffAddress(0,0), measureIndex=2, voiceIndex=1, elementIndex=0)
        val value = RestID(
            staff = StaffAddress(0, 0),
            measureIndex = 2,
            voiceIndex = 1,
            elementIndex = 0,
        )
        val w = BinaryWriter()
        RestIDCodec.encodePayload(value, w)
        val bytes = w.toByteArray()
        val r = BinaryReader(bytes)
        val decoded = RestIDCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

    @Test
    fun tupletIDPayloadDecodes() {
        // Build TLV payload for TupletID(StaffAddress(0,0), measureIndex=3, voiceIndex=0, startElementIndex=5)
        val value = TupletID(
            staff = StaffAddress(0, 0),
            measureIndex = 3,
            voiceIndex = 0,
            startElementIndex = 5,
        )
        val w = BinaryWriter()
        TupletIDCodec.encodePayload(value, w)
        val bytes = w.toByteArray()
        val r = BinaryReader(bytes)
        val decoded = TupletIDCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

}
