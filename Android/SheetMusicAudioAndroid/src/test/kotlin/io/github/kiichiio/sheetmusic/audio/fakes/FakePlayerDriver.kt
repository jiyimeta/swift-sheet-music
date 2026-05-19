package io.github.kiichiio.sheetmusic.audio.fakes

import io.github.kiichiio.sheetmusic.audio.synth.PlayerDriver

/**
 * Builds a [PlayerDriver] backed by a [RecordingBindings] instance.
 *
 * Usage:
 * ```
 * val (player, bindings) = FakePlayerDriver.create()
 * ```
 * All calls are recorded in [bindings] without touching native code.
 */
internal object FakePlayerDriver {
    internal class RecordingBindings : PlayerDriver.NativeBindings {
        val loadCalls = mutableListOf<ByteArray>()
        val playCalls = mutableListOf<Unit>()
        val stopCalls = mutableListOf<Unit>()
        val joinCalls = mutableListOf<Unit>()
        val seekTicks = mutableListOf<Long>()
        var closeCalled = false
        var tickToReturn: Long = 0L

        override fun newPlayer(synthHandle: Long): Long = 1L
        override fun deletePlayer(handle: Long) { closeCalled = true }
        override fun playerAddMem(handle: Long, bytes: ByteArray): Int {
            loadCalls += bytes; return 0
        }
        override fun playerPlay(handle: Long): Int { playCalls += Unit; return 0 }
        override fun playerStop(handle: Long): Int { stopCalls += Unit; return 0 }
        override fun playerJoin(handle: Long): Int { joinCalls += Unit; return 0 }
        override fun playerSeek(handle: Long, tick: Long): Int {
            seekTicks += tick; tickToReturn = tick; return 0
        }
        override fun playerGetCurrentTick(handle: Long): Long = tickToReturn
    }

    internal fun create(): Pair<PlayerDriver, RecordingBindings> {
        val bindings = RecordingBindings()
        val driver = PlayerDriver(attachedSynthHandle = 0L, nativeBindings = bindings)
        return driver to bindings
    }
}
