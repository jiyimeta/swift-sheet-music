package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Round-trip tests for AudioExportRangeCodec.
 *
 * The wire format is wirelet TLV: encode() produces a length-prefixed blob.
 * decode(encode(x)) == x for all cases.
 */
class AudioExportRangeEncoderTest {
    @Test fun encodesFullRoundTrip() {
        val encoded = AudioExportRangeCodec.encode(AudioExportRange.Full)
        val decoded = AudioExportRangeCodec.decode(encoded)
        assertEquals(AudioExportRange.Full, decoded)
    }

    @Test fun encodesCurrentLoopRoundTrip() {
        val encoded = AudioExportRangeCodec.encode(AudioExportRange.CurrentLoop)
        val decoded = AudioExportRangeCodec.decode(encoded)
        assertEquals(AudioExportRange.CurrentLoop, decoded)
    }

    @Test fun encodesRegionWithCursorPairRoundTrip() {
        val from = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val to = ScoreCursor.Beat(measureIndex = 1, tickInMeasure = 240)
        val value = AudioExportRange.Region(from, to)
        val encoded = AudioExportRangeCodec.encode(value)
        val decoded = AudioExportRangeCodec.decode(encoded)
        assertEquals(value, decoded)
    }

    @Test fun encodesRegionThroughEndRoundTrip() {
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
        val value = AudioExportRange.RegionThroughEnd(from, last)
        val encoded = AudioExportRangeCodec.encode(value)
        val decoded = AudioExportRangeCodec.decode(encoded)
        assertEquals(value, decoded)
    }
}
