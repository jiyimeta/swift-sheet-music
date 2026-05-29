package io.github.jiyimeta.sheetmusic.audio

import android.content.Context
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.export.AudioExporter
import io.github.jiyimeta.sheetmusic.audio.export.ExportEngineSnapshot
import io.github.jiyimeta.sheetmusic.audio.jni.SheetMusicAudioJNI
import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.AudioExportRangeCodec
import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.sheetmusic.audio.serialization.FrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.MetronomeBeatCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.NoteIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthDriver
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthEngine
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeMixer
import io.github.jiyimeta.sheetmusic.audio.synth.OboeStream
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
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

        /** Returns the item's end tick in ticks, or -1 if the id is not in the timeline. */
        fun itemEndTick(scoreHandle: Long, idBytes: ByteArray): Long

        /**
         * Resolve an [AudioExportRange] (encoded by [AudioExportRangeCodec])
         * to `[startTick, endTick]`. Returns `[-1, -1]` on failure.
         */
        fun resolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray
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
            override fun itemEndTick(h: Long, i: ByteArray) =
                SheetMusicAudioJNI.nativeItemEndTick(h, i)
            override fun resolveExportTickRange(h: Long, bytes: ByteArray) =
                SheetMusicAudioJNI.nativeResolveExportTickRange(h, bytes)
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

    /**
     * Lifecycle state of the engine. Driven internally by [play] /
     * [pause] / [stop] / [prepare] / [exportToWavFile] (when that
     * path is wired) and by the poll loop's end-of-score detection.
     *
     * MediaSession integrators: map to
     * `androidx.media3.common.Player.STATE_*` (or
     * `PlaybackStateCompat.STATE_*` for the legacy MediaSession
     * API):
     *
     * | engine state | Media3 Player.State    | PlaybackStateCompat |
     * |--------------|------------------------|---------------------|
     * | STOPPED      | STATE_IDLE / STATE_ENDED | STATE_STOPPED     |
     * | PREPARED     | STATE_READY            | STATE_PAUSED        |
     * | PLAYING      | STATE_READY (+ playing)| STATE_PLAYING       |
     * | PAUSED       | STATE_READY (+ paused) | STATE_PAUSED        |
     * | EXPORTING    | (transport unavailable) | STATE_STOPPED      |
     *
     * The EXPORTING row reflects the engine's no-op guard on all
     * transport methods during export — apps should hide or disable
     * transport UI in that state.
     */
    private val _state = MutableStateFlow(PlaybackState.STOPPED)
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private val _currentCursor = MutableStateFlow<ScoreCursor?>(null)
    val currentCursor: StateFlow<ScoreCursor?> = _currentCursor.asStateFlow()

    /**
     * Current playback position in seconds, updated at the poll loop
     * cadence (~33 ms) during playback and on every [seek] / [skip] /
     * [stop] / [prepare].
     *
     * During A-B loop playback, the poll loop snaps tick into
     * `[loop.startTick, loop.endTick)` before reading the frame
     * time, so observers see the wrapped (audible) position rather
     * than a value that climbs past `loop.endTick`. This is the
     * behavior MediaSession scrubbers and `getCurrentPosition()`
     * implementations expect — without the fold, the lock-screen
     * scrubber would keep advancing and saturate at score end.
     */
    private val _currentTimeSeconds = MutableStateFlow(0.0)
    val currentTimeSeconds: StateFlow<Double> = _currentTimeSeconds.asStateFlow()

    private val _totalTimeSeconds = MutableStateFlow(0.0)
    val totalTimeSeconds: StateFlow<Double> = _totalTimeSeconds.asStateFlow()

    private val _mixerChannels = MutableStateFlow<List<MixerChannel>>(emptyList())
    val mixerChannels: StateFlow<List<MixerChannel>> = _mixerChannels.asStateFlow()

    private val _currentRate = MutableStateFlow(1.0f)
    val currentRate: StateFlow<Float> = _currentRate.asStateFlow()

    private val _loopRange = MutableStateFlow<LoopRange?>(null)
    val loopRange: StateFlow<LoopRange?> = _loopRange.asStateFlow()

    // ── Internal mutable state (assembled by prepare) ────────────────

    private val prepareMutex = Mutex()
    private val exportMutex = Mutex()
    private var scoreHandle: Long = 0
    private var totalTicks: Long = 0
    /** Ticks-per-beat from the prepared score's timeline; required by export. */
    private var ticksPerBeat: Int = 480
    private var fluidSynthEngine: FluidSynthEngine? = null
    private var playerDriver: PlayerDriver? = null
    private var oboeStream: OboeStream? = null
    private var metronomeMixer: MetronomeMixer? = null
    private var pollJob: Job? = null
    // Scopes are lazy so pollDispatcher is captured after construction.
    private val pollScope by lazy { CoroutineScope(SupervisorJob() + pollDispatcher) }
    private val previewScope by lazy { CoroutineScope(SupervisorJob() + pollDispatcher) }

    @Volatile private var masterVolume: Float = 1.0f
    @Volatile private var pendingRate: Float = 1.0f

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
            _loopRange.value = null
            val summary = jniBridge.timelineSummary(scoreHandle)
            if (summary.size < 3) throw AudioBackendException.InvalidScoreHandle()
            totalTicks = summary[0]
            val totalSecs = summary[1] / 1_000_000.0
            ticksPerBeat = summary[2].toInt()

            val staffBytes = jniBridge.staffParams(scoreHandle)
            val staves = run {
                val r = BinaryReader(staffBytes)
                val out = ArrayList<io.github.jiyimeta.sheetmusic.audio.model.StaffParams>()
                r.readLengthPrefixed { inner ->
                    while (inner.remaining > 0) {
                        out.add(inner.readLengthPrefixed { StaffParamsCodec.decodePayload(it) })
                    }
                }
                out
            }
            if (staves.isEmpty()) throw AudioBackendException.EmptyScore()
            if (staves.size > 16) throw AudioBackendException.TooManyStaves(staves.size)

            val beatBytes = jniBridge.metronomeBeats(scoreHandle)
            val beats = run {
                val r = BinaryReader(beatBytes)
                val out = ArrayList<io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat>()
                r.readLengthPrefixed { inner ->
                    while (inner.remaining > 0) {
                        out.add(inner.readLengthPrefixed { MetronomeBeatCodec.decodePayload(it) })
                    }
                }
                out
            }

            val smfBytes = jniBridge.renderMidi(scoreHandle)
            if (smfBytes.isEmpty()) throw AudioBackendException.InvalidScoreHandle()

            // Tear down any prior prepared state before recreating.
            teardownInternalNoCancelScopes()

            // Single fluid_synth_t — channels 0..N-1 map to staves 0..N-1.
            val engine = FluidSynthEngine(synthFactory)
            engine.setupStaves(staves, soundfontResolver, context)
            this@AndroidPlaybackEngine.fluidSynthEngine = engine

            // Dedicated metronome synth on a separate fluid_synth_t.
            val metronomeSynth = synthFactory(48_000)
            val metronomeUri = soundfontResolver.soundfontUriFor(bank = 0, program = 0, isDrums = true)
                ?: soundfontResolver.defaultGmSoundfontUri
            metronomeUri?.let { uri -> metronomeSynth.loadSoundFont(uri, context) }
            metronomeMixer = MetronomeMixer(metronomeSynth, beats)

            // PlayerDriver wired to the real fluid_synth_t handle.
            // fluid_player's default routing uses event.channel directly —
            // the Swift bridge already relabels SMF channels to track indices
            // (AudioMidiBridge.relabelChannelsToTrackIndex), so per-staff
            // routing works without a playback-callback shim.
            val player = playerFactory(engine.synthHandle)
            player.load(smfBytes)
            // Carry the pending rate into the newly built player so a rate set
            // before prepare (or across a re-prepare) survives.
            if (pendingRate != 1.0f) {
                player.setTempo(pendingRate.toDouble())
            }
            this@AndroidPlaybackEngine.playerDriver = player

            // Wire the OboeStream producer: mix the staff synth + metronome.
            val oboe = oboeFactory().also { it.open() }
            oboe.setProducer { frameCount, left, right ->
                val eng = this@AndroidPlaybackEngine.fluidSynthEngine
                if (eng == null) {
                    for (i in 0 until frameCount) { left[i] = 0f; right[i] = 0f }
                    return@setProducer
                }
                eng.writeFloat(frameCount, left, right)
                val mm = this@AndroidPlaybackEngine.metronomeMixer
                if (mm != null && mm.isEnabled) {
                    val mLeft = FloatArray(frameCount)
                    val mRight = FloatArray(frameCount)
                    mm.synth.writeFloat(frameCount, mLeft, mRight)
                    for (i in 0 until frameCount) {
                        left[i] += mLeft[i]
                        right[i] += mRight[i]
                    }
                }
            }
            oboeStream = oboe

            this@AndroidPlaybackEngine.scoreHandle = scoreHandle
            _mixerChannels.value = staves.mapIndexed { i, p ->
                MixerChannel(
                    staffIndex = i,
                    displayName = "Staff ${i + 1}",
                    program = if (p.isDrums) null else p.program.toInt(),
                )
            }
            _totalTimeSeconds.value = totalSecs
            _currentTimeSeconds.value = 0.0
            _currentCursor.value = null
            _currentRate.value = pendingRate
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
        oboeStream?.play()
        player.play()
        _state.value = PlaybackState.PLAYING
        startPollJob()
    }

    /**
     * Pauses playback at the current position. [play] resumes from
     * there. Idempotent.
     *
     * Also stops the underlying Oboe output stream. Stopping just
     * the FluidSynth player leaves the audio stream emitting silent
     * frames, which Android's audio focus framework reads as
     * "audio still active" and which MediaSession's
     * `PlaybackStateCompat` aggregation may use to override an
     * explicit `STATE_PAUSED`. Mirrors the equivalent
     * `AVAudioEngine.pause()` discipline on Apple side.
     *
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun pause() {
        if (_state.value == PlaybackState.EXPORTING) return
        playerDriver?.stop()
        oboeStream?.stop()
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
        oboeStream?.stop()
        stopPollJob()
        _state.value = PlaybackState.STOPPED
        _currentCursor.value = null
        _currentTimeSeconds.value = 0.0
    }

    // ── Rate ─────────────────────────────────────────────────────────

    /**
     * Scales playback speed. `1.0` is the score's native tempo; the host's
     * typical slider range is 0.5..2.0 but no clamping is applied here.
     * Persists across [prepare] calls — the rate is re-applied to a freshly
     * built [PlayerDriver].
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun setRate(rate: Float) {
        if (_state.value == PlaybackState.EXPORTING) return
        pendingRate = rate
        playerDriver?.setTempo(rate.toDouble())
        _currentRate.value = rate
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
        val frame = if (frameBytes.isEmpty()) null else FrameCodec.decode(frameBytes)
        frame ?: return
        val snapped = snapTickToLoop(frame.tick)
        fluidSynthEngine?.allNotesOff()
        player.seekTick(snapped)
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
        val frame = if (frameBytes.isEmpty()) null else FrameCodec.decode(frameBytes)
        frame ?: return
        val snapped = snapTickToLoop(frame.tick)
        fluidSynthEngine?.allNotesOff()
        player.seekTick(snapped)
        _currentCursor.value = frame.cursor
        _currentTimeSeconds.value = frame.timeSeconds
    }

    /**
     * Seek to an absolute time in seconds, clamped to
     * `[0, totalTimeSeconds]`. Preserves play / pause state.
     *
     * Provided alongside [skip] for natural integration with
     * `MediaSession.Callback.onSeekTo(positionMs)`, whose handler
     * receives an absolute target time. Internally reuses [skip]'s
     * clamp + state-preserve machinery — no new code path through
     * the player.
     *
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun seek(toTimeSeconds: Double) {
        skip(toTimeSeconds - _currentTimeSeconds.value)
    }

    // ── Loop ─────────────────────────────────────────────────────────

    /**
     * Loop the half-open region [from, to) — playback wraps at the onset
     * tick of `to` (the item under `to` is NOT sounded). Use the
     * `setLoop(from:throughEndOf:)` overload to include the last item's
     * full ringing duration.
     *
     * No-op when [state] is [PlaybackState.EXPORTING], when either cursor
     * doesn't resolve, when start.tick >= end.tick, or when no player is
     * prepared yet.
     */
    fun setLoop(from: ScoreCursor, to: ScoreCursor) {
        if (_state.value == PlaybackState.EXPORTING) return
        if (playerDriver == null) return
        val fromBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(from))
        val toBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(to))
        val fromFrame = if (fromBytes.isEmpty()) null else FrameCodec.decode(fromBytes)
        fromFrame ?: return
        val toFrame = if (toBytes.isEmpty()) null else FrameCodec.decode(toBytes)
        toFrame ?: return
        if (fromFrame.tick >= toFrame.tick) return
        _loopRange.value = LoopRange(startTick = fromFrame.tick, endTick = toFrame.tick)
    }

    /**
     * Loop from `from` through the end of `throughEndOf`'s notated duration.
     * Mirrors Apple `setLoop(from:throughEndOf:)`.
     *
     * No-op when [state] is [PlaybackState.EXPORTING], when `from` doesn't
     * resolve, when the item's end tick is not in the timeline (`itemEndTick`
     * returns -1), or when no player is prepared.
     */
    fun setLoop(from: ScoreCursor, throughEndOf: ScoreItemID) {
        if (_state.value == PlaybackState.EXPORTING) return
        if (playerDriver == null) return
        val fromBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(from))
        val fromFrame = if (fromBytes.isEmpty()) null else FrameCodec.decode(fromBytes)
        fromFrame ?: return
        val endTick = jniBridge.itemEndTick(scoreHandle, ScoreItemIDCodec.encode(throughEndOf))
        if (endTick < 0) return
        if (fromFrame.tick >= endTick) return
        _loopRange.value = LoopRange(startTick = fromFrame.tick, endTick = endTick)
    }

    /**
     * Disable looping. The next poll cycle stops snapping the playhead back
     * to startTick, so playback continues past the previous loop end.
     */
    fun clearLoop() {
        if (_state.value == PlaybackState.EXPORTING) return
        _loopRange.value = null
    }

    /** Clamp [tick] into the active loop, or return it unchanged. */
    private fun snapTickToLoop(tick: Long): Long {
        val loop = _loopRange.value ?: return tick
        return if (tick < loop.startTick || tick >= loop.endTick) loop.startTick else tick
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
        engine.previewNoteOn(staffIndex, pitch, velocity)
        previewScope.launch {
            delay(durationMillis)
            engine.previewNoteOff(staffIndex, pitch)
        }
    }

    /** Clears the current score cursor without affecting playback state. */
    fun clearCursor() { _currentCursor.value = null }

    /**
     * Returns the [ScoreItemID] in [of] that comes earliest in the score,
     * or `null` if [of] is empty or no item matches.
     */
    fun earliest(of: List<ScoreItemID>): ScoreItemID? {
        val encodedIds = run {
            val w = BinaryWriter()
            w.writeLengthPrefixed {
                for (id in of) writeLengthPrefixed { ScoreItemIDCodec.encodePayload(id, this) }
            }
            w.toByteArray()
        }
        val bytes = jniBridge.earliestOf(scoreHandle, encodedIds)
        if (bytes.isEmpty()) return null
        return ScoreItemIDCodec.decode(bytes)
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
     * Recomputes [MixerChannel.effectiveMute] for all channels and
     * propagates audibility changes to the synth via MIDI CC7.
     */
    fun setStaffMuted(staffIndex: Int, muted: Boolean) {
        updateChannel(staffIndex) { it.copy(isMuted = muted) }
        reapplyChannelAudibility(staffIndex)
        // Solo precedence may have changed effectiveMute on other staves too.
        for (i in _mixerChannels.value.indices) if (i != staffIndex) reapplyChannelAudibility(i)
    }

    /**
     * Solos or un-solos staff [staffIndex].
     * When any staff is soloed, un-soloed staves are effectively muted.
     * Recomputes [MixerChannel.effectiveMute] for all channels and
     * propagates audibility changes to the synth via MIDI CC7.
     */
    fun setStaffSoloed(staffIndex: Int, soloed: Boolean) {
        updateChannel(staffIndex) { it.copy(isSoloed = soloed) }
        for (i in _mixerChannels.value.indices) reapplyChannelAudibility(i)
    }

    /**
     * Sets the volume for staff [staffIndex] (range 0..1).
     * Propagates to the synth via MIDI CC7. If the channel is currently muted,
     * the new volume is recorded for restoration on unmute but not written to
     * the synth now (mute must keep CC7 = 0).
     */
    fun setStaffVolume(staffIndex: Int, volume: Float) {
        updateChannel(staffIndex) { it.copy(volume = volume) }
        // Use setChannelVolume (not reapplyChannelAudibility) so the new CC7 is
        // recorded in rememberedCC7 and applied only when the channel is unmuted.
        fluidSynthEngine?.setChannelVolume(staffIndex, volume)
    }

    /**
     * Swaps the GM program (sound) for staff [staffIndex].
     * The change is applied immediately to the synth and to the
     * mixer state. No-op when [state] is [PlaybackState.EXPORTING].
     * Drum staves have `MixerChannel.program == null` and the program-picker
     * UI hides those rows, so users don't reach this branch with a drum staff;
     * programmatic callers behave like [FluidSynthEngine.setStaffProgram]
     * which selects a drum-kit variation within bank 128.
     */
    fun setStaffProgram(staffIndex: Int, program: Int) {
        if (_state.value == PlaybackState.EXPORTING) return
        fluidSynthEngine?.setStaffProgram(staffIndex, program)
        updateChannel(staffIndex) { it.copy(program = program) }
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

    // ── Audio file export ────────────────────────────────────────────

    /**
     * Offline-render the prepared score to an audio file at [outputFd].
     *
     * Mirrors Apple's `PlaybackEngine.exportAudioFile`: builds a dedicated
     * FluidSynth + [PlayerDriver] per call, applies a snapshot of live
     * engine state, pumps PCM through the encoder, and transitions
     * `state` to [PlaybackState.EXPORTING] for the duration of the
     * render. Live playback mutators (`play` / `pause` / `seek` / …)
     * already no-op while `state == EXPORTING`.
     *
     * Cancelling the calling coroutine aborts the render and throws
     * [AudioBackendException.Cancelled]. The partial file at [outputFd]
     * is left intact for the caller to clean up — the engine does not
     * own the file descriptor.
     *
     * Concurrent calls are serialized through an internal mutex.
     *
     * @throws AudioBackendException.NoScorePrepared if [scoreHandle]
     *   doesn't match the most recent [prepare] call.
     * @throws AudioBackendException.RangeNotInTimeline if a `.Region`
     *   or `.RegionThroughEnd` range fails to resolve.
     * @throws AudioBackendException.FormatUnsupportedOnThisOS if the
     *   device has no encoder for the requested format.
     * @throws AudioBackendException.EngineSetupFailed on synth / player
     *   construction failure.
     * @throws AudioBackendException.FileWriteFailed on encoder write
     *   failure.
     * @throws AudioBackendException.Cancelled on coroutine cancellation.
     */
    suspend fun exportAudioFile(
        outputFd: ParcelFileDescriptor,
        scoreHandle: Long,
        format: AudioFileFormat,
        range: AudioExportRange = AudioExportRange.Full,
        progress: ((Float) -> Unit)? = null,
    ) = exportAudioFileWith(
        outputFd = outputFd,
        scoreHandle = scoreHandle,
        format = format,
        range = range,
        progress = progress,
    ) {
        AudioExporter(
            resolver = soundfontResolver,
            context = context,
            synthFactory = synthFactory,
            playerFactory = playerFactory,
        )
    }

    /**
     * Test-only seam exposing the [exporterFactory] hook and accepting a
     * nullable [outputFd] so JVM unit tests (where
     * `ParcelFileDescriptor.createPipe` is unavailable) can drive the
     * export pipeline with a [AudioExporter] backed by fake drivers.
     */
    internal suspend fun exportAudioFileWith(
        outputFd: ParcelFileDescriptor?,
        scoreHandle: Long,
        format: AudioFileFormat,
        range: AudioExportRange,
        progress: ((Float) -> Unit)?,
        exporterFactory: () -> AudioExporter,
    ) = exportMutex.withLock {
        if (this.scoreHandle == 0L || this.scoreHandle != scoreHandle) {
            throw AudioBackendException.NoScorePrepared()
        }

        // Resolve tick range. `CurrentLoop` is resolved on the Kotlin side
        // from the live [_loopRange]; the other variants need a Swift-side
        // timeline lookup via the JNI seam.
        val (startTick, endTick) = when (range) {
            is AudioExportRange.CurrentLoop -> {
                val loop = _loopRange.value
                if (loop != null) Pair(loop.startTick, loop.endTick) else Pair(0L, totalTicks)
            }
            else -> {
                val rangeBytes = AudioExportRangeCodec.encode(range)
                val resolved = jniBridge.resolveExportTickRange(scoreHandle, rangeBytes)
                if (resolved.size < 2 || resolved[0] < 0 || resolved[1] < 0) {
                    throw AudioBackendException.RangeNotInTimeline()
                }
                Pair(resolved[0], resolved[1])
            }
        }

        // Capture a snapshot of live engine state before flipping the
        // state machine — these reads must not race with the EXPORTING
        // transition (live mutators already no-op once we set EXPORTING).
        val beatBytes = jniBridge.metronomeBeats(scoreHandle)
        val beats = run {
            val r = BinaryReader(beatBytes)
            val out = ArrayList<io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat>()
            r.readLengthPrefixed { inner ->
                while (inner.remaining > 0) {
                    out.add(inner.readLengthPrefixed { MetronomeBeatCodec.decodePayload(it) })
                }
            }
            out
        }
        val snapshot = ExportEngineSnapshot(
            mixerChannels = _mixerChannels.value,
            metronomeEnabled = metronomeMixer?.isEnabled ?: false,
            metronomeVolume = metronomeMixer?.volume ?: 1f,
            metronomeBeats = beats,
            rate = _currentRate.value,
        )

        val smfBytes = jniBridge.renderMidi(scoreHandle)
        val staffParams = run {
            val spBytes = jniBridge.staffParams(scoreHandle)
            val r = BinaryReader(spBytes)
            val out = ArrayList<io.github.jiyimeta.sheetmusic.audio.model.StaffParams>()
            r.readLengthPrefixed { inner ->
                while (inner.remaining > 0) {
                    out.add(inner.readLengthPrefixed { StaffParamsCodec.decodePayload(it) })
                }
            }
            out
        }

        // Synth and encoder MUST share the same sample rate; otherwise the file
        // header advertises one rate while the samples were produced at another,
        // and players reinterpret duration / pitch by the header's rate.
        val sampleRate = when (format) {
            is AudioFileFormat.Wav -> format.options.sampleRate
            is AudioFileFormat.Aiff -> format.options.sampleRate
            is AudioFileFormat.M4a -> format.options.sampleRate
            is AudioFileFormat.Mp3 -> format.options.sampleRate
        }

        _state.value = PlaybackState.EXPORTING
        try {
            exporterFactory().run(
                outputFd = outputFd,
                smfBytes = smfBytes,
                staffParams = staffParams,
                snapshot = snapshot,
                startTick = startTick,
                endTick = endTick,
                ticksPerBeat = ticksPerBeat,
                format = format,
                sampleRate = sampleRate,
                progress = progress,
            )
        } finally {
            _state.value = PlaybackState.STOPPED
        }
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
                var tick = player.currentTick
                // Loop wrap: if we've advanced past loop.endTick, snap back.
                val loop = _loopRange.value
                if (loop != null && tick >= loop.endTick) {
                    fluidSynthEngine?.allNotesOff()
                    player.seekTick(loop.startTick)
                    tick = loop.startTick
                }
                metronomeMixer?.updateCurrentTick(tick)

                val frameBytes = jniBridge.frameAtTick(scoreHandle, tick)
                val frame = if (frameBytes.isEmpty()) null else FrameCodec.decode(frameBytes)
                // StateFlow.value assignments are atomic and thread-safe;
                // no Main-dispatch required here. Collectors in ViewModels
                // can observe on the UI dispatcher themselves via flowOn().
                if (frame != null) {
                    _currentCursor.value = frame.cursor
                    _currentTimeSeconds.value = frame.timeSeconds
                }
                // End of score: only stop when no loop is active.
                if (loop == null && tick >= totalTicks && totalTicks > 0) {
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
     * Reads the current [MixerChannel.effectiveMute] for [staffIndex] and
     * propagates the mute/unmute transition to the synth via MIDI CC7.
     *
     * On unmute, calls [FluidSynthEngine.unmuteChannel] which restores the
     * last-captured CC7 value (SMF-emitted or user-set) rather than writing
     * the mixer slider value (which would snap volume to 127). Volume-slider
     * changes call [FluidSynthEngine.setChannelVolume] directly via
     * [setStaffVolume].
     *
     * Must be called *after* [updateChannel] so the [_mixerChannels] state
     * already reflects the latest [MixerChannel.effectiveMute] value.
     */
    private fun reapplyChannelAudibility(staffIndex: Int) {
        val ch = _mixerChannels.value.getOrNull(staffIndex) ?: return
        if (ch.effectiveMute) {
            fluidSynthEngine?.muteChannel(staffIndex)
        } else {
            fluidSynthEngine?.unmuteChannel(staffIndex)
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
