package io.github.jiyimeta.sheetmusic.audio.synth

import kotlin.math.abs
import kotlin.math.log2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MasterTuningTest {
    @Test fun splitZero() {
        val (c, f) = MasterTuning.split(0.0)
        assertEquals(0, c)
        assertTrue(abs(f) < 1e-9)
    }

    @Test fun split432() {
        val cents = 1200 * log2(432.0 / 440.0)
        val (c, f) = MasterTuning.split(cents)
        assertEquals(0, c)
        assertTrue(abs(f - cents) < 1e-6)
    }

    @Test fun split415DownOneSemitone() {
        val cents = 1200 * log2(415.0 / 440.0)
        val (c, _) = MasterTuning.split(cents)
        assertEquals(-1, c)
    }

    @Test fun rpnZeroCentered() {
        assertEquals(
            listOf(
                MasterTuning.CC(101, 0), MasterTuning.CC(100, 2), MasterTuning.CC(6, 64), MasterTuning.CC(38, 0),
                MasterTuning.CC(101, 0), MasterTuning.CC(100, 1), MasterTuning.CC(6, 64), MasterTuning.CC(38, 0),
                MasterTuning.CC(101, 127), MasterTuning.CC(100, 127),
            ),
            MasterTuning.rpnControlChanges(0.0),
        )
    }

    @Test fun rpn432FineFlat() {
        val m = MasterTuning.rpnControlChanges(1200 * log2(432.0 / 440.0))
        assertEquals(MasterTuning.CC(6, 64), m[2])          // coarse centered
        assertTrue(m[6].controller == 6 && m[6].value < 64) // fine flat
    }

    @Test fun rpn415CoarseDown() {
        val m = MasterTuning.rpnControlChanges(1200 * log2(415.0 / 440.0))
        assertEquals(MasterTuning.CC(6, 63), m[2])
    }
}
