package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioExportRangeEncoderTest {
    @Test fun encodesFullAsHeaderPlusTagZero() {
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.Full)
        // Header: u16=1 (LE) + u8 tag=0 -> 3 bytes total
        assertArrayEquals(byteArrayOf(0x01, 0x00, 0x00), bytes)
    }

    @Test fun encodesCurrentLoopAsHeaderPlusTagOne() {
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.CurrentLoop)
        assertArrayEquals(byteArrayOf(0x01, 0x00, 0x01), bytes)
    }

    @Test fun encodesRegionWithCursorPair() {
        val from = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val to = ScoreCursor.Beat(measureIndex = 1, tickInMeasure = 240)
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.Region(from, to))

        // Header: u16 ver=1 (LE) + tag=2.
        assertEquals(0x01.toByte(), bytes[0])
        assertEquals(0x00.toByte(), bytes[1])
        assertEquals(0x02.toByte(), bytes[2])

        // Per ScoreCursorCodec.encodePayload: tag(1) + i32 measureIndex(4) + i32 tickInMeasure(4) = 9 bytes
        // per Beat cursor. So total = 3 header + 9 + 9 = 21.
        assertEquals(3 + 9 + 9, bytes.size)

        // Verify second cursor payload exact bytes (LE):
        // bytes[3..11]: from = tag=1, mi=0, tick=0
        // bytes[12..20]: to   = tag=1, mi=1, tick=240 (0xF0 0x00 0x00 0x00)
        val expectedFromPayload = byteArrayOf(
            0x01, // ScoreCursor.Beat tag
            0x00, 0x00, 0x00, 0x00, // measureIndex = 0
            0x00, 0x00, 0x00, 0x00, // tickInMeasure = 0
        )
        val expectedToPayload = byteArrayOf(
            0x01, // ScoreCursor.Beat tag
            0x01, 0x00, 0x00, 0x00, // measureIndex = 1
            0xF0.toByte(), 0x00, 0x00, 0x00, // tickInMeasure = 240
        )
        assertArrayEquals(expectedFromPayload, bytes.copyOfRange(3, 12))
        assertArrayEquals(expectedToPayload, bytes.copyOfRange(12, 21))
    }

    @Test fun encodesRegionThroughEndWithCursorAndItemID() {
        val from = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val last = ScoreItemID.Note(
            NoteID(
                staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
                measureIndex = 1,
                voiceIndex = 0,
                elementIndex = 3,
                noteIndexInChord = 0,
            ),
        )
        val bytes = AudioExportRangeEncoder.encode(AudioExportRange.RegionThroughEnd(from, last))

        // Header byte: tag=3
        assertEquals(0x03.toByte(), bytes[2])

        // Size breakdown:
        //   3   header (u16 version + u8 tag)
        //   9   ScoreCursor.Beat payload (tag + 2*i32)
        //   1   ScoreItemID tag (Note=0)
        //  24   NoteID payload: StaffAddress(2*i32=8) + 4*i32(16) = 24
        // ---
        //  37
        assertEquals(3 + 9 + 1 + 24, bytes.size)

        // Verify the ScoreItemID.Note tag immediately after the cursor payload.
        // Header(3) + Beat cursor payload(9) = offset 12.
        assertEquals(0x00.toByte(), bytes[12]) // ScoreItemID.Note tag

        // Verify the NoteID body bytes (all i32 LE):
        // partIndex=0, staffIndexInPart=0, measureIndex=1, voiceIndex=0,
        // elementIndex=3, noteIndexInChord=0
        val expectedNoteIDBody = byteArrayOf(
            0x00, 0x00, 0x00, 0x00, // partIndex = 0
            0x00, 0x00, 0x00, 0x00, // staffIndexInPart = 0
            0x01, 0x00, 0x00, 0x00, // measureIndex = 1
            0x00, 0x00, 0x00, 0x00, // voiceIndex = 0
            0x03, 0x00, 0x00, 0x00, // elementIndex = 3
            0x00, 0x00, 0x00, 0x00, // noteIndexInChord = 0
        )
        assertArrayEquals(expectedNoteIDBody, bytes.copyOfRange(13, 37))
    }
}
