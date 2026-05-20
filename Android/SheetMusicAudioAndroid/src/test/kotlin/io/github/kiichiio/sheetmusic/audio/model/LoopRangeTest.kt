package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class LoopRangeTest {
    @Test
    fun storesStartAndEndTicks() {
        val r = LoopRange(startTick = 100L, endTick = 200L)
        assertEquals(100L, r.startTick)
        assertEquals(200L, r.endTick)
    }

    @Test
    fun equalityByValue() {
        assertEquals(LoopRange(0L, 480L), LoopRange(0L, 480L))
    }
}
