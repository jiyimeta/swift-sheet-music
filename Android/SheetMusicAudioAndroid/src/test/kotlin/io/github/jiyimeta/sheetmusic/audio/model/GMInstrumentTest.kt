package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * JVM unit tests can't load `libSheetMusicJNI.so`, so we pre-populate
 * [GMInstrument]'s cache with a known list via the `__setForTests`
 * seam and exercise the public API against that. Content correctness
 * (all 128 patch names) is verified by `GMInstrumentCodecTests` on
 * the Swift host side.
 */
class GMInstrumentTest {
    private val piano = GMInstrument(program = 0, displayName = "Acoustic Grand Piano", familyIndex = 0)
    private val violin = GMInstrument(program = 40, displayName = "Violin", familyIndex = 5)

    @After
    fun teardown() {
        GMInstrument.__setForTests(null)
    }

    @Test
    fun entriesReturnsInjectedList() {
        GMInstrument.__setForTests(listOf(piano, violin))
        assertEquals(listOf(piano, violin), GMInstrument.entries)
    }

    @Test
    fun forProgramReturnsMatchingEntry() {
        GMInstrument.__setForTests(listOf(piano, violin))
        assertEquals(violin, GMInstrument.forProgram(40))
    }

    @Test
    fun forProgramReturnsNullWhenNoMatch() {
        GMInstrument.__setForTests(listOf(piano, violin))
        assertNull(GMInstrument.forProgram(1))
        assertNull(GMInstrument.forProgram(-1))
        assertNull(GMInstrument.forProgram(128))
    }

    @Test
    fun dataClassEqualityByValue() {
        assertEquals(
            GMInstrument(program = 40, displayName = "Violin", familyIndex = 5),
            violin,
        )
    }
}
