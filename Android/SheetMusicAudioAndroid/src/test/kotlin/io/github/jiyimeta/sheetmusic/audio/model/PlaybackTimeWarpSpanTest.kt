package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackTimeWarpSpanTest {
    @Test fun `spans encode as big-endian doubles, three a span, as the Swift validator reads them`() {
        // The same bytes `RecordingBridgeTests` decodes on the Swift side.
        val expected = byteArrayOf(
            0x3F, 0xF0.toByte(), 0, 0, 0, 0, 0, 0,
            0x40, 0x00, 0, 0, 0, 0, 0, 0,
            0x3F, 0xE0.toByte(), 0, 0, 0, 0, 0, 0,
        )
        assertArrayEquals(expected, PlaybackTimeWarpSpan.encode(listOf(PlaybackTimeWarpSpan(1.0, 2.0, 0.5))))
        assertEquals(48, PlaybackTimeWarpSpan.encode(List(2) { PlaybackTimeWarpSpan(0.0, 1.0, 1.0) }).size)
        assertEquals(0, PlaybackTimeWarpSpan.encode(emptyList()).size)
    }
}
