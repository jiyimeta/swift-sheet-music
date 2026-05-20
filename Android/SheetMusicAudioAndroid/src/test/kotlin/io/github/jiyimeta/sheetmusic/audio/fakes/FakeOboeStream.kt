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
    override fun open() { /* skip AudioTrack construction */ }
    override fun play() { /* no-op */ }
    override fun stop() { /* no-op */ }
    override fun close() { /* no-op */ }
}
