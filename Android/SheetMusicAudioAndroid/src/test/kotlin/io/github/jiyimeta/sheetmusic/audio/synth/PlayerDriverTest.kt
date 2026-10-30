package io.github.jiyimeta.sheetmusic.audio.synth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerDriverTest {

    // -----------------------------------------------------------------------
    // Fake bindings
    // -----------------------------------------------------------------------

    private class FakeBindings(private val handleToReturn: Long = 42L) : PlayerDriver.NativeBindings {
        val calls = mutableListOf<String>()

        override fun newPlayer(synthHandle: Long, bytes: ByteArray): Long {
            calls += "newPlayer($synthHandle,bytes[${bytes.size}])"
            return handleToReturn
        }

        override fun deletePlayer(handle: Long) { calls += "deletePlayer($handle)" }

        override fun playerPlay(handle: Long) { calls += "playerPlay($handle)" }

        override fun playerStop(handle: Long) { calls += "playerStop($handle)" }

        override fun playerSeek(handle: Long, tick: Long) { calls += "playerSeek($handle,$tick)" }

        override fun playerGetCurrentTick(handle: Long): Long {
            calls += "playerGetCurrentTick($handle)"
            return 999L
        }

        override fun playerSetTempo(handle: Long, scale: Double) { calls += "playerSetTempo($handle,$scale)" }
    }

    private val synthHandle = 1L
    private val smfBytes = ByteArray(16) { it.toByte() }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    @Test fun load_attachesTheBytesToTheSynth() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)

        assertEquals(0, driver.load(smfBytes))

        assertEquals(listOf("newPlayer($synthHandle,bytes[16])"), fake.calls)
    }

    @Test fun load_answersMinusOneWhenTheBytesAreNotAnSmf() {
        val fake = FakeBindings(handleToReturn = 0L)
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)

        assertEquals(-1, driver.load(smfBytes))
        assertEquals(-1, driver.play())
    }

    @Test fun load_releasesTheSequenceItReplaces() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        driver.load(smfBytes)

        assertEquals(listOf("deletePlayer(42)", "newPlayer($synthHandle,bytes[16])"), fake.calls)
    }

    @Test fun play_forwardsToPlayerPlay() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        val result = driver.play()

        assertEquals(0, result)
        assertTrue(fake.calls.any { it == "playerPlay(42)" })
    }

    @Test fun stop_forwardsToPlayerStop() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        val result = driver.stop()

        assertEquals(0, result)
        assertTrue(fake.calls.any { it == "playerStop(42)" })
    }

    @Test fun seekTick_forwardsToPlayerSeek() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        val result = driver.seekTick(480L)

        assertEquals(0, result)
        assertTrue(fake.calls.any { it == "playerSeek(42,480)" })
    }

    @Test fun currentTick_forwardsToPlayerGetCurrentTick() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        val tick = driver.currentTick

        assertEquals(999L, tick)
        assertTrue(fake.calls.any { it == "playerGetCurrentTick(42)" })
    }

    @Test fun close_callsPlayerStopThenDeletePlayer() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        driver.close()

        assertEquals(listOf("playerStop(42)", "deletePlayer(42)"), fake.calls)
    }

    @Test fun close_isIdempotent_andLeavesTheDriverInert() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)

        driver.close()
        val callsAfterFirstClose = fake.calls.size
        driver.close()
        // A released handle must never reach native code again.
        assertEquals(-1, driver.play())
        assertEquals(-1, driver.seekTick(0L))
        assertEquals(0L, driver.currentTick)
        assertEquals(-1, driver.load(smfBytes))

        assertEquals(callsAfterFirstClose, fake.calls.size)
    }

    @Test fun methodsReturnMinusOne_whenNotLoaded() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        // Do NOT call load — handle stays 0.

        assertEquals(-1, driver.play())
        assertEquals(-1, driver.stop())
        assertEquals(-1, driver.seekTick(0L))
        assertEquals(-1, driver.setTempo(1.0))
        assertEquals(0L, driver.currentTick)
        assertTrue(fake.calls.isEmpty())
    }

    @Test
    fun setTempoForwardsScaleToNativeBindings() {
        val fake = FakeBindings(handleToReturn = 7L)
        val driver = PlayerDriver(attachedSynthHandle = 0L, nativeBindings = fake)
        driver.load(byteArrayOf())
        fake.calls.clear()

        val rc = driver.setTempo(1.5)

        assertEquals(0, rc)
        assertEquals(listOf("playerSetTempo(7,1.5)"), fake.calls)
    }
}
