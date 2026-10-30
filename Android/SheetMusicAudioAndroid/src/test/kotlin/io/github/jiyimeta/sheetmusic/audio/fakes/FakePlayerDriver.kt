package io.github.jiyimeta.sheetmusic.audio.fakes

import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver

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
        val seekTicks = mutableListOf<Long>()
        var closeCalled = false
        var tickToReturn: Long = 0L

        override fun newPlayer(synthHandle: Long, bytes: ByteArray): Long {
            loadCalls += bytes
            return 1L
        }
        override fun deletePlayer(handle: Long) { closeCalled = true }
        override fun playerPlay(handle: Long) { playCalls += Unit }
        override fun playerStop(handle: Long) { stopCalls += Unit }
        override fun playerSeek(handle: Long, tick: Long) {
            seekTicks += tick; tickToReturn = tick
        }
        override fun playerGetCurrentTick(handle: Long): Long = tickToReturn
        val setTempoCalls = mutableListOf<Double>()
        override fun playerSetTempo(handle: Long, scale: Double) {
            setTempoCalls += scale
        }
    }

    internal fun create(): Pair<PlayerDriver, RecordingBindings> {
        val bindings = RecordingBindings()
        val driver = PlayerDriver(attachedSynthHandle = 0L, nativeBindings = bindings)
        return driver to bindings
    }
}
