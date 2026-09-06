package io.github.jiyimeta.sheetmusic.audio.synth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors `Tests/SheetMusicTests/SoftClipTests.swift` case for case.
 *
 * The Kotlin curve is a port, not a shared implementation, so nothing but a test keeps the two from
 * drifting. These assert the properties that DEFINE the curve rather than sampled outputs, because
 * a table of expected floats would be satisfied by a curve that is right at ten points and wrong
 * everywhere between them.
 */
class SoftClipTest {

    private val knee = SoftClip.DEFAULT_KNEE

    @Test
    fun `passes signals below the knee through untouched`() {
        for (input in listOf(0f, 0.1f, 0.25f, 0.5f, 0.7f)) {
            assertEquals(input, SoftClip.apply(input, knee), 0f)
        }
    }

    @Test
    fun `preserves sign`() {
        assertEquals(-0.5f, SoftClip.apply(-0.5f, knee), 0f)
        assertTrue(SoftClip.apply(-2f, knee) < 0f)
        assertEquals(-SoftClip.apply(2f, knee), SoftClip.apply(-2f, knee), 0f)
    }

    @Test
    fun `never turns a louder sample into a quieter one`() {
        // The property that separates this from a peak limiter: strictly monotonic, so the master
        // gain control never runs backwards.
        var previous = SoftClip.apply(knee, knee)
        for (input in listOf(0.8f, 1f, 1.2f, 1.5f, 2f, 3f, 4f, 8f, 16f, 64f)) {
            val output = SoftClip.apply(input, knee)
            assertTrue("$input produced $output < $previous", output >= previous)
            previous = output
        }
    }

    @Test
    fun `never exceeds full scale however hard it is driven`() {
        assertTrue(SoftClip.apply(1000f, knee) <= 1f)
        assertTrue(SoftClip.apply(1000f, knee) > 0.99f)
    }

    @Test
    fun `joins the linear region smoothly`() {
        // Slope 1 at the knee: the curve leaves the linear region without a kink, which is what
        // keeps the transition from being audible as the mix crosses it.
        val epsilon = 1e-4f
        val below = SoftClip.apply(knee - epsilon, knee)
        val above = SoftClip.apply(knee + epsilon, knee)
        val slope = (above - below) / (2 * epsilon)
        assertEquals(1f, slope, 0.01f)
    }

    @Test
    fun `a knee at full scale degenerates to a hard clip`() {
        // Rather than dividing by a zero headroom.
        assertEquals(1f, SoftClip.apply(2f, 1f), 0f)
        assertEquals(-1f, SoftClip.apply(-2f, 1f), 0f)
    }

    @Test
    fun `the default knee is minus three dBFS`() {
        // Pinned because it is half of the contract with the Swift side; the shaping above is the
        // other half, and a curve with the same shape at a different knee is a different curve.
        assertEquals(0.7071068f, SoftClip.DEFAULT_KNEE, 1e-7f)
    }
}
