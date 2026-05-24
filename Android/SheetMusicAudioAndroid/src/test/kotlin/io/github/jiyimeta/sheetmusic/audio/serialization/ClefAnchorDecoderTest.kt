package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.wireformat.BinaryReader

import io.github.jiyimeta.sheetmusic.audio.model.ClefAnchor
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class ClefAnchorDecoderTest {

    // MARK: - Explicit branch (kind = 0)

    @Test
    fun explicitBranchDecodes() {
        // kind=0 + VoiceElementID(StaffAddress(1,2), measure=3, voice=0, elem=4)
        val bytes = byteArrayOf(
            0x00,  // kind = 0 (Explicit)
            0x01, 0x00, 0x00, 0x00,  // partIndex = 1
            0x02, 0x00, 0x00, 0x00,  // staffIndexInPart = 2
            0x03, 0x00, 0x00, 0x00,  // measureIndex = 3
            0x00, 0x00, 0x00, 0x00,  // voiceIndex = 0
            0x04, 0x00, 0x00, 0x00,  // elementIndex = 4
        )
        val r = BinaryReader(bytes)
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(
            ClefAnchor.Explicit(
                VoiceElementID(
                    staff = StaffAddress(partIndex = 1, staffIndexInPart = 2),
                    measureIndex = 3,
                    voiceIndex = 0,
                    elementIndex = 4,
                ),
            ),
            decoded,
        )
    }

    // MARK: - StaffDefault branch (kind = 1)

    @Test
    fun staffDefaultBranchDecodes() {
        // kind=1 + StaffAddress(0,0)
        val bytes = byteArrayOf(
            0x01,  // kind = 1 (StaffDefault)
            0x00, 0x00, 0x00, 0x00,  // partIndex = 0
            0x00, 0x00, 0x00, 0x00,  // staffIndexInPart = 0
        )
        val r = BinaryReader(bytes)
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(
            ClefAnchor.StaffDefault(StaffAddress(partIndex = 0, staffIndexInPart = 0)),
            decoded,
        )
    }

    @Test
    fun staffDefaultWithNonZeroAddress() {
        // kind=1 + StaffAddress(2,1)
        val bytes = byteArrayOf(
            0x01,  // kind = 1 (StaffDefault)
            0x02, 0x00, 0x00, 0x00,  // partIndex = 2
            0x01, 0x00, 0x00, 0x00,  // staffIndexInPart = 1
        )
        val r = BinaryReader(bytes)
        val decoded = ClefAnchorCodec.decodePayload(r)
        assertEquals(
            ClefAnchor.StaffDefault(StaffAddress(partIndex = 2, staffIndexInPart = 1)),
            decoded,
        )
    }

    // MARK: - Unknown kind

    @Test
    fun unknownKindThrows() {
        val bytes = byteArrayOf(0x02)  // kind = 2 (unknown)
        val r = BinaryReader(bytes)
        try {
            ClefAnchorCodec.decodePayload(r)
            fail("Expected error for unknown kind")
        } catch (_: IllegalArgumentException) {
            // expected — generated codec throws IllegalArgumentException
        }
    }
}
