package io.github.jiyimeta.sheetmusic.audio.fakes

import io.github.jiyimeta.sheetmusic.audio.synth.OboeStream

/**
 * No-op [OboeStream] subclass for JVM unit tests.
 *
 * [OboeStream] uses [android.media.AudioTrack] internally; with the
 * `unitTests.isReturnDefaultValues = true` flag, SDK stubs return
 * defaults but still may throw if AudioTrack is constructed with
 * zero buffer size. Overriding [open] / [play] / [stop] / [close]
 * sidesteps this completely.
 *
 * Usage: pass [FakeOboeStream::create] as `oboeFactory` in test engine
 * construction helpers.
 */
internal object FakeOboeStream {
    internal fun create(): OboeStream = NoOpOboeStream()
}

internal class NoOpOboeStream : OboeStream() {
    /** Stream transitions in order, for tests that care about when the stream runs rather than that it does. */
    val calls: MutableList<String> = mutableListOf()

    override fun open() { calls += "open" } // and skip AudioTrack construction
    override fun play() { calls += "play" }
    override fun stop() { calls += "stop" }
    override fun close() { calls += "close" }

    /**
     * The audio clock a test can drive.
     *
     * `null` by default — the real stream returns null until the device has presented audio, and a
     * fake that always produced a reading would hide the null path from every caller. Tests that
     * want a clock install [clockSamples], which is consumed one entry per call so a test can make
     * the value ADVANCE between reads; running past the end returns the last entry.
     */
    var clockSamples: MutableList<ClockSample> = mutableListOf()

    override fun audioTimestamp(): ClockSample? {
        if (clockSamples.isEmpty()) return null
        return if (clockSamples.size == 1) clockSamples[0] else clockSamples.removeAt(0)
    }
}
