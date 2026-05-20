package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackStateTest {
    @Test fun hasFiveCases() {
        assertEquals(5, PlaybackState.values().size)
    }
}
