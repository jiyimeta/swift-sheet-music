package io.github.kiichiio.sheetmusic.audio.synth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerDriverTest {

    // -----------------------------------------------------------------------
    // Fake bindings
    // -----------------------------------------------------------------------

    private class FakeBindings : PlayerDriver.NativeBindings {
        val calls = mutableListOf<String>()

        /** Simulated handle returned by newPlayer. */
        private val simulatedHandle: Long = 42L

        override fun newPlayer(synthHandle: Long): Long {
            calls += "newPlayer($synthHandle)"
            return simulatedHandle
        }

        override fun deletePlayer(handle: Long) { calls += "deletePlayer($handle)" }

        override fun playerAddMem(handle: Long, bytes: ByteArray): Int {
            calls += "playerAddMem($handle,bytes[${bytes.size}])"
            return 0
        }

        override fun playerPlay(handle: Long): Int {
            calls += "playerPlay($handle)"
            return 0
        }

        override fun playerStop(handle: Long): Int {
            calls += "playerStop($handle)"
            return 0
        }

        override fun playerJoin(handle: Long): Int {
            calls += "playerJoin($handle)"
            return 0
        }

        override fun playerSeek(handle: Long, tick: Long): Int {
            calls += "playerSeek($handle,$tick)"
            return 0
        }

        override fun playerGetCurrentTick(handle: Long): Long {
            calls += "playerGetCurrentTick($handle)"
            return 999L
        }

        override fun playerSetTempo(handle: Long, type: Int, value: Double): Int {
            calls += "playerSetTempo($handle,$type,$value)"
            return 0
        }
    }

    private val synthHandle = 1L
    private val smfBytes = ByteArray(16) { it.toByte() }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    @Test fun load_callsNewPlayerThenPlayerAddMem() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)

        driver.load(smfBytes)

        // newPlayer with the synth handle must come first.
        assertTrue("newPlayer should be called", fake.calls.any { it == "newPlayer($synthHandle)" })
        // playerAddMem with the simulated player handle and the bytes.
        assertTrue(
            "playerAddMem should be called after newPlayer",
            fake.calls.any { it.startsWith("playerAddMem(42,") },
        )
        val newIdx = fake.calls.indexOfFirst { it == "newPlayer($synthHandle)" }
        val addIdx = fake.calls.indexOfFirst { it.startsWith("playerAddMem(") }
        assertTrue("newPlayer should precede playerAddMem", newIdx < addIdx)
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

    @Test fun join_forwardsToPlayerJoin() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        val result = driver.join()

        assertEquals(0, result)
        assertTrue(fake.calls.any { it == "playerJoin(42)" })
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

    @Test fun close_callsPlayerStopThenJoinThenDeletePlayer() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)
        fake.calls.clear()

        driver.close()

        val stopIdx = fake.calls.indexOfFirst { it == "playerStop(42)" }
        val joinIdx = fake.calls.indexOfFirst { it == "playerJoin(42)" }
        val deleteIdx = fake.calls.indexOfFirst { it == "deletePlayer(42)" }

        assertTrue("playerStop should be called", stopIdx >= 0)
        assertTrue("playerJoin should be called", joinIdx >= 0)
        assertTrue("deletePlayer should be called", deleteIdx >= 0)
        assertTrue("stop before join", stopIdx < joinIdx)
        assertTrue("join before delete", joinIdx < deleteIdx)
    }

    @Test fun close_isIdempotent() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        driver.load(smfBytes)

        driver.close()
        val callsAfterFirstClose = fake.calls.size
        driver.close()

        // Second close should add no new calls.
        assertEquals(callsAfterFirstClose, fake.calls.size)
    }

    @Test fun methodsReturnMinusOne_whenNotLoaded() {
        val fake = FakeBindings()
        val driver = PlayerDriver(attachedSynthHandle = synthHandle, nativeBindings = fake)
        // Do NOT call load — handle stays 0.

        assertEquals(-1, driver.play())
        assertEquals(-1, driver.stop())
        assertEquals(-1, driver.seekTick(0L))
        assertEquals(-1, driver.join())
        assertEquals(0L, driver.currentTick)
    }

    @Test
    fun setTempoForwardsScaleToNativeBindings() {
        val setTempoCalls = mutableListOf<Triple<Long, Int, Double>>()
        val bindings = object : PlayerDriver.NativeBindings {
            override fun newPlayer(synthHandle: Long): Long = 7L
            override fun deletePlayer(handle: Long) {}
            override fun playerAddMem(handle: Long, bytes: ByteArray): Int = 0
            override fun playerPlay(handle: Long): Int = 0
            override fun playerStop(handle: Long): Int = 0
            override fun playerJoin(handle: Long): Int = 0
            override fun playerSeek(handle: Long, tick: Long): Int = 0
            override fun playerGetCurrentTick(handle: Long): Long = 0
            override fun playerSetTempo(handle: Long, type: Int, value: Double): Int {
                setTempoCalls += Triple(handle, type, value)
                return 0
            }
        }
        val driver = PlayerDriver(attachedSynthHandle = 0L, nativeBindings = bindings)
        driver.load(byteArrayOf())
        val rc = driver.setTempo(1.5)
        assertEquals(0, rc)
        assertEquals(1, setTempoCalls.size)
        val (handle, type, value) = setTempoCalls.first()
        assertEquals(7L, handle)
        assertEquals(0, type)            // FLUID_PLAYER_TEMPO_INTERNAL
        assertEquals(1.5, value, 0.0001)
    }
}
