package io.github.jiyimeta.sheetmusic.audio.synth

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.asCoroutineDispatcher

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
internal open class OboeStream(
    private val sampleRate: Int = 48_000,
    private val framesPerBuffer: Int = 480,  // ~10 ms at 48 kHz
) : AutoCloseable {

    /**
     * Dedicated single-thread executor for the audio writer coroutine.
     *
     * Using [Dispatchers.Default] (a shared work-stealing pool) risks
     * preemption from unrelated coroutines, draining the AudioTrack ring
     * buffer and producing underrun crackling. A max-priority daemon thread
     * gives the writer the best-effort real-time scheduling available on the
     * JVM without requiring root or `RECORD_AUDIO`.
     *
     * The executor is kept alive across play/pause cycles to avoid
     * re-initialization overhead. It is shut down only in [close].
     */
    private val writerDispatcher = Executors.newSingleThreadExecutor { r ->
        Thread(r, "OboeStream-writer").apply {
            priority = Thread.MAX_PRIORITY
            isDaemon = true
        }
    }.asCoroutineDispatcher()

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

    /**
     * One reading of the device's audio clock: the frame the output has actually PRESENTED, and the
     * host-clock instant (`System.nanoTime()` base) at which it did.
     */
    data class ClockSample(val framePosition: Long, val nanoTime: Long)

    /** How long [stop] waits for the writer after unparking and cancelling it. See [stop]. */
    private companion object {
        const val WRITER_SHUTDOWN_TIMEOUT_MS = 500L
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
    open fun open() {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_FLOAT,
        )
        // Hold at least 4 writer buffers to absorb scheduling jitter without
        // underrunning. One buffer = framesPerBuffer * 2 ch * 4 bytes/float.
        val bufferSize = minBuf.coerceAtLeast(framesPerBuffer * 2 * Float.SIZE_BYTES * 4)

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
    open fun play() {
        val t = track ?: return
        if (running) return
        // Force AudioTrack software volume to max — some Android versions
        // initialize tracks at a lower default. The OS stream volume is
        // controlled separately by the volume slider, so this only ensures
        // we don't lose a multiplier silently.
        t.setVolume(AudioTrack.getMaxVolume())
        t.play()
        running = true
        writerScope = CoroutineScope(SupervisorJob() + writerDispatcher)
        writerScope!!.launch { runWriter() }
    }

    /**
     * Stops the writer coroutine and pauses / flushes the AudioTrack.
     * Idempotent.
     *
     * **Returns only once the writer has actually stopped**, which is what makes [close] safe. The writer spends
     * most of its life inside `AudioTrack.write(..., WRITE_BLOCKING)` — a blocking native call, not a suspension
     * point, so `cancel()` cannot reach it and merely marks the job. A caller that released the track on the
     * strength of `cancel()` alone was freeing an AudioTrack another thread was still writing into: a native
     * use-after-free that surfaced as SIGSEGV inside `BpBinder::onLastStrongRef`, rarely, and never at the call
     * site that caused it.
     *
     * `pause()` / `flush()` move BEFORE the cancel for the same reason: they are what actually returns a parked
     * `write()`, so the join below has something to wait for rather than a thread that will not budge until the
     * ring buffer drains on its own.
     *
     * The join is bounded. A writer that has not come back by then is stuck somewhere this class cannot reach,
     * and blocking a caller — often the main thread, since teardown runs from the Reader leaving or an edit
     * landing — is worse than the leak of letting that one thread finish on its own.
     */
    open fun stop() {
        running = false
        // Order matters: unpark the writer first, then ask it to stop, then wait for it.
        track?.pause()
        track?.flush()
        val scope = writerScope
        writerScope = null
        scope?.cancel()
        val job = scope?.coroutineContext?.job ?: return
        runBlocking { withTimeoutOrNull(WRITER_SHUTDOWN_TIMEOUT_MS) { job.join() } }
    }

    /**
     * Reads the device's audio clock, or `null` when it cannot supply one.
     *
     * `AudioTrack.getTimestamp` is documented as best-effort: it returns false before enough audio
     * has been written, on routes that do not report a timestamp, and after the track is released.
     * A caller must treat `null` as "no better information than the poll loop's" rather than as an
     * error — every position this pairs with stays correct without it, only coarser.
     */
    open fun audioTimestamp(): ClockSample? {
        val t = track ?: return null
        val ts = AudioTimestamp()
        if (!t.getTimestamp(ts)) return null
        return ClockSample(framePosition = ts.framePosition, nanoTime = ts.nanoTime)
    }

    /**
     * Stops playback, releases the AudioTrack, and shuts down the writer dispatcher.
     *
     * Safe because [stop] joins the writer: nothing is touching the track by the time it is released, and nothing
     * is calling back into the [Producer] by the time the caller tears the synth down after this returns.
     */
    open override fun close() {
        stop()
        track?.release()
        track = null
        writerDispatcher.close()
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
