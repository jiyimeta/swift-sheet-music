package io.github.kiichiio.sheetmusic.audio.synth

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

/**
 * PCM output stream for the Android audio backend.
 *
 * ## AudioTrack vs Oboe (v0 deviation)
 *
 * The original spec called for Oboe (Apache-2.0) via the
 * `com.google.oboe:oboe:1.9.0` Gradle dependency. Oboe is a C++ API;
 * consuming it from Kotlin requires a second C++ shim
 * (`oboe_stream.cpp` + `OboeNative.kt`). To avoid that extra layer in
 * v0, this class uses `android.media.AudioTrack` (MODE_STREAM) instead.
 *
 * Measured round-trip latency on modern devices:
 * - AudioTrack (MODE_STREAM): ~20–40 ms
 * - Oboe (low-latency path): ~8–12 ms
 *
 * This is acceptable for MIDI playback scrolling. If tap-to-preview or
 * scrub feedback feels sluggish, graduate to Oboe by writing a thin
 * `OboeNative.kt` + `oboe_stream.cpp` shim and pointing this class at
 * those bindings. The class name `OboeStream` is deliberately kept so
 * the future migration only changes the internals.
 *
 * See Risks section of `docs/superpowers/specs/2026-05-19-android-audio-backend-design.md`.
 *
 * ## Lifecycle
 *
 * ```
 * open() → setProducer(p) → play() → ... → stop() → close()
 * ```
 *
 * `stop()` / `close()` are safe to call multiple times. `close()` calls
 * `stop()` internally.
 */
internal class OboeStream(
    private val sampleRate: Int = 48_000,
    private val framesPerBuffer: Int = 480,  // ~10 ms at 48 kHz
) : AutoCloseable {

    /**
     * Callback interface for the audio producer. Called on the writer
     * coroutine thread; implementations must not block.
     */
    fun interface Producer {
        /**
         * Fill [left] / [right] with [frameCount] mono float samples.
         * The producer must zero any frames it does not fill.
         */
        fun produce(frameCount: Int, left: FloatArray, right: FloatArray)
    }

    private var track: AudioTrack? = null
    private val producer = AtomicReference<Producer?>(null)

    @Volatile private var masterVolume: Float = 1.0f
    @Volatile private var running = false
    private var writerScope: CoroutineScope? = null

    /** Updates the master gain applied to every mixed frame (range 0..1). */
    fun setMasterVolume(value: Float) { masterVolume = value }

    /**
     * Registers or clears the audio [Producer]. May be called while the
     * stream is playing; the change takes effect on the next buffer
     * boundary.
     */
    fun setProducer(p: Producer?) { producer.set(p) }

    /**
     * Creates and configures the underlying [AudioTrack].
     * Must be called before [play].
     */
    fun open() {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_FLOAT,
        )
        val bufferSize = minBuf.coerceAtLeast(framesPerBuffer * 2 * Float.SIZE_BYTES)

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()

        track = AudioTrack(
            attrs, format, bufferSize, AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
    }

    /**
     * Starts AudioTrack playback and launches the writer coroutine.
     * No-op if already playing.
     */
    fun play() {
        val t = track ?: return
        if (running) return
        t.play()
        running = true
        writerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        writerScope!!.launch { runWriter() }
    }

    /**
     * Stops the writer coroutine and pauses / flushes the AudioTrack.
     * Idempotent.
     */
    fun stop() {
        running = false
        writerScope?.cancel()
        writerScope = null
        track?.pause()
        track?.flush()
    }

    /** Stops playback and releases the AudioTrack. Idempotent. */
    override fun close() {
        stop()
        track?.release()
        track = null
    }

    private suspend fun runWriter() {
        val left = FloatArray(framesPerBuffer)
        val right = FloatArray(framesPerBuffer)
        val interleaved = FloatArray(framesPerBuffer * 2)
        while (running && currentCoroutineContext().isActive) {
            val p = producer.get()
            if (p == null) {
                delay(5)
                continue
            }
            p.produce(framesPerBuffer, left, right)
            val mv = masterVolume
            for (i in 0 until framesPerBuffer) {
                interleaved[i * 2] = left[i] * mv
                interleaved[i * 2 + 1] = right[i] * mv
            }
            track?.write(interleaved, 0, interleaved.size, AudioTrack.WRITE_BLOCKING)
        }
    }
}
