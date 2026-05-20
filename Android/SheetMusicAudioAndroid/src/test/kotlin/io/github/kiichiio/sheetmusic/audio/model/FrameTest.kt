package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class FrameTest {
    private val cursor = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)

    @Test fun equality() {
        val a = Frame(tick = 0L, timeSeconds = 0.0, cursor = cursor)
        val b = Frame(tick = 0L, timeSeconds = 0.0, cursor = cursor)
        assertEquals(a, b)
    }

    @Test fun fieldsRoundtrip() {
        val frame = Frame(tick = 960L, timeSeconds = 1.5, cursor = cursor)
        assertEquals(960L, frame.tick)
        assertEquals(1.5, frame.timeSeconds, 1e-9)
        assertEquals(cursor, frame.cursor)
    }
}
