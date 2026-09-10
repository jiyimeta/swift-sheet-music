package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.BarLineRole
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreArticulationKind
import io.github.jiyimeta.sheetmusic.audio.model.ScoreElementID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.SlurID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertEquals
import org.junit.Test

class ScoreElementIDDecoderTest {
    private val staff = StaffAddress(partIndex = 2, staffIndexInPart = 1)
    private val start = NoteID(
        staff = staff, measureIndex = 3, voiceIndex = 1, elementIndex = 4, noteIndexInChord = 2,
    )
    private val end = NoteID(
        staff = StaffAddress(partIndex = 3, staffIndexInPart = 2),
        measureIndex = 5, voiceIndex = 2, elementIndex = 6, noteIndexInChord = 3,
    )
    private val anchor = VoiceElementID(staff = staff, measureIndex = 3, voiceIndex = 1, elementIndex = 4)

    // Exact vectors from ScoreItemIDCodecTests.newElementBytes in
    // Tests/SheetMusicTests/AndroidJNI/Audio/ScoreItemIDCodecTests.swift.
    // Decode fixed Swift-side evidence; do not generate these inputs with the Kotlin encoder.
    @Test
    fun tieVectorDecodesBothEndpoints() {
        val bytes = byteArrayOf(
            0x24, 0x05, 0x0A, 0x21, 0x09,
            0x0A, 0x0E, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08, 0x28, 0x04,
            0x12, 0x0E, 0x0A, 0x04, 0x08, 0x06, 0x10, 0x04, 0x10, 0x0A, 0x18, 0x04, 0x20, 0x0C, 0x28, 0x06,
        )
        assertEquals(ScoreItemID.Element(ScoreElementID.Tie(start = start, end = end)), ScoreItemIDCodec.decode(bytes))
    }

    @Test
    fun chordSlurVectorDecodesAnchorAndOrdinal() {
        val bytes = byteArrayOf(
            0x17, 0x05, 0x0A, 0x14, 0x0A, 0x0A, 0x11, 0x00, 0x0A, 0x0C,
            0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08, 0x10, 0x02,
        )
        val expected = ScoreElementID.Slur(arg0 = SlurID.Chord(anchor = anchor, ordinal = 1))
        assertEquals(ScoreItemID.Element(expected), ScoreItemIDCodec.decode(bytes))
    }

    @Test
    fun standaloneSlurVectorDecodesVoiceSlot() {
        val bytes = byteArrayOf(
            0x15, 0x05, 0x0A, 0x12, 0x0A, 0x0A, 0x0F, 0x01, 0x0A, 0x0C,
            0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08,
        )
        val expected = ScoreElementID.Slur(arg0 = SlurID.Voice(arg0 = anchor))
        assertEquals(ScoreItemID.Element(expected), ScoreItemIDCodec.decode(bytes))
    }

    @Test
    fun jumpVectorDecodesOwningStaffAndListIndex() {
        val bytes = byteArrayOf(
            0x0E, 0x05, 0x0A, 0x0B, 0x0B, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x0E, 0x18, 0x04,
        )
        val expected = ScoreElementID.Jump(staff = staff, measureIndex = 7, index = 2)
        assertEquals(ScoreItemID.Element(expected), ScoreItemIDCodec.decode(bytes))
    }

    @Test
    fun markerVectorDecodesOwningStaffAndListIndex() {
        val bytes = byteArrayOf(
            0x0E, 0x05, 0x0A, 0x0B, 0x0C, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x0E, 0x18, 0x04,
        )
        val expected = ScoreElementID.Marker(staff = staff, measureIndex = 7, index = 2)
        assertEquals(ScoreItemID.Element(expected), ScoreItemIDCodec.decode(bytes))
    }

    @Test
    fun previousElementDiscriminatorsRemainCompatible() {
        // Hand-derived TLV vectors for choices 0..8. Anchor payload length is 12 (0x0C):
        // staff tag 1 + length 4 + two Int32 fields; then measure/voice/slot tags and zig-zag values.
        val anchorBytes = byteArrayOf(0x0C, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08)
        val cases: List<Pair<ScoreElementID, ByteArray>> = listOf(
            ScoreElementID.Dynamic(anchor) to (byteArrayOf(0x12, 0x05, 0x0A, 0x0F, 0x00, 0x0A) + anchorBytes),
            ScoreElementID.Fermata(anchor) to (byteArrayOf(0x12, 0x05, 0x0A, 0x0F, 0x01, 0x0A) + anchorBytes),
            ScoreElementID.Breath(anchor) to (byteArrayOf(0x12, 0x05, 0x0A, 0x0F, 0x02, 0x0A) + anchorBytes),
            ScoreElementID.Tempo(anchor) to (byteArrayOf(0x12, 0x05, 0x0A, 0x0F, 0x03, 0x0A) + anchorBytes),
            // String tag 2 + length 7 + UTF-8 "HairPin"; element payload = 15 + 9 = 24 bytes.
            ScoreElementID.Spanner(anchor, "HairPin") to (
                byteArrayOf(0x1B, 0x05, 0x0A, 0x18, 0x04, 0x0A) + anchorBytes +
                    byteArrayOf(0x12, 0x07, 0x48, 0x61, 0x69, 0x72, 0x50, 0x69, 0x6E)
            ),
            ScoreElementID.KeySignature(7) to byteArrayOf(0x06, 0x05, 0x0A, 0x03, 0x05, 0x08, 0x0E),
            ScoreElementID.TimeSignature(7) to byteArrayOf(0x06, 0x05, 0x0A, 0x03, 0x06, 0x08, 0x0E),
            ScoreElementID.BarLine(7, BarLineRole.Explicit) to
                byteArrayOf(0x09, 0x05, 0x0A, 0x06, 0x07, 0x08, 0x0E, 0x12, 0x01, 0x00),
            // Accent is choice 3; its one-byte payload follows field 2's tag and length.
            ScoreElementID.Articulation(anchor, ScoreArticulationKind.Accent) to (
                byteArrayOf(0x15, 0x05, 0x0A, 0x12, 0x08, 0x0A) + anchorBytes + byteArrayOf(0x12, 0x01, 0x03)
            ),
        )
        for ((expected, bytes) in cases) {
            assertEquals("Previous identity: $expected", ScoreItemID.Element(expected), ScoreItemIDCodec.decode(bytes))
        }
    }
}
