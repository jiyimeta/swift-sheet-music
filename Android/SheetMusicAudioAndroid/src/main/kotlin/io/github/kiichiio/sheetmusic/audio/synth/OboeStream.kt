package io.github.kiichiio.sheetmusic.audio.synth

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
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

    companion object {
        private const val TAG = "OboeStream"
        // Log underrun diagnostics once every ~10 s of audio (480 frames/buf * 2048 iters ≈ 10 s)
        private const val UNDERRUN_LOG_INTERVAL = 2048
    }

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
     */
    open fun stop() {
        running = false
        writerScope?.cancel()
        writerScope = null
        track?.pause()
        track?.flush()
    }

    /** Stops playback, releases the AudioTrack, and shuts down the writer dispatcher. */
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
        var iteration = 0
        // Per-window peak / sum-of-squares accumulators reset every ~1 s of audio.
        var windowPeak = 0f
        var windowSumSquares = 0.0
        var windowFrames = 0L
        val framesPerSecond = framesPerBuffer.toLong() * (48_000 / framesPerBuffer)
        while (running && currentCoroutineContext().isActive) {
            val p = producer.get()
            if (p == null) {
                delay(5)
                continue
            }
            p.produce(framesPerBuffer, left, right)
            val mv = masterVolume
            for (i in 0 until framesPerBuffer) {
                val ls = left[i] * mv
                val rs = right[i] * mv
                interleaved[i * 2] = ls
                interleaved[i * 2 + 1] = rs
                val a = kotlin.math.max(kotlin.math.abs(ls), kotlin.math.abs(rs))
                if (a > windowPeak) windowPeak = a
                windowSumSquares += (ls.toDouble() * ls + rs.toDouble() * rs)
            }
            windowFrames += framesPerBuffer
            track?.write(interleaved, 0, interleaved.size, AudioTrack.WRITE_BLOCKING)
            // Diagnostic: log underrun count every ~10 s of audio. API 24+.
            if (++iteration % UNDERRUN_LOG_INTERVAL == 0) {
                val underruns = track?.underrunCount ?: -1
                Log.i(TAG, "underrunCount=$underruns iter=$iteration thread=${Thread.currentThread().name}")
            }
            // Peak / RMS meter, once per second.
            if (windowFrames >= framesPerSecond) {
                val rmsLinear = kotlin.math.sqrt(
                    windowSumSquares / (windowFrames * 2.0).coerceAtLeast(1.0)
                ).toFloat()
                val peakDb = if (windowPeak > 0f)
                    20f * kotlin.math.log10(windowPeak.toDouble()).toFloat()
                else Float.NEGATIVE_INFINITY
                val rmsDb = if (rmsLinear > 0f)
                    20f * kotlin.math.log10(rmsLinear.toDouble()).toFloat()
                else Float.NEGATIVE_INFINITY
                Log.i(
                    TAG,
                    "meter peak=%.3f (%.1f dBFS) rms=%.3f (%.1f dBFS)"
                        .format(windowPeak, peakDb, rmsLinear, rmsDb),
                )
                windowPeak = 0f
                windowSumSquares = 0.0
                windowFrames = 0
            }
        }
    }
}
