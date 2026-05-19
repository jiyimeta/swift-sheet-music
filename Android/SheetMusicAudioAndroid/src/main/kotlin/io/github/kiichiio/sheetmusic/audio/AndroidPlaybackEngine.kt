package io.github.kiichiio.sheetmusic.audio

import android.content.Context
import io.github.kiichiio.sheetmusic.audio.jni.SheetMusicAudioJNI
import io.github.kiichiio.sheetmusic.audio.model.MixerChannel
import io.github.kiichiio.sheetmusic.audio.model.NoteID
import io.github.kiichiio.sheetmusic.audio.model.PlaybackState
import io.github.kiichiio.sheetmusic.audio.model.ScoreCursor
import io.github.kiichiio.sheetmusic.audio.model.ScoreItemID
import io.github.kiichiio.sheetmusic.audio.serialization.FrameDecoder
import io.github.kiichiio.sheetmusic.audio.serialization.MetronomeBeatDecoder
import io.github.kiichiio.sheetmusic.audio.serialization.NoteIDCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreItemIDDecoder
import io.github.kiichiio.sheetmusic.audio.serialization.StaffParamsDecoder
import io.github.kiichiio.sheetmusic.audio.synth.FluidSynthDriver
import io.github.kiichiio.sheetmusic.audio.synth.FluidSynthEngine
import io.github.kiichiio.sheetmusic.audio.synth.MetronomeMixer
import io.github.kiichiio.sheetmusic.audio.synth.OboeStream
import io.github.kiichiio.sheetmusic.audio.synth.PlayerDriver
import io.github.kiichiio.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Public facade that wires [SheetMusicAudioJNI] + [FluidSynthEngine] +
 * [PlayerDriver] + [OboeStream] + [MetronomeMixer] into a single API
 * consumed by Compose ViewModels.
 *
 * ## Lifecycle
 *
 * ```
 * prepare(scoreHandle) → play() → pause() ↔ play() → stop()
 * ...
 * teardown()   // or close() — both are safe to call multiple times
 * ```
 *
 * ## Threading
 *
 * - [prepare] is `suspend` and must be called from a coroutine. It runs
 *   its I/O-heavy work on [Dispatchers.IO].
 * - All other public methods are synchronous and thread-safe. FluidSynth
 *   native calls are mutex-free per the library documentation; StateFlow
 *   updates are atomic.
 * - [StateFlow] writes from the poll job are atomic; ViewModel collectors
 *   apply `flowOn(Dispatchers.Main)` on their side as needed.
 *
 * ## Context handling in tests
 *
 * The internal constructor accepts [Context?] so that JVM unit tests can
 * pass `null`. Production always supplies a real [Context]. The only
 * place [Context] is used is in [FluidSynthEngine.setupStaves] for SF2
 * materialization; fakes never dereference it.
 */
class AndroidPlaybackEngine internal constructor(
    private val context: Context?,
    private val soundfontResolver: SoundfontResolver,
    private val jniBridge: JniBridge,
    private val synthFactory: (Int) -> SynthDriver,
    private val playerFactory: (Long) -> PlayerDriver,
    private val oboeFactory: () -> OboeStream,
    /** Dispatcher used for the poll loop. Injectable for tests. */
    private val pollDispatcher: CoroutineDispatcher = Dispatchers.Default,
) : AutoCloseable {

    // ── JniBridge seam ───────────────────────────────────────────────

    /**
     * Seam between [AndroidPlaybackEngine] and the native JNI layer.
     * Production code uses [defaultBridge]; tests inject a [FakeJniBridge].
     */
    interface JniBridge {
        /** Returns the rendered SMF bytes for [scoreHandle]. */
        fun renderMidi(scoreHandle: Long): ByteArray

        /** Returns [totalTicks, totalMicros, ticksPerBeat] as a [LongArray]. */
        fun timelineSummary(scoreHandle: Long): LongArray

        /** Returns a serialized [Frame] for the nearest frame at or before [tick]. */
        fun frameAtTick(scoreHandle: Long, tick: Long): ByteArray

        /** Returns a serialized [Frame] for the frame matching [cursorBytes]. */
        fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray

        /** Returns a serialized metronome-beat array. */
        fun metronomeBeats(scoreHandle: Long): ByteArray

        /** Returns a serialized staff-params array. */
        fun staffParams(scoreHandle: Long): ByteArray

        /**
         * Returns `(pitch << 32) | staffIndex` for [noteIdBytes],
         * or -1 if not found.
         */
        fun pitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long

        /**
         * Returns a serialized [ScoreItemID] for the earliest item in
         * [idsBytes], or an empty byte array if [idsBytes] is empty.
         */
        fun earliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray
    }

    companion object {
        /** Production bridge backed by [SheetMusicAudioJNI]. */
        val defaultBridge: JniBridge = object : JniBridge {
            override fun renderMidi(h: Long) = SheetMusicAudioJNI.nativeRenderMidi(h)
            override fun timelineSummary(h: Long) = SheetMusicAudioJNI.nativeTimelineSummary(h)
            override fun frameAtTick(h: Long, t: Long) = SheetMusicAudioJNI.nativeFrameAtTick(h, t)
            override fun frameForCursor(h: Long, c: ByteArray) =
                SheetMusicAudioJNI.nativeFrameForCursor(h, c)
            override fun metronomeBeats(h: Long) = SheetMusicAudioJNI.nativeMetronomeBeats(h)
            override fun staffParams(h: Long) = SheetMusicAudioJNI.nativeStaffParams(h)
            override fun pitchAndStaffOfNote(h: Long, n: ByteArray) =
                SheetMusicAudioJNI.nativePitchAndStaffOfNote(h, n)
            override fun earliestOf(h: Long, i: ByteArray) = SheetMusicAudioJNI.nativeEarliestOf(h, i)
        }
    }

    /** Public production constructor — uses [defaultBridge] and real sub-components. */
    constructor(context: Context, soundfontResolver: SoundfontResolver) : this(
        context = context,
        soundfontResolver = soundfontResolver,
        jniBridge = defaultBridge,
        synthFactory = { sr -> FluidSynthDriver.create(sr) },
        playerFactory = { synthHandle -> PlayerDriver(synthHandle) },
        oboeFactory = { OboeStream() },
        pollDispatcher = Dispatchers.Default,
    )

    // ── Observable state ─────────────────────────────────────────────

    private val _state = MutableStateFlow(PlaybackState.STOPPED)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private val _currentCursor = MutableStateFlow<ScoreCursor?>(null)
    val currentCursor: StateFlow<ScoreCursor?> = _currentCursor.asStateFlow()

    private val _currentTimeSeconds = MutableStateFlow(0.0)
    val currentTimeSeconds: StateFlow<Double> = _currentTimeSeconds.asStateFlow()

    private val _totalTimeSeconds = MutableStateFlow(0.0)
    val totalTimeSeconds: StateFlow<Double> = _totalTimeSeconds.asStateFlow()

    private val _mixerChannels = MutableStateFlow<List<MixerChannel>>(emptyList())
    val mixerChannels: StateFlow<List<MixerChannel>> = _mixerChannels.asStateFlow()

    // ── Internal mutable state (assembled by prepare) ────────────────

    private val prepareMutex = Mutex()
    private var scoreHandle: Long = 0
    private var totalTicks: Long = 0
    private var fluidSynthEngine: FluidSynthEngine? = null
    private var playerDriver: PlayerDriver? = null
    private var oboeStream: OboeStream? = null
    private var metronomeMixer: MetronomeMixer? = null
    private var pollJob: Job? = null
    // Scopes are lazy so pollDispatcher is captured after construction.
    private val pollScope by lazy { CoroutineScope(SupervisorJob() + pollDispatcher) }
    private val previewScope by lazy { CoroutineScope(SupervisorJob() + pollDispatcher) }

    @Volatile private var masterVolume: Float = 1.0f

    // ── prepare ──────────────────────────────────────────────────────

    /**
     * Loads score data from the Swift bridge, creates per-staff synthesizers,
     * initializes the player and stream, and transitions to [PlaybackState.PREPARED].
     *
     * @param scoreHandle opaque handle obtained from the JNI score-loading API.
     * @throws AudioBackendException.InvalidScoreHandle if the timeline summary is malformed.
     * @throws AudioBackendException.EmptyScore if the score has no staves.
     * @throws AudioBackendException.TooManyStaves if the score has more than 16 staves.
     */
    suspend fun prepare(scoreHandle: Long) = prepareMutex.withLock {
        withContext(Dispatchers.IO) {
            val summary = jniBridge.timelineSummary(scoreHandle)
            if (summary.size < 3) throw AudioBackendException.InvalidScoreHandle()
            totalTicks = summary[0]
            val totalSecs = summary[1] / 1_000_000.0

            val staffBytes = jniBridge.staffParams(scoreHandle)
            val staves = StaffParamsDecoder.decodeArray(staffBytes)
            if (staves.isEmpty()) throw AudioBackendException.EmptyScore()
            if (staves.size > 16) throw AudioBackendException.TooManyStaves(staves.size)

            val beatBytes = jniBridge.metronomeBeats(scoreHandle)
            val beats = MetronomeBeatDecoder.decodeArray(beatBytes)

            val smfBytes = jniBridge.renderMidi(scoreHandle)
            if (smfBytes.isEmpty()) throw AudioBackendException.InvalidScoreHandle()

            // Tear down any prior prepared state before recreating.
            teardownInternalNoCancelScopes()

            // Per-staff FluidSynth instances.
            val engine = FluidSynthEngine(synthFactory)
            engine.setupStaves(staves, soundfontResolver, context)
            this@AndroidPlaybackEngine.fluidSynthEngine = engine

            // Dedicated metronome synth on a separate fluid_synth_t.
            val metronomeSynth = synthFactory(48_000)
            val metronomeUri = soundfontResolver.soundfontUriFor(bank = 0, program = 0, isDrums = true)
                ?: soundfontResolver.defaultGmSoundfontUri
            metronomeUri?.let { uri -> metronomeSynth.loadSoundFont(uri, context) }
            metronomeMixer = MetronomeMixer(metronomeSynth, beats)

            // PlayerDriver attached to synthHandle 0 for v0.
            // A follow-up phase will expose SynthDriver.nativeHandle and
            // route the player callback to per-staff synths.
            val player = playerFactory(0L)
            player.load(smfBytes)
            this@AndroidPlaybackEngine.playerDriver = player

            val oboe = oboeFactory().also { it.open() }
            oboeStream = oboe

            this@AndroidPlaybackEngine.scoreHandle = scoreHandle
            _mixerChannels.value = staves.mapIndexed { i, _ ->
                MixerChannel(staffIndex = i, displayName = "Staff ${i + 1}")
            }
            _totalTimeSeconds.value = totalSecs
            _currentTimeSeconds.value = 0.0
            _currentCursor.value = null
            _state.value = PlaybackState.PREPARED
        }
    }

    // ── Playback controls ────────────────────────────────────────────

    /**
     * Starts playback, optionally seeking to [from] first.
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun play(from: ScoreCursor? = null) {
        if (_state.value == PlaybackState.EXPORTING) return
        val player = playerDriver ?: return
        if (from != null) seek(from)
        player.play()
        _state.value = PlaybackState.PLAYING
        startPollJob()
    }

    /**
     * Pauses playback. Idempotent.
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun pause() {
        if (_state.value == PlaybackState.EXPORTING) return
        playerDriver?.stop()
        stopPollJob()
        _state.value = PlaybackState.PAUSED
    }

    /**
     * Stops playback and resets position to the beginning.
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun stop() {
        if (_state.value == PlaybackState.EXPORTING) return
        playerDriver?.stop()
        playerDriver?.seekTick(0L)
        fluidSynthEngine?.allNotesOff()
        stopPollJob()
        _state.value = PlaybackState.STOPPED
        _currentCursor.value = null
        _currentTimeSeconds.value = 0.0
    }

    // ── Seek / skip ──────────────────────────────────────────────────

    /**
     * Seeks to the frame matching [to].
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun seek(to: ScoreCursor) {
        if (_state.value == PlaybackState.EXPORTING) return
        val player = playerDriver ?: return
        val cursorBytes = ScoreCursorCodec.encode(to)
        val frameBytes = jniBridge.frameForCursor(scoreHandle, cursorBytes)
        val frame = FrameDecoder.decode(frameBytes) ?: return
        fluidSynthEngine?.allNotesOff()
        player.seekTick(frame.tick)
        _currentCursor.value = to
        _currentTimeSeconds.value = frame.timeSeconds
    }

    /**
     * Skips forward/backward by [seconds] relative to the current position.
     * Clamps to [0, totalTimeSeconds].
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun skip(seconds: Double) {
        if (_state.value == PlaybackState.EXPORTING) return
        val player = playerDriver ?: return
        val total = _totalTimeSeconds.value
        val target = (_currentTimeSeconds.value + seconds).coerceIn(0.0, total)
        val targetTickEstimate = if (total > 0) {
            (target / total * totalTicks).toLong()
        } else 0L
        val frameBytes = jniBridge.frameAtTick(scoreHandle, targetTickEstimate)
        val frame = FrameDecoder.decode(frameBytes) ?: return
        fluidSynthEngine?.allNotesOff()
        player.seekTick(frame.tick)
        _currentCursor.value = frame.cursor
        _currentTimeSeconds.value = frame.timeSeconds
    }

    // ── Preview / cursor ─────────────────────────────────────────────

    /**
     * Plays a single-note preview for [noteId] at the given [velocity] for
     * [durationMillis] ms. Fires noteOff asynchronously in [previewScope].
     * No-op when [state] is [PlaybackState.EXPORTING] or no engine is ready.
     */
    fun playPreview(noteId: NoteID, durationMillis: Long = 300L, velocity: Int = 96) {
        if (_state.value == PlaybackState.EXPORTING) return
        val engine = fluidSynthEngine ?: return
        val packed = jniBridge.pitchAndStaffOfNote(scoreHandle, NoteIDCodec.encode(noteId))
        if (packed == -1L || packed.toULong() == 0xFFFF_FFFF_FFFF_FFFFuL) return
        val pitch = ((packed.toULong() shr 32) and 0xFFFF_FFFFu).toInt()
        val staffIndex = (packed.toULong() and 0xFFFF_FFFFu).toInt()
        val driver = engine.staff(staffIndex) ?: return
        driver.noteOn(channel = 0, pitch = pitch, velocity = velocity)
        previewScope.launch {
            delay(durationMillis)
            driver.noteOff(channel = 0, pitch = pitch)
        }
    }

    /** Clears the current score cursor without affecting playback state. */
    fun clearCursor() { _currentCursor.value = null }

    /**
     * Returns the [ScoreItemID] in [of] that comes earliest in the score,
     * or `null` if [of] is empty or no item matches.
     */
    fun earliest(of: List<ScoreItemID>): ScoreItemID? {
        val bytes = jniBridge.earliestOf(scoreHandle, ScoreItemIDCodec.encodeArray(of))
        if (bytes.isEmpty()) return null
        return ScoreItemIDDecoder.decode(bytes)
    }

    // ── Mixer ────────────────────────────────────────────────────────

    /**
     * Sets the master output volume (range 0..1).
     * Propagates to [OboeStream.setMasterVolume].
     */
    fun setMasterVolume(volume: Float) {
        masterVolume = volume
        oboeStream?.setMasterVolume(volume)
    }

    /**
     * Mutes or un-mutes staff [staffIndex].
     * Recomputes [MixerChannel.effectiveMute] for all channels.
     */
    fun setStaffMuted(staffIndex: Int, muted: Boolean) {
        updateChannel(staffIndex) { it.copy(isMuted = muted) }
    }

    /**
     * Solos or un-solos staff [staffIndex].
     * When any staff is soloed, un-soloed staves are effectively muted.
     * Recomputes [MixerChannel.effectiveMute] for all channels.
     */
    fun setStaffSoloed(staffIndex: Int, soloed: Boolean) {
        updateChannel(staffIndex) { it.copy(isSoloed = soloed) }
    }

    /**
     * Sets the volume for staff [staffIndex] (range 0..1).
     * Propagates to the staff's [SynthDriver.setGain].
     */
    fun setStaffVolume(staffIndex: Int, volume: Float) {
        fluidSynthEngine?.setStaffGain(staffIndex, volume)
        updateChannel(staffIndex) { it.copy(volume = volume) }
    }

    // ── Metronome ────────────────────────────────────────────────────

    /** Enables or disables metronome click output. */
    fun setMetronomeEnabled(enabled: Boolean) {
        metronomeMixer?.isEnabled = enabled
    }

    /** Sets metronome click volume (range 0..1). */
    fun setMetronomeVolume(volume: Float) {
        metronomeMixer?.volume = volume
    }

    // ── Teardown ─────────────────────────────────────────────────────

    /**
     * Tears down all resources and transitions to [PlaybackState.STOPPED].
     * Idempotent — safe to call multiple times.
     */
    fun teardown() {
        pollJob?.cancel()
        pollJob = null
        previewScope.cancel()
        pollScope.cancel()
        oboeStream?.close()
        oboeStream = null
        playerDriver?.let {
            try { it.stop() } catch (_: Throwable) {}
            try { it.join() } catch (_: Throwable) {}
            it.close()
        }
        playerDriver = null
        fluidSynthEngine?.teardown()
        fluidSynthEngine = null
        metronomeMixer = null
        _state.value = PlaybackState.STOPPED
    }

    override fun close() = teardown()

    // ── Poll job ─────────────────────────────────────────────────────

    private fun startPollJob() {
        pollJob?.cancel()
        pollJob = pollScope.launch {
            while (isActive && _state.value == PlaybackState.PLAYING) {
                val player = playerDriver ?: break
                val tick = player.currentTick
                metronomeMixer?.updateCurrentTick(tick)

                val frameBytes = jniBridge.frameAtTick(scoreHandle, tick)
                val frame = FrameDecoder.decode(frameBytes)
                // StateFlow.value assignments are atomic and thread-safe;
                // no Main-dispatch required here. Collectors in ViewModels
                // can observe on the UI dispatcher themselves via flowOn().
                if (frame != null) {
                    _currentCursor.value = frame.cursor
                    _currentTimeSeconds.value = frame.timeSeconds
                }
                if (tick >= totalTicks && totalTicks > 0) {
                    stop()
                    break
                }
                delay(33)
            }
        }
    }

    private fun stopPollJob() {
        pollJob?.cancel()
        pollJob = null
    }

    // ── Mixer helpers ─────────────────────────────────────────────────

    private inline fun updateChannel(idx: Int, mutate: (MixerChannel) -> MixerChannel) {
        _mixerChannels.update { list ->
            if (idx !in list.indices) return@update list
            val mut = list.toMutableList()
            mut[idx] = mutate(mut[idx])
            recomputeEffectiveMutes(mut)
        }
    }

    private fun recomputeEffectiveMutes(channels: MutableList<MixerChannel>): List<MixerChannel> {
        val anySoloed = channels.any { it.isSoloed && !it.isMuted }
        return channels.map { c ->
            val effMute = c.isMuted || (anySoloed && !c.isSoloed)
            c.copy(effectiveMute = effMute)
        }
    }

    /**
     * Tears down internal components without cancelling [pollScope] /
     * [previewScope]. Called by [prepare] when re-preparing a new score
     * while those scopes should stay alive.
     */
    private fun teardownInternalNoCancelScopes() {
        pollJob?.cancel()
        pollJob = null
        oboeStream?.close()
        oboeStream = null
        playerDriver?.let {
            try { it.stop() } catch (_: Throwable) {}
            it.close()
        }
        playerDriver = null
        fluidSynthEngine?.teardown()
        fluidSynthEngine = null
        metronomeMixer = null
    }
}
