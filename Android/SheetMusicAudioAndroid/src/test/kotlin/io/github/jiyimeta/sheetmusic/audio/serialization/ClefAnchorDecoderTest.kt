package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.wirelet.WireFormatException

import io.github.jiyimeta.sheetmusic.audio.model.ClefAnchor
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class ClefAnchorDecoderTest {

    // MARK: - Explicit branch

    @Test
    fun explicitBranchDecodes() {
        // ClefAnchor.Explicit(VoiceElementID(StaffAddress(1,2), measure=3, voice=0, elem=4))
        val value = ClefAnchor.Explicit(
            VoiceElementID(
                staff = StaffAddress(partIndex = 1, staffIndexInPart = 2),
                measureIndex = 3,
                voiceIndex = 0,
                elementIndex = 4,
            ),
        )
        val w = BinaryWriter()
        ClefAnchorCodec.encodePayload(value, w)
        val r = BinaryReader(w.toByteArray())
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

    // MARK: - StaffDefault branch

    @Test
    fun staffDefaultBranchDecodes() {
        // ClefAnchor.StaffDefault(StaffAddress(0,0))
        val value = ClefAnchor.StaffDefault(StaffAddress(partIndex = 0, staffIndexInPart = 0))
        val w = BinaryWriter()
        ClefAnchorCodec.encodePayload(value, w)
        val r = BinaryReader(w.toByteArray())
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

    @Test
    fun staffDefaultWithNonZeroAddress() {
        // ClefAnchor.StaffDefault(StaffAddress(2,1))
        val value = ClefAnchor.StaffDefault(StaffAddress(partIndex = 2, staffIndexInPart = 1))
        val w = BinaryWriter()
        ClefAnchorCodec.encodePayload(value, w)
        val r = BinaryReader(w.toByteArray())
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

    // MARK: - Restatement branch

    @Test
    fun restatementBranchDecodes() {
        // ClefAnchor.Restatement(StaffAddress(1,0), measureIndex=12)
        val value = ClefAnchor.Restatement(StaffAddress(partIndex = 1, staffIndexInPart = 0), measureIndex = 12)
        val w = BinaryWriter()
        ClefAnchorCodec.encodePayload(value, w)
        val r = BinaryReader(w.toByteArray())
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(value, decoded)
    }

    // MARK: - Unknown discriminator

    @Test
    fun unknownKindThrows() {
        // Discriminators 0…2 are explicit / staffDefault / restatement; hand-craft 3 (unknown).
        // In TLV format the choice discriminator is a varint. Build a payload with disc=3.
        val w = BinaryWriter()
        w.writeVarint(3L) // discriminator = 3 (unknown)
        val r = BinaryReader(w.toByteArray())
        try {
            ClefAnchorCodec.decodePayload(r)
            fail("Expected error for unknown discriminator")
        } catch (_: WireFormatException.UnknownChoiceDiscriminator) {
            // expected — TLV codecs throw UnknownChoiceDiscriminator for out-of-range discriminators
        }
    }
}
