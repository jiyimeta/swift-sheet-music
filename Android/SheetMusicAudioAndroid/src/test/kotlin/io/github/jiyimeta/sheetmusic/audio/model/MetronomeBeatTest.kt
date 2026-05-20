package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MetronomeBeatTest {
    @Test fun downbeatEquality() {
        val a = MetronomeBeat(tick = 0L, isDownbeat = true)
        val b = MetronomeBeat(tick = 0L, isDownbeat = true)
        assertEquals(a, b)
        assertTrue(a.isDownbeat)
    }

    @Test fun upbeatEquality() {
        val a = MetronomeBeat(tick = 480L, isDownbeat = false)
        val b = MetronomeBeat(tick = 480L, isDownbeat = false)
        assertEquals(a, b)
        assertFalse(a.isDownbeat)
    }
}
