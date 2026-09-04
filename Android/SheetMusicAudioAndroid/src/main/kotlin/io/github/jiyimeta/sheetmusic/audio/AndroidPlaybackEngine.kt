package io.github.jiyimeta.sheetmusic.audio

import android.content.Context
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.CountInWire
import io.github.jiyimeta.sheetmusic.CountInWireCodec
import io.github.jiyimeta.sheetmusic.audio.export.AudioExporter
import io.github.jiyimeta.sheetmusic.audio.export.ExportEngineSnapshot
import io.github.jiyimeta.sheetmusic.audio.jni.SheetMusicAudioJNI
import io.github.jiyimeta.sheetmusic.audio.model.AudioClockPosition
import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.InstrumentParams
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MasterOutputStage
import io.github.jiyimeta.sheetmusic.audio.model.MixLevel
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.serialization.AudioExportRangeCodec
import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.sheetmusic.audio.serialization.FrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.InstrumentParamsCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.MetronomeBeatCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.MidiControlChangeCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.NoteIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.PreviewPlanCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthDriver
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthEngine
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeMixer
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeSf2Loader
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
import java.util.concurrent.atomic.AtomicInteger

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
    /**
     * A `var` so [reloadSoundfont] can replace it. Everything that reads it does so inside
     * [prepare], under [prepareMutex], so a swap can never land mid-load.
     */
    private var soundfontResolver: SoundfontResolver,
    private val metronomeClickProvider: MetronomeClickProvider? = null,
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

        /**
         * Returns the metronome's own SMF — the score's tempo map plus the click track — for the second
         * player the metronome runs on. Empty when the score has no beats or the native bridge predates
         * this entry point; the engine then plays without a metronome.
         */
        fun renderMetronomeMidi(scoreHandle: Long): ByteArray

        /**
         * The same sequence with a count-in region in front, for playback starting at [cursorBytes]
         * (whose tick is [baseTick]). Empty when the position has no count-in.
         */
        fun renderCountInMetronomeMidi(
            scoreHandle: Long,
            cursorBytes: ByteArray,
            baseTick: Long,
        ): ByteArray

        /** Returns [totalTicks, totalMicros, ticksPerBeat] as a [LongArray]. */
        fun timelineSummary(scoreHandle: Long): LongArray

        /** Returns a serialized [Frame] for the nearest frame at or before [tick]. */
        fun frameAtTick(scoreHandle: Long, tick: Long): ByteArray

        /** Returns a serialized [Frame] for the frame matching [cursorBytes]. */
        fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray

        /**
         * The UNROLLED transport tick that a NOTATED score tick sits at — its first occurrence in
         * playback order. The write-side inverse of [frameAtTick]'s read-side translation.
         *
         * The engine gets notated ticks out of [frameForCursor], [itemEndTick] and the timeline
         * summary's `totalTicks`, but everything it hands the player ([PlayerDriver.seekTick]) or
         * reads back from it ([PlayerDriver.currentTick]) is unrolled. This is the projection
         * between them, and it is a genuine translation only on a score whose repeats or jumps make
         * the rendered SMF longer than the notated timeline.
         *
         * Returns -1 when the handle is unknown, the tick is negative, or the native bridge predates
         * this entry point. The default here returns the tick unchanged for exactly that last case —
         * identity is what the engine did before this existed, and it stays correct for every score
         * without a repeat.
         */
        fun unrolledTickForNotated(scoreHandle: Long, notatedTick: Long): Long = notatedTick

        /** Returns a serialized `CountInWire` for a pre-roll starting at [cursorBytes]. */
        fun countIn(scoreHandle: Long, cursorBytes: ByteArray): ByteArray

        /** Returns a serialized staff-params array. */
        fun staffParams(scoreHandle: Long): ByteArray

        /**
         * Returns a serialized instrument-params array — one entry per
         * deduped (part × instrument) mixer strip. Empty on an older
         * native bridge that predates this call; [prepare] falls back to
         * one strip per staff in that case.
         */
        fun instrumentParams(scoreHandle: Long): ByteArray

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

        /** Builds a click SF2 from two WAV blobs; empty array on failure. */
        fun buildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray): ByteArray

        // ── Note auditions ───────────────────────────────────────────
        //
        // Which audition supersedes which, how long a drum rings against a melodic note, and how long the
        // audio graph has to stay alive for a release are decided by shared Swift (`NotePreviewPolicy`) that
        // the Apple engine runs too. This engine asks and then executes, in FluidSynth's own messages. It
        // used to decide as well, in a hand-written copy of Apple's state machine that had neither the
        // supersede nor the release tail — both audible, and both already fixed on the other platform.

        /** Creates an audition policy. The caller owns the handle and must [previewPolicyRelease] it. */
        fun previewPolicyCreate(): Long

        /** Releases a handle from [previewPolicyCreate]. Unknown handles are ignored. */
        fun previewPolicyRelease(policyHandle: Long)

        /**
         * Plans one audition, superseding whatever was sounding. Returns an encoded [PreviewPlan], or an
         * empty array for an unknown handle — for which the only sane response is to sound nothing, there
         * being no generation to end the note by.
         */
        fun previewPolicyBegin(
            policyHandle: Long,
            channel: Int,
            pitch: Int,
            velocity: Int,
            isDrum: Boolean,
            ringMilliseconds: Int,
        ): ByteArray

        /**
         * The note to silence now that [generation]'s ring time is up, packed as `channel shl 8 or pitch`,
         * or -1 when a newer audition superseded it and silencing anything would silence THAT note.
         */
        fun previewPolicyEnd(policyHandle: Long, generation: Long): Long

        /** Abandons any audition in progress, answering the note to silence, packed as above, or -1. */
        fun previewPolicySilence(policyHandle: Long): Long

        /**
         * The MIDI Master Tuning RPN messages retuning one channel by [cents] off A4=440, as consecutive
         * `(controller, value)` byte pairs. Shared with the Apple engine, which reads the same split into
         * its AudioUnit tuning params — see `MasterTuning` in SheetMusicAudioCore.
         */
        fun masterTuningControlChanges(cents: Double): ByteArray
    }

    companion object {
        /**
         * How often the count-in checks whether the click transport has reached the pre-roll's end.
         * Only the single handover to the score rides on this; the clicks are placed by the sequence.
         */
        private const val COUNT_IN_HANDOVER_POLL_MILLIS = 2L

        /** Production bridge backed by [SheetMusicAudioJNI]. */
        val defaultBridge: JniBridge = object : JniBridge {
            override fun renderMidi(h: Long) = SheetMusicAudioJNI.nativeRenderMidi(h)
            override fun renderMetronomeMidi(h: Long) =
                SheetMusicAudioJNI.nativeRenderMetronomeMidi(h)
            override fun renderCountInMetronomeMidi(h: Long, c: ByteArray, baseTick: Long) =
                SheetMusicAudioJNI.nativeRenderCountInMetronomeMidi(h, c, baseTick)
            override fun timelineSummary(h: Long) = SheetMusicAudioJNI.nativeTimelineSummary(h)
            override fun frameAtTick(h: Long, t: Long) = SheetMusicAudioJNI.nativeFrameAtTick(h, t)
            override fun frameForCursor(h: Long, c: ByteArray) =
                SheetMusicAudioJNI.nativeFrameForCursor(h, c)
            override fun unrolledTickForNotated(h: Long, t: Long) =
                SheetMusicAudioJNI.nativeUnrolledTickForNotated(h, t)
            override fun countIn(h: Long, c: ByteArray) = SheetMusicAudioJNI.nativeCountIn(h, c)
            override fun staffParams(h: Long) = SheetMusicAudioJNI.nativeStaffParams(h)
            override fun instrumentParams(h: Long) = SheetMusicAudioJNI.nativeInstrumentParams(h)
            override fun pitchAndStaffOfNote(h: Long, n: ByteArray) =
                SheetMusicAudioJNI.nativePitchAndStaffOfNote(h, n)
            override fun earliestOf(h: Long, i: ByteArray) = SheetMusicAudioJNI.nativeEarliestOf(h, i)
            override fun itemEndTick(h: Long, i: ByteArray) =
                SheetMusicAudioJNI.nativeItemEndTick(h, i)
            override fun resolveExportTickRange(h: Long, bytes: ByteArray) =
                SheetMusicAudioJNI.nativeResolveExportTickRange(h, bytes)
            override fun buildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray) =
                SheetMusicAudioJNI.nativeBuildClickSoundFont(strongWav, weakWav)
            override fun previewPolicyCreate() = SheetMusicAudioJNI.nativePreviewPolicyCreate()
            override fun previewPolicyRelease(policyHandle: Long) =
                SheetMusicAudioJNI.nativePreviewPolicyRelease(policyHandle)
            override fun previewPolicyBegin(
                policyHandle: Long,
                channel: Int,
                pitch: Int,
                velocity: Int,
                isDrum: Boolean,
                ringMilliseconds: Int,
            ) = SheetMusicAudioJNI.nativePreviewPolicyBegin(
                policyHandle, channel, pitch, velocity, isDrum, ringMilliseconds,
            )
            override fun previewPolicyEnd(policyHandle: Long, generation: Long) =
                SheetMusicAudioJNI.nativePreviewPolicyEnd(policyHandle, generation)
            override fun previewPolicySilence(policyHandle: Long) =
                SheetMusicAudioJNI.nativePreviewPolicySilence(policyHandle)
            override fun masterTuningControlChanges(cents: Double) =
                SheetMusicAudioJNI.nativeMasterTuningControlChanges(cents)
        }
    }

    /** Public production constructor — uses [defaultBridge] and real sub-components. */
    constructor(
        context: Context,
        soundfontResolver: SoundfontResolver,
        metronomeClickProvider: MetronomeClickProvider? = null,
    ) : this(
        context = context,
        soundfontResolver = soundfontResolver,
        metronomeClickProvider = metronomeClickProvider,
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

    /**
     * The transport's position paired with the device's AUDIO clock, or `null` when the output
     * cannot supply a timestamp (before playback starts, after teardown, or on a route that does
     * not report one — `AudioTrack.getTimestamp` is best-effort by contract).
     *
     * A read, deliberately, and not a flow: [currentTimeSeconds] is written from a 33 ms poll, so
     * its value is stale by an unknown fraction of that interval whenever a host looks at it. This
     * asks the audio output where it actually is AT THE MOMENT OF THE CALL, so a host smoothing a
     * playhead can extrapolate from `nanoTime` rather than from whenever the poll last fired.
     * Publishing it as a flow would put it back on the poll's cadence and lose the whole point.
     *
     * Purely additive: [currentTimeSeconds] and [currentCursor] are untouched and a host that never
     * calls this behaves exactly as before.
     */
    fun audioClockPosition(): AudioClockPosition? {
        val sample = oboeStream?.audioTimestamp() ?: return null
        val tick = playerDriver?.currentTick ?: return null
        return AudioClockPosition(
            unrolledTick = tick,
            framePosition = sample.framePosition,
            nanoTime = sample.nanoTime,
        )
    }

    // ── Internal mutable state (assembled by prepare) ────────────────

    private val prepareMutex = Mutex()
    private val exportMutex = Mutex()
    private var scoreHandle: Long = 0
    private var totalTicks: Long = 0
    /**
     * Length of the UNROLLED sequence (repeats + jumps expanded) — the tick
     * space the FluidSynth player actually traverses. End-of-score detection
     * in the poll loop compares the player tick against THIS, not the shorter
     * notated [totalTicks], so a repeat's second pass or a D.C./D.S. jump does
     * not stop playback early. Falls back to [totalTicks] for an older native
     * bridge that doesn't report it.
     */
    private var unrolledTotalTicks: Long = 0
    /** Ticks-per-beat from the prepared score's timeline; required by export. */
    private var ticksPerBeat: Int = 480
    /**
     * Live MIDI channel per flat staff index — the staff's part's PRIMARY
     * (ordinal-0) strip, for auditioning a [playPreview] note on the
     * instrument actually configured on the synth. Populated in [prepare];
     * empty otherwise. Not staff-index-identity (see [MixerChannel]).
     */
    private var staffLiveChannel: IntArray = IntArray(0)

    /**
     * Whether each flat staff plays on the percussion bank. Populated in [prepare] alongside
     * [staffLiveChannel]; empty otherwise.
     *
     * Read only by [playPreview], because a drum audition is not over when a melodic one would be — a
     * cymbal's musical value is its decay. How much longer is the shared policy's answer, not this file's.
     */
    private var staffIsDrums: BooleanArray = BooleanArray(0)

    /**
     * Handle to this engine's audition policy in shared Swift, or 0 before [prepare] / after [teardown].
     *
     * Created in [prepare] rather than at construction so the first native call still happens where every
     * other one does — an engine can be constructed in contexts that never load the library.
     */
    @Volatile private var previewPolicyHandle: Long = 0L
    private var fluidSynthEngine: FluidSynthEngine? = null
    private var playerDriver: PlayerDriver? = null
    private var oboeStream: OboeStream? = null
    private var metronomeMixer: MetronomeMixer? = null
    private val clickResolver by lazy {
        AndroidMetronomeClickResolver(metronomeClickProvider, jniBridge)
    }
    private var pollJob: Job? = null
    // Scopes are lazy so pollDispatcher is captured after construction.
    private val pollScope by lazy { CoroutineScope(SupervisorJob() + pollDispatcher) }
    private val previewScope by lazy { CoroutineScope(SupervisorJob() + pollDispatcher) }

    /**
     * Where the score transport will resume from — the tick the metronome's transport has to be started
     * at so the two run together.
     *
     * Not read from the player: `fluid_player_seek` only records the request and applies it inside the
     * player's render callback, so `currentTick` still reports the pre-seek position until playback is
     * actually running again. Every path that repositions a stopped player updates this instead: seek,
     * skip, stop, the loop wrap, and pause (which captures the live tick while it is still accurate).
     */
    @Volatile private var scoreTickIntent: Long = 0L

    /**
     * How far the click transport runs ahead of the score's, in ticks: the length of the count-in
     * region currently sitting at the head of its sequence, or 0 when it is playing the plain body
     * sequence. Every seek of the metronome adds it.
     */
    @Volatile private var metronomeTickOffset: Long = 0L

    /** The plain (count-in-free) click sequence, kept so a count-in play can be undone. */
    private var bodyMetronomeSmf: ByteArray = ByteArray(0)

    @Volatile private var masterVolume: Float = 1.0f

    /**
     * Master output stage and level handler, held here as well as on the stream because [prepare]
     * builds a NEW [OboeStream] every time — a host that set either once would otherwise silently
     * lose it the next time a score is adopted.
     */
    @Volatile private var masterOutputStage: MasterOutputStage = MasterOutputStage.NONE

    @Volatile private var levelHandler: ((MixLevel) -> Unit)? = null

    private val _isPreparingSoundfont = MutableStateFlow(false)

    /**
     * True while [prepare] or [reloadSoundfont] is loading SoundFont data.
     *
     * A large SF2 takes visible time to load, and until this flow existed a host had no way to tell
     * "still loading" from "loaded and silent" — so the only honest UI was no UI. Mirrors Apple's
     * `PlaybackEngine.isPreparingSoundfont`.
     */
    val isPreparingSoundfont: StateFlow<Boolean> = _isPreparingSoundfont.asStateFlow()
    @Volatile private var pendingRate: Float = 1.0f
    @Volatile private var masterTuningCents: Double = 0.0

    /** Live whole-score transpose (−12…+12). Combined with [masterTuningCents] by `applyTuning`. */
    @Volatile private var transposeSemitones: Int = 0

    /**
     * Whether `play()` first counts in a measure of clicks. Off by default, and persists across
     * prepare so the host only has to push the user's setting once.
     */
    @Volatile var countInEnabled: Boolean = false

    /** The in-flight pre-roll, if any. Non-null only between `play()` and the score actually starting. */
    private var countInJob: Job? = null

    /**
     * Count of in-flight previews that started the Oboe output stream while the
     * engine was idle/paused. The last one to drain restores the stream to its
     * stopped state. See [playPreview].
     */
    private val previewStreamHolders = AtomicInteger(0)

    // ── prepare ──────────────────────────────────────────────────────

    /**
     * Loads score data from the Swift bridge, creates the single FluidSynth
     * engine and assigns per-strip channels, initializes the player and
     * stream, and transitions to [PlaybackState.PREPARED].
     *
     * @param scoreHandle opaque handle obtained from the JNI score-loading API.
     * @throws AudioBackendException.InvalidScoreHandle if the timeline summary is malformed.
     * @throws AudioBackendException.EmptyScore if the score has no staves.
     * @throws AudioBackendException.TooManyStaves if the score has more than 16 staves.
     */
    suspend fun prepare(scoreHandle: Long) = prepareMutex.withLock {
        _isPreparingSoundfont.value = true
        try {
            prepareLocked(scoreHandle)
        } finally {
            // In a `finally` because the flag's whole job is telling a host whether to show a
            // spinner: leaving it stuck true after a failed prepare (a missing SF2, an invalid
            // handle) would leave that spinner up forever, which is a worse failure than the one
            // that caused it.
            _isPreparingSoundfont.value = false
        }
    }

    /**
     * Swap the SoundFont source and reload the current score's instruments with it.
     *
     * The resolver used to be fixed at construction, so changing SoundFont meant tearing the engine
     * down and building a new one — losing the transport position, the loop, and every mixer
     * setting the user had made. Mirrors Apple's `PlaybackEngine.reloadSoundfont(resolver:)`.
     *
     * A no-op before the first [prepare]: with no score adopted there is nothing to reload, and the
     * new resolver is simply the one the next [prepare] will use.
     *
     * Reloading rebuilds the synth, so it stops playback — a running player holding voices from the
     * old bank cannot be handed a new one mid-note. The caller re-starts.
     */
    suspend fun reloadSoundfont(resolver: SoundfontResolver) = prepareMutex.withLock {
        soundfontResolver = resolver
        val handle = scoreHandle
        if (handle == 0L) return@withLock
        _isPreparingSoundfont.value = true
        try {
            prepareLocked(handle)
        } finally {
            _isPreparingSoundfont.value = false
        }
    }

    private suspend fun prepareLocked(scoreHandle: Long) =
        withContext(Dispatchers.IO) {
            _loopRange.value = null
            transportLoop = null
            val summary = jniBridge.timelineSummary(scoreHandle)
            if (summary.size < 3) throw AudioBackendException.InvalidScoreHandle()
            totalTicks = summary[0]
            val totalSecs = summary[1] / 1_000_000.0
            ticksPerBeat = summary[2].toInt()
            // Native bridge appends the unrolled length as summary[3];
            // fall back to the notated total for an older bridge.
            unrolledTotalTicks = if (summary.size > 3) summary[3] else totalTicks

            val staffBytes = jniBridge.staffParams(scoreHandle)
            val staves = run {
                val r = BinaryReader(staffBytes)
                val out = ArrayList<StaffParams>()
                r.readLengthPrefixed { inner ->
                    while (inner.remaining > 0) {
                        out.add(inner.readLengthPrefixed { StaffParamsCodec.decodePayload(it) })
                    }
                }
                out
            }
            if (staves.isEmpty()) throw AudioBackendException.EmptyScore()
            if (staves.size > 16) throw AudioBackendException.TooManyStaves(staves.size)

            // One entry per deduped (part × instrument) mixer strip — the
            // Android mirror of Apple's `LiveChannelPlan`.
            val decodedStrips = decodeInstrumentParams(scoreHandle)
            val strips = stripsOrFallback(decodedStrips, staves)
            // `strips.size` — NOT `staves.size` — is what actually gets
            // handed to `FluidSynthEngine.setupStaves` below (one entry
            // per live channel, not per staff), so it is the quantity that
            // must stay within the single-synth 16-channel limit.
            // `FluidSynthEngine.setupStaves` has its own `require(...)` for
            // this, but that throws a raw `IllegalArgumentException`
            // instead of this method's documented `TooManyStaves` — check
            // here first so the typed exception wins.
            if (strips.size > 16) throw AudioBackendException.TooManyStaves(strips.size)
            // Per-staff live channel for `playPreview`: the staff's PART's
            // primary (ordinal-0) strip. Only meaningful when the real
            // `instrumentParams` bridge populated `strips` with genuine
            // `StaffParams.partIndex`-keyed data — the synthetic fallback
            // above already used `staffIndex` as its own liveChannel, so
            // reading it back through the same join is equivalent there too.
            val partToPrimaryChannel = strips.filter { it.ordinal == 0 }
                .associate { it.partIndex to it.liveChannel }
            this@AndroidPlaybackEngine.staffLiveChannel = IntArray(staves.size) { i ->
                if (decodedStrips.isNotEmpty()) {
                    partToPrimaryChannel[staves[i].partIndex] ?: staves[i].staffIndex
                } else {
                    staves[i].staffIndex
                }
            }
            this@AndroidPlaybackEngine.staffIsDrums = BooleanArray(staves.size) { staves[it].isDrums }
            if (previewPolicyHandle == 0L) previewPolicyHandle = jniBridge.previewPolicyCreate()
            // A re-prepare lands on a different score and a fresh synth; an audition planned against the
            // previous one must not be ended against this one.
            jniBridge.previewPolicySilence(previewPolicyHandle)

            val metronomeSmfBytes = jniBridge.renderMetronomeMidi(scoreHandle)

            val smfBytes = jniBridge.renderMidi(scoreHandle)
            if (smfBytes.isEmpty()) throw AudioBackendException.InvalidScoreHandle()

            // Tear down any prior prepared state before recreating.
            teardownInternalNoCancelScopes()

            // Single fluid_synth_t, one channel per STRIP (not per staff) —
            // keyed on each strip's live MIDI channel, which is what the
            // rendered SMF (remapped via `LiveChannelPlan` on the Swift
            // side) actually addresses. `StaffParams` is reused here purely
            // as a generic (channel, bank, program, isDrums) load spec —
            // `FluidSynthEngine` never interprets the "staffIndex" field as
            // anything but a raw MIDI channel number.
            val engine = FluidSynthEngine(
                synthFactory,
                masterTuningControlChanges = {
                    MidiControlChangeCodec.decode(jniBridge.masterTuningControlChanges(it))
                },
            )
            val channelLoadParams = strips.map { s ->
                StaffParams(
                    staffIndex = s.liveChannel,
                    bankLSB = s.bankLSB,
                    program = s.program,
                    isDrums = s.isDrums,
                    partAddressHash = 0L,
                )
            }
            engine.setupStaves(channelLoadParams, soundfontResolver, context)
            // Re-apply the combined calibration + transpose offset: a fresh synth starts at concert
            // pitch, so a score opened while either is non-zero would otherwise play untransposed.
            if (effectiveTuningCents != 0.0) engine.setMasterTuning(effectiveTuningCents)
            this@AndroidPlaybackEngine.fluidSynthEngine = engine
            // Seed each strip's channel volume into the synth from the score's CC 7. The rendered SMF
            // no longer carries CC 7 on mixer-managed channels (stripped in the shared
            // MidiSynthPostProcess so the live mixer is the sole authority), so the synth must be told
            // the score's volume here; otherwise every strip would play at FluidSynth's default. Because
            // no tick-0 CC 7 fires when the player starts, a volume the user sets *before* the first play
            // now survives — matching iOS, where applyMixerState owns CC 7 and the SMF's is stripped.
            strips.forEach { s ->
                engine.setChannelVolume(s.liveChannel, s.channelVolume.toInt().coerceIn(0, 127) / 127f)
            }

            // Dedicated metronome synth on a separate fluid_synth_t. The
            // click sound comes from the provider: .clickSamples builds an
            // SF2 from the host's WAVs (via JNI), .soundFont uses a host SF2,
            // .defaultGM / no provider falls back to the GM drum-kit.
            val metronomeSynth = synthFactory(48_000)
            MetronomeSf2Loader.load(
                metronomeSynth, clickResolver.resolve(), soundfontResolver, context,
            )
            // Its own player, over the metronome-only SMF. Scheduling the clicks on a transport (rather
            // than firing them by hand) is what keeps them on the beat; see [MetronomeMixer].
            bodyMetronomeSmf = metronomeSmfBytes
            metronomeTickOffset = 0L
            metronomeMixer = MetronomeMixer(metronomeSynth) { smf ->
                val p = playerFactory(metronomeSynth.nativeHandle)
                if (p.load(smf) == 0) p else { p.close(); null }
            }.also {
                it.loadSequence(metronomeSmfBytes)
                it.setTempo(pendingRate.toDouble())
            }

            // PlayerDriver wired to the real fluid_synth_t handle.
            // fluid_player's default routing uses event.channel directly —
            // the Swift bridge already remaps SMF channels onto the live
            // single-port channel set (`AudioMidiBridge.renderMidi`, via
            // `LiveChannelPlan` + `MidiChannelRemap`), which is exactly the
            // channel set `channelLoadParams` above programs, so per-strip
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
            // Re-apply the master settings this engine holds. `prepare` builds a new stream each
            // time, so a host that set the gain, the output stage or a level meter once would
            // otherwise lose all three the next time a score is adopted — silently, and only
            // audibly on the next score.
            oboe.setMasterVolume(masterVolume)
            oboe.setMasterOutputStage(masterOutputStage)
            levelHandler?.let { oboe.startLevelMonitoring(it) }
            oboe.setProducer { frameCount, left, right ->
                val eng = this@AndroidPlaybackEngine.fluidSynthEngine
                if (eng == null) {
                    for (i in 0 until frameCount) { left[i] = 0f; right[i] = 0f }
                    return@setProducer
                }
                eng.writeFloat(frameCount, left, right)
                val mm = this@AndroidPlaybackEngine.metronomeMixer
                if (mm != null && mm.isAudible) {
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
            _mixerChannels.value = strips.map { s ->
                // Seed the slider from the score's authored channel volume (CC7 → 0..1),
                // matching iOS where the mixer opens at the part's notated volume rather
                // than a flat 100%. The SMF stream already carries these CC7 values, so
                // this only aligns the displayed/reset value with what actually plays.
                val initialVolume = s.channelVolume.toInt().coerceIn(0, 127) / 127f
                MixerChannel(
                    partIndex = s.partIndex,
                    ordinal = s.ordinal,
                    liveChannel = s.liveChannel,
                    // Shared Swift derivation (part label, plus the instrument in
                    // parens for a genuine secondary instrument), matching the
                    // iOS mixer. Falls back to a generic label if an older
                    // bridge / the synthesized fallback left it empty.
                    displayName = s.displayName.ifEmpty { "Part ${s.partIndex + 1}" },
                    volume = initialVolume,
                    defaultVolume = initialVolume,
                    // Drum strips carry their program too — there it is the percussion-bank kit
                    // number, which a host needs in order to show the kit picker. `isDrums` is
                    // what distinguishes the two catalogs now.
                    program = s.program.toInt(),
                    isDrums = s.isDrums,
                )
            }
            _totalTimeSeconds.value = totalSecs
            _currentTimeSeconds.value = 0.0
            _currentCursor.value = null
            _currentRate.value = pendingRate
            // Freshly loaded players sit at tick 0.
            scoreTickIntent = 0L
            _state.value = PlaybackState.PREPARED
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
        // A play() while a pre-roll is already counting restarts it rather than stacking a second one.
        cancelCountIn()
        // Any shift a previous count-in left on the click transport belongs to that play's start
        // position, not this one's.
        restoreBodyMetronomeSequence()
        oboeStream?.play()

        val countIn = beginCountInOrNull()
        if (countIn == null) {
            player.play()
            // The click transport starts from the same tick as the score's, and from here on the two
            // advance together — each is driven by its own synth's rendering, off the same tempo map.
            metronomeMixer?.start(scoreTickIntent)
            _state.value = PlaybackState.PLAYING
            startPollJob()
            return
        }

        // The state flips to PLAYING for the whole count-in: the transport is "running" from the
        // reader's point of view, and pause() during the clicks has to be able to cancel it. The score
        // itself only starts once the pre-roll has played out (see [countInJob]).
        _state.value = PlaybackState.PLAYING
        // Open the metronome's mix path for the pre-roll. Loading the clicks is not enough on its own:
        // the render loop skips the metronome synth entirely while it is inaudible, so with the
        // metronome switched off the count-in would play into a buffer nobody sums — and, because the
        // transport only advances while it is rendered, would not play at all.
        val mixer = metronomeMixer
        mixer?.isCountingIn = true
        mixer?.start(0L)
        countInJob = pollScope.launch {
            try {
                // The clicks are events in the click transport's own sequence, so their spacing is the
                // audio clock's, not this loop's. All this waits for is the handover: the pre-roll's
                // last tick, at which the music takes over. Polling tightly keeps that one event close
                // — the beats themselves no longer care how promptly we wake up.
                //
                // Bounded by wall time as well, so a transport that never advances (an output stream
                // that failed to start, a sequence the player rejected) leaves the user with playback
                // that begins late rather than playback that never begins.
                var waited = 0L
                val deadline = countIn.timeoutMillis
                while ((mixer?.currentTick ?: Long.MAX_VALUE) < countIn.preRollTicks &&
                    waited < deadline
                ) {
                    delay(COUNT_IN_HANDOVER_POLL_MILLIS)
                    waited += COUNT_IN_HANDOVER_POLL_MILLIS
                }
                countInJob = null
                player.play()
                startPollJob()
            } finally {
                // `finally`, so a cancelled pre-roll (pause / stop / seek / restart) also closes the mix
                // path instead of leaving the metronome permanently audible.
                metronomeMixer?.isCountingIn = false
            }
        }
    }

    /**
     * Loads the count-in's click sequence and returns the tick at which the music takes over, or null
     * when this play should start immediately (the setting is off, no score, no click transport, or the
     * position has no count-in).
     *
     * The pre-roll is a region at the head of the METRONOME's sequence, with the body's clicks shifted
     * behind it; the score's own sequence is untouched and simply starts late. That leaves the click
     * transport running [metronomeTickOffset] ticks ahead of the score's for the rest of this play.
     */
    private fun beginCountInOrNull(): CountInHandover? {
        if (!countInEnabled) return null
        val mixer = metronomeMixer ?: return null
        val handle = scoreHandle.takeIf { it != 0L } ?: return null
        val cursor = _currentCursor.value ?: ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val cursorBytes = ScoreCursorCodec.encode(cursor)
        val schedule = runCatching {
            CountInWireCodec.decode(jniBridge.countIn(handle, cursorBytes))
        }.getOrNull() ?: return null
        if (schedule.preRollTicks <= 0 || schedule.beats.isEmpty()) return null
        val smf = jniBridge.renderCountInMetronomeMidi(handle, cursorBytes, scoreTickIntent)
        if (smf.isEmpty()) return null
        mixer.loadSequence(smf)
        metronomeTickOffset = schedule.preRollTicks.toLong()
        val rate = pendingRate.toDouble().coerceAtLeast(0.01)
        return CountInHandover(
            preRollTicks = metronomeTickOffset,
            // Twice the pre-roll's own length plus a second: long enough never to cut a healthy count-in
            // short, short enough that a stalled transport doesn't strand playback.
            timeoutMillis = ((schedule.totalSeconds / rate) * 2000.0).toLong() + 1000L,
        )
    }

    /** What the count-in's job waits for: the click transport's tick, with a wall-clock backstop. */
    private data class CountInHandover(val preRollTicks: Long, val timeoutMillis: Long)

    /**
     * Puts the click transport back on the plain body sequence, undoing a count-in's shift. Called
     * before anything that repositions playback, because the count-in sequence drops everything before
     * the tick it was built for — seeking back into that region would leave the metronome silent.
     */
    private fun restoreBodyMetronomeSequence() {
        if (metronomeTickOffset == 0L) return
        metronomeTickOffset = 0L
        metronomeMixer?.loadSequence(bodyMetronomeSmf)
    }

    /**
     * Cancels an in-flight count-in. Called from `play` (restart), `pause`, `stop` and `seek`: in every
     * one of those the position or the transport state is changing out from under the pre-roll, and a
     * surviving job would start the player after the user had already stopped it.
     */
    private fun cancelCountIn() {
        countInJob?.cancel()
        countInJob = null
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
        // Capture the position while the player's own tick is still live — after this it stops advancing
        // and a later seek would not be reflected in it, so this is what the next play() resumes from.
        // Only once the score has actually started: pausing mid-count-in must keep the start position
        // the pre-roll was counting into, which the not-yet-started player does not know.
        if (countInJob == null) playerDriver?.let { scoreTickIntent = it.currentTick }
        cancelCountIn()
        playerDriver?.stop()
        metronomeMixer?.stop()
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
        cancelCountIn()
        playerDriver?.stop()
        playerDriver?.seekTick(0L)
        scoreTickIntent = 0L
        metronomeMixer?.stop()
        restoreBodyMetronomeSequence()
        metronomeMixer?.seekTick(0L)
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
        // Same scale on the click transport, or the metronome would drift away from the music.
        metronomeMixer?.setTempo(rate.toDouble())
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
        // `frame.tick` and the loop are NOTATED; the player and the click transport are not.
        val snapped = unrolledTick(forNotated = snapTickToLoop(frame.tick))
        fluidSynthEngine?.allNotesOff()
        player.seekTick(snapped)
        scoreTickIntent = snapped
        // The count-in sequence only covers the region from the tick it was built for; leave it before
        // repositioning so a seek can't land somewhere it has no clicks.
        restoreBodyMetronomeSequence()
        repositionMetronome(snapped)
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
        // `total` and `totalTicks` are both NOTATED, so this estimate is a notated tick — but
        // `frameAtTick` takes the player's UNROLLED coordinates, so it has to be projected first.
        val targetTickEstimate = if (total > 0) {
            unrolledTick(forNotated = (target / total * totalTicks).toLong())
        } else 0L
        val frameBytes = jniBridge.frameAtTick(scoreHandle, targetTickEstimate)
        val frame = if (frameBytes.isEmpty()) null else FrameCodec.decode(frameBytes)
        frame ?: return
        // Back the other way: the frame's tick and the loop are notated, the player is not.
        val snapped = unrolledTick(forNotated = snapTickToLoop(frame.tick))
        fluidSynthEngine?.allNotesOff()
        player.seekTick(snapped)
        scoreTickIntent = snapped
        // The count-in sequence only covers the region from the tick it was built for; leave it before
        // repositioning so a seek can't land somewhere it has no clicks.
        restoreBodyMetronomeSequence()
        repositionMetronome(snapped)
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
        armLoop(LoopRange(startTick = fromFrame.tick, endTick = toFrame.tick))
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
        armLoop(LoopRange(startTick = fromFrame.tick, endTick = endTick))
    }

    /**
     * Loop measures `[fromMeasure, toMeasure]` inclusive. Resolves each measure head to a tick via
     * the timeline. The loop end is the onset tick of measure `(toMeasure + 1)`; if that beat does
     * not resolve (i.e. `toMeasure` is the last measure) the end falls back to [totalTicks] so the
     * final measure loops through its full duration. No-op when [state] is [PlaybackState.EXPORTING],
     * when no player is prepared, when the start beat doesn't resolve, or when the resolved range is
     * empty. Mirrors Apple `LivePlaybackController` loop-bounds resolution.
     */
    fun setLoopMeasures(fromMeasure: Int, toMeasure: Int) {
        if (_state.value == PlaybackState.EXPORTING) return
        if (playerDriver == null) return
        val fromBytes = jniBridge.frameForCursor(
            scoreHandle,
            ScoreCursorCodec.encode(ScoreCursor.Beat(fromMeasure, 0)),
        )
        val fromFrame = if (fromBytes.isEmpty()) null else FrameCodec.decode(fromBytes)
        fromFrame ?: return
        val endBytes = jniBridge.frameForCursor(
            scoreHandle,
            ScoreCursorCodec.encode(ScoreCursor.Beat(toMeasure + 1, 0)),
        )
        val endTick = if (endBytes.isEmpty()) totalTicks else FrameCodec.decode(endBytes).tick
        if (fromFrame.tick >= endTick) return
        armLoop(LoopRange(startTick = fromFrame.tick, endTick = endTick))
    }

    /**
     * Loop the entire prepared score `[0, totalTicks)`. No-op when [state] is
     * [PlaybackState.EXPORTING], when no player is prepared, or when the timeline is empty.
     */
    fun setLoopFullScore() {
        if (_state.value == PlaybackState.EXPORTING) return
        if (playerDriver == null || totalTicks <= 0) return
        armLoop(LoopRange(startTick = 0, endTick = totalTicks))
    }

    /**
     * Disable looping. The next poll cycle stops snapping the playhead back
     * to startTick, so playback continues past the previous loop end.
     */
    fun clearLoop() {
        if (_state.value == PlaybackState.EXPORTING) return
        _loopRange.value = null
        transportLoop = null
    }

    /**
     * The active loop expressed in the TRANSPORT's own coordinates.
     *
     * [LoopRange] is a region of the SCORE, so [loopRange] stores — and hands the host — NOTATED
     * ticks; that is what the host persists and what it maps back through its own measure table.
     * The transport, though, runs the UNROLLED render, where the same bar sits at one position per
     * pass and generally at none of its notated ticks. Every comparison against a polled player
     * position, and every seek that answers one, uses this instead.
     */
    private data class TransportLoop(
        /** Unrolled tick of the loop's start — its FIRST occurrence in playback order. */
        val startTick: Long,
        /**
         * Exclusive unrolled end, derived as `startTick + notated span` rather than by projecting
         * the notated end tick on its own: within one measure-play the region is contiguous and
         * slope-1, whereas the end tick's own first occurrence can belong to a LATER pass — a loop
         * over a repeated bar would then swallow the repeat's second take.
         */
        val endTick: Long,
    )

    @Volatile private var transportLoop: TransportLoop? = null

    /** Store [range] as the score-space loop and cache its projection onto the transport. */
    private fun armLoop(range: LoopRange) {
        _loopRange.value = range
        val start = unrolledTick(forNotated = range.startTick)
        transportLoop = TransportLoop(
            startTick = start,
            endTick = start + (range.endTick - range.startTick),
        )
    }

    /**
     * The UNROLLED transport tick a NOTATED score tick sits at. Identity when no score is prepared
     * or the native bridge declines the projection (see [JniBridge.unrolledTickForNotated]), which
     * is what this engine did before the projection existed and stays correct without a repeat.
     */
    private fun unrolledTick(forNotated: Long): Long {
        if (scoreHandle == 0L || forNotated < 0) return forNotated
        val projected = jniBridge.unrolledTickForNotated(scoreHandle, forNotated)
        return if (projected < 0) forNotated else projected
    }

    /**
     * Moves the metronome's transport to [tick], restarting it when the score is running.
     *
     * The restart matters at the end of the click track: the metronome sequence ends one tick after the
     * last click, so a loop whose region reaches the end of the score leaves the click transport finished
     * — and a finished `fluid_player` ignores a bare seek. Re-playing it revives it on the wrap. While
     * paused or stopped the seek alone is what we want; starting it there would click over the silence.
     */
    private fun repositionMetronome(tick: Long) {
        val mixer = metronomeMixer ?: return
        val metronomeTick = tick + metronomeTickOffset
        if (_state.value == PlaybackState.PLAYING && countInJob == null) {
            mixer.start(metronomeTick)
        } else {
            mixer.seekTick(metronomeTick)
        }
    }

    /**
     * Clamp [tick] into the active loop, or return it unchanged.
     *
     * NOTATED in and notated out: its callers hand it a frame's tick and go on to look the result up
     * on the notated timeline, so the comparison belongs on [loopRange] rather than on the
     * transport's projection. Projecting to the player's coordinates is the caller's next step.
     */
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
        // Audition the instrument actually configured on the synth for this
        // staff's part — its PRIMARY (ordinal-0) live channel — not the raw
        // staffIndex, which is no longer the same as a channel number once a
        // score has a drum part, a grand staff, or a mid-score instrument
        // change (see `staffLiveChannel`, populated in `prepare`).
        val liveChannel = staffLiveChannel.getOrElse(staffIndex) { staffIndex }

        // What this audition does — whether it supersedes one already sounding, how long it rings, how long
        // the graph has to stay alive after it — is decided by the shared policy. See `JniBridge`.
        val planBytes = jniBridge.previewPolicyBegin(
            policyHandle = previewPolicyHandle,
            channel = liveChannel,
            pitch = pitch,
            velocity = velocity,
            isDrum = staffIsDrums.getOrElse(staffIndex) { false },
            ringMilliseconds = durationMillis.toInt(),
        )
        if (planBytes.isEmpty()) return
        val plan = PreviewPlanCodec.decode(planBytes)

        // The Oboe output driver pulls samples only while it's running — it is
        // started in play() and stopped in pause() / stop(). When we're idle or
        // paused the stream is open but not running, so previewNoteOn() would
        // queue a note nobody pulls → silence. Start the stream for the preview
        // (no-op if already running) and restore the host's paused/idle state
        // after the note drains, so the audio-focus / MediaSession behavior that
        // pause() established (the reason it stops the stream) is preserved.
        val startedStreamForPreview = _state.value != PlaybackState.PLAYING
        if (startedStreamForPreview) {
            previewStreamHolders.incrementAndGet()
            oboeStream?.play()
        }

        // Silencing the superseded note by its own (channel, pitch) rather than Apple's CC 120 on a foreign
        // channel is a deliberate difference in the MESSAGE, not in the behaviour the policy describes. Apple's
        // branch works around AUMIDISynth swallowing a CC 120 sent immediately before a note-on on the same
        // channel; FluidSynth needs no such workaround, and a plain note-off is both more precise — it silences
        // exactly the note this engine started — and gentler, since it lets the release envelope run.
        if (plan.supersedesChannel >= 0) {
            engine.previewNoteOff(plan.supersedesChannel, plan.supersedesPitch)
        }
        previewSilentAtNanos = System.nanoTime() +
            (plan.ringMilliseconds + plan.releaseTailMilliseconds).toLong() * 1_000_000L

        engine.previewNoteOn(plan.channel, plan.pitch, plan.velocity)
        previewScope.launch {
            delay(plan.ringMilliseconds.toLong())
            // -1 means a newer audition has taken this one's place and already silenced it; ending it again
            // would silence the NEWER note instead. The stream hold is still released below, because this
            // call took one out.
            val ending = jniBridge.previewPolicyEnd(previewPolicyHandle, plan.generation)
            if (ending >= 0) {
                engine.previewNoteOff((ending shr 8).toInt(), (ending and 0xFF).toInt())
            }
            if (!startedStreamForPreview) return@launch
            // Keep the output stream open for the note's release before parking it again. That stream is what
            // RENDERS the release: stopping it the instant the note-off is sent truncates the tail into a click,
            // which is what a single audition in an idle Reader sounded like. The span is the policy's
            // `releaseTailMilliseconds`, and the Apple engine defers its own graph park across the same one.
            //
            // The hold is released only after that wait, so one hold covers a note AND its tail. A preview
            // arriving during the tail therefore takes its own hold, which both keeps the stream running and
            // hands the park obligation to the newer note — no generation check is needed here to get that.
            delay(plan.releaseTailMilliseconds.toLong())
            if (previewStreamHolders.decrementAndGet() == 0 && _state.value != PlaybackState.PLAYING) {
                oboeStream?.stop()
            }
        }
    }

    /**
     * How much longer a preview will be audible in milliseconds — its remaining ring time plus the release
     * tail — or `0` when none is sounding.
     *
     * For a host that has to STOP this engine to do something else: Folino re-prepares it to adopt an edited
     * score, and stopping it silences whatever preview the edit itself just started. Acting the instant the
     * edit lands therefore cut the user's own audition off a frame in. The answer belongs here rather than in
     * the caller's copy of the preview duration, because the tail is this engine's business and the caller
     * has no way to know it.
     */
    fun millisUntilPreviewSilent(): Long =
        ((previewSilentAtNanos - System.nanoTime()) / 1_000_000L).coerceAtLeast(0L)

    /**
     * `System.nanoTime()` at which the preview started by the last [playPreview] falls silent.
     *
     * A monotonic reading rather than a wall clock, and deliberately not the test scheduler's virtual time:
     * its one reader is a host deciding how long to wait in real time.
     */
    @Volatile
    private var previewSilentAtNanos: Long = 0L

    /**
     * The sustained preview note currently held, as `(staffIndex, channel, pitch)`, or `null`.
     *
     * Only one at a time, matching Apple's `activeSustainedPreview`: the note shares the staff's own
     * sequencer channel, so two held notes on one staff would fight over it.
     */
    private var sustainedPreview: Triple<Int, Int, Int>? = null

    /**
     * Start a **sustained** preview note on [flatStaffIndex]'s own MIDI channel — the mixer-selected
     * program and the synth's global tuning, exactly like [playPreview], but held until
     * [previewNoteOff] or a superseding [previewNoteOn].
     *
     * This is what a note-input UI needs and [playPreview] cannot give it: a key held down should
     * sound for as long as it is held, not for a fixed 300 ms. The engine has had the capability all
     * along — [FluidSynthEngine.previewNoteOn] is what [playPreview] itself calls — it was simply
     * never public.
     *
     * Intended for use while stopped or paused (the caller gates this); a held note shares the
     * staff's channel and is not meant to overlap live playback, so this is a no-op while playing or
     * exporting. Resumes a parked output stream and re-parks it on the matching note-off, the same
     * way [playPreview] does — without that the note would be queued for a stream nobody is pulling
     * from, and sound like nothing at all.
     */
    fun previewNoteOn(pitch: Int, onStaff: Int, velocity: Int = 96) {
        if (_state.value == PlaybackState.EXPORTING || _state.value == PlaybackState.PLAYING) return
        val engine = fluidSynthEngine ?: return
        val liveChannel = staffLiveChannel.getOrElse(onStaff) { onStaff }

        // A pending fixed-duration audition must not be cut by this note's own start, and must not
        // pause the stream underneath a held note. Silencing it through the shared policy is what
        // transfers the stream hold rather than double-counting it.
        val silenced = jniBridge.previewPolicySilence(previewPolicyHandle)
        if (silenced >= 0) {
            engine.previewNoteOff((silenced shr 8).toInt(), (silenced and 0xFF).toInt())
        }

        // Only one sustained note at a time — cut the previous one first.
        sustainedPreview?.let { (_, channel, heldPitch) -> engine.previewNoteOff(channel, heldPitch) }
        sustainedPreview = null

        // The hold is taken BEFORE the note sounds, and released by the matching note-off. A
        // `playPreview` arriving during the hold takes its own, so the stream stays up for both.
        previewStreamHolders.incrementAndGet()
        oboeStream?.play()

        engine.previewNoteOn(liveChannel, pitch, velocity)
        sustainedPreview = Triple(onStaff, liveChannel, pitch)
    }

    /**
     * Stop the sustained preview note for [pitch]. A no-op unless it is the note currently held —
     * so a stale note-off from a key released after a superseding press cannot silence the newer
     * note.
     *
     * Releases the stream hold [previewNoteOn] took and re-parks the output stream when nothing
     * else is holding it and playback is not running.
     */
    fun previewNoteOff(pitch: Int) {
        val held = sustainedPreview ?: return
        if (held.third != pitch) return
        sustainedPreview = null
        fluidSynthEngine?.previewNoteOff(held.second, pitch)
        if (previewStreamHolders.decrementAndGet() == 0 && _state.value != PlaybackState.PLAYING) {
            oboeStream?.stop()
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
     * Sets the master output gain. Propagates to [OboeStream.setMasterVolume].
     *
     * **Not capped at 1.0**, matching Apple's `PlaybackEngine.setMasterGain`. How loud playback
     * should be depends on the SoundFont's own output level and on what the host is trying to sound
     * like, neither of which this engine can judge — a host calibrating a quiet bank against a
     * louder reference can legitimately need more than unity, and being refused leaves it with no
     * recourse. What a large boost does past full scale is [setMasterOutputStage]'s business: by
     * default nothing, so the gain reaches the output device as given.
     *
     * Negative values are clamped to zero.
     */
    fun setMasterGain(gain: Float) {
        val clamped = gain.coerceAtLeast(0f)
        masterVolume = clamped
        oboeStream?.setMasterVolume(clamped)
    }

    /**
     * Sets the master output volume.
     *
     * Kept as the name every existing host already calls, now delegating to [setMasterGain]. The
     * rename matters because the old name promised a 0..1 volume control and the new one does not
     * cap: what a host passes has not changed meaning, but what it is *allowed* to pass has.
     */
    @Deprecated(
        "Renamed: values above 1.0 are now allowed, which 'volume' misdescribes.",
        ReplaceWith("setMasterGain(volume)"),
    )
    fun setMasterVolume(volume: Float) {
        setMasterGain(volume)
    }

    /**
     * Chooses what — if anything — shapes the mix once [setMasterGain] has pushed it past full
     * scale. Idempotent, persists across [prepare], and safe to call during playback.
     *
     * See [MasterOutputStage]; note that `PEAK_LIMITER` behaves as `NONE` here and says why.
     */
    fun setMasterOutputStage(stage: MasterOutputStage) {
        masterOutputStage = stage
        oboeStream?.setMasterOutputStage(stage)
    }

    /**
     * Starts reporting the mix's level, so a host can show a meter — or measure how much headroom is
     * left before [setMasterGain] pushes the mix past full scale.
     *
     * [handler] receives one [MixLevel] per written buffer, post-gain and pre-shaping. It is called
     * on the audio writer thread, **not** the main thread: hop before touching UI, and do not block
     * or the audio stalls. Buffers arrive only while audio is flowing.
     *
     * Starting again replaces the previous handler. Survives [prepare], which rebuilds the stream.
     */
    fun startLevelMonitoring(handler: (MixLevel) -> Unit) {
        levelHandler = handler
        oboeStream?.startLevelMonitoring(handler)
    }

    /** Stops reporting levels. A no-op when not monitoring. */
    fun stopLevelMonitoring() {
        levelHandler = null
        oboeStream?.stopLevelMonitoring()
    }

    /**
     * Mutes or un-mutes the strip identified by [partIndex] + [ordinal].
     * Recomputes [MixerChannel.effectiveMute] for all channels and
     * propagates audibility changes to the synth via MIDI CC7, routed
     * through the strip's own [MixerChannel.liveChannel] — NOT its
     * position in [mixerChannels], which is no longer the same as a MIDI
     * channel number once a part changes instrument mid-score.
     */
    fun setStaffMuted(partIndex: Int, ordinal: Int, muted: Boolean) {
        val idx = channelIndex(partIndex, ordinal)
        if (idx < 0) return
        updateChannel(idx) { it.copy(isMuted = muted) }
        reapplyChannelAudibility(idx)
        // Solo precedence may have changed effectiveMute on other strips too.
        for (i in _mixerChannels.value.indices) if (i != idx) reapplyChannelAudibility(i)
    }

    /**
     * Solos or un-solos the strip identified by [partIndex] + [ordinal].
     * When any strip is soloed, un-soloed strips are effectively muted.
     * Recomputes [MixerChannel.effectiveMute] for all channels and
     * propagates audibility changes to the synth via MIDI CC7.
     */
    fun setStaffSoloed(partIndex: Int, ordinal: Int, soloed: Boolean) {
        val idx = channelIndex(partIndex, ordinal)
        if (idx < 0) return
        updateChannel(idx) { it.copy(isSoloed = soloed) }
        for (i in _mixerChannels.value.indices) reapplyChannelAudibility(i)
    }

    /**
     * Sets the volume for the strip identified by [partIndex] + [ordinal]
     * (range 0..1). Propagates to the synth via MIDI CC7 on the strip's own
     * [MixerChannel.liveChannel]. If the channel is currently muted, the new
     * volume is recorded for restoration on unmute but not written to the
     * synth now (mute must keep CC7 = 0).
     */
    fun setStaffVolume(partIndex: Int, ordinal: Int, volume: Float) {
        val idx = channelIndex(partIndex, ordinal)
        if (idx < 0) return
        val liveChannel = _mixerChannels.value[idx].liveChannel
        updateChannel(idx) { it.copy(volume = volume) }
        // Use setChannelVolume (not reapplyChannelAudibility) so the new CC7 is
        // recorded in rememberedCC7 and applied only when the channel is unmuted.
        fluidSynthEngine?.setChannelVolume(liveChannel, volume)
    }

    /**
     * Swaps the program (sound) for the strip identified by [partIndex] +
     * [ordinal]. The change is applied immediately to the synth (on the
     * strip's own [MixerChannel.liveChannel]) and to the mixer state.
     * No-op when [state] is [PlaybackState.EXPORTING].
     *
     * Works for drum strips as well as melodic ones: [FluidSynthEngine.setStaffProgram] keeps the
     * channel on its own bank, so on a percussion strip this selects a kit within bank 128 rather than
     * a melodic patch. Hosts pick which catalog to offer from `MixerChannel.isDrums`.
     */
    fun setStaffProgram(partIndex: Int, ordinal: Int, program: Int) {
        if (_state.value == PlaybackState.EXPORTING) return
        val idx = channelIndex(partIndex, ordinal)
        if (idx < 0) return
        val liveChannel = _mixerChannels.value[idx].liveChannel
        fluidSynthEngine?.setStaffProgram(liveChannel, program)
        updateChannel(idx) { it.copy(program = program) }
    }

    /**
     * Retune playback to an A4 reference ([cents] offset from 440). Persists across prepare.
     * No-op when [state] is [PlaybackState.EXPORTING].
     */
    fun setMasterTuning(cents: Double) {
        if (_state.value == PlaybackState.EXPORTING) return
        masterTuningCents = cents
        applyTuning()
    }

    /**
     * Live whole-score transpose in [semitones], clamped to −12…+12. Persists across prepare.
     * No-op when [state] is [PlaybackState.EXPORTING].
     *
     * Implemented as a tuning shift, not a re-render: [FluidSynthEngine.setMasterTuning] retunes the
     * melodic channels only and leaves drum channels at concert pitch, which is exactly the semantics
     * the Apple `PlaybackEngine.setTranspose` has (global coarse tuning on the melodic unit). Notes
     * already sounding shift with it, and no MIDI is re-sequenced.
     *
     * The NOTATION half is separate: the host passes the same semitone count in `LayoutOptionsWire`,
     * and the layout bridge re-spells the score. Both halves must be driven, or the score will look
     * transposed while sounding at concert pitch (or the reverse).
     */
    fun setTranspose(semitones: Int) {
        if (_state.value == PlaybackState.EXPORTING) return
        transposeSemitones = semitones.coerceIn(-12, 12)
        applyTuning()
    }

    /**
     * Push calibration + transpose onto the melodic channels as one combined offset. Mirrors the Apple
     * engine's `applyTuning`: melodic = calibration + transpose, percussion = calibration only (the
     * drum exclusion lives inside [FluidSynthEngine.setMasterTuning]).
     */
    private fun applyTuning() {
        fluidSynthEngine?.setMasterTuning(effectiveTuningCents)
    }

    /** Combined melodic-channel offset from A4=440: calibration plus the transpose, 100 cents per semitone. */
    private val effectiveTuningCents: Double
        get() = masterTuningCents + transposeSemitones * 100.0

    // ── Metronome ────────────────────────────────────────────────────

    /**
     * Enables or disables metronome click output.
     *
     * Switching it back on mid-playback re-seeks the click transport to the score's position: while
     * inaudible the metronome synth is not rendered, so its transport was frozen wherever it was switched
     * off. Mirrors the Apple backend's `setMetronomeMuted`.
     */
    fun setMetronomeEnabled(enabled: Boolean) {
        val mixer = metronomeMixer ?: return
        val wasAudible = mixer.isAudible
        mixer.isEnabled = enabled
        if (enabled && !wasAudible) {
            // Mid-playback the player's own tick is the live one; stopped or paused (or still counting
            // in, where the player has not started yet) it is stale, and the intent is what play() will
            // start both transports from anyway.
            val playing = _state.value == PlaybackState.PLAYING && countInJob == null
            val scoreTick = if (playing) playerDriver?.currentTick ?: scoreTickIntent else scoreTickIntent
            mixer.resyncTo(scoreTick + metronomeTickOffset)
        }
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
            masterTuningControlChanges = {
                MidiControlChangeCodec.decode(jniBridge.masterTuningControlChanges(it))
            },
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
        val snapshot = ExportEngineSnapshot(
            mixerChannels = _mixerChannels.value,
            metronomeEnabled = metronomeMixer?.isEnabled ?: false,
            metronomeVolume = metronomeMixer?.volume ?: 1f,
            metronomeSmfBytes = jniBridge.renderMetronomeMidi(scoreHandle),
            rate = _currentRate.value,
            metronomeResolution = clickResolver.resolve(),
            // Pitch state travels with the snapshot for the same reason the mixer does: the offline
            // render builds a fresh synth at concert pitch, and the SMF it loads carries the AUTHORED
            // pitches because transposed playback is a tuning shift and never a re-render.
            masterTuningCents = masterTuningCents,
            transposeSemitones = transposeSemitones,
        )

        val smfBytes = jniBridge.renderMidi(scoreHandle)
        val staffParams = run {
            val spBytes = jniBridge.staffParams(scoreHandle)
            val r = BinaryReader(spBytes)
            val out = ArrayList<StaffParams>()
            r.readLengthPrefixed { inner ->
                while (inner.remaining > 0) {
                    out.add(inner.readLengthPrefixed { StaffParamsCodec.decodePayload(it) })
                }
            }
            out
        }
        val strips = stripsOrFallback(decodeInstrumentParams(scoreHandle), staffParams)

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
                strips = strips,
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
        metronomeMixer?.close()
        metronomeMixer = null
        staffLiveChannel = IntArray(0)
        staffIsDrums = BooleanArray(0)
        if (previewPolicyHandle != 0L) {
            jniBridge.previewPolicyRelease(previewPolicyHandle)
            previewPolicyHandle = 0L
        }
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
                // Loop wrap: if we've advanced past the loop's end, snap back. `tick` is an
                // UNROLLED player tick, so the bounds it is measured against — and the tick seeked
                // back to — have to be the loop's UNROLLED ones. Folding against the notated bounds
                // wrapped at the wrong instant, and to the wrong place, on any score with a repeat.
                val loop = transportLoop
                if (loop != null && tick >= loop.endTick) {
                    fluidSynthEngine?.allNotesOff()
                    player.seekTick(loop.startTick)
                    scoreTickIntent = loop.startTick
                    repositionMetronome(loop.startTick)
                    tick = loop.startTick
                }

                val frameBytes = jniBridge.frameAtTick(scoreHandle, tick)
                val frame = if (frameBytes.isEmpty()) null else FrameCodec.decode(frameBytes)
                // StateFlow.value assignments are atomic and thread-safe;
                // no Main-dispatch required here. Collectors in ViewModels
                // can observe on the UI dispatcher themselves via flowOn().
                if (frame != null) {
                    _currentCursor.value = frame.cursor
                    _currentTimeSeconds.value = frame.timeSeconds
                }
                // End of score: only stop when no loop is active. Compare
                // against the UNROLLED length — the player traverses the
                // repeat/jump-expanded SMF, so `tick` runs past the notated
                // `totalTicks` mid-piece whenever the score repeats.
                if (loop == null && tick >= unrolledTotalTicks && unrolledTotalTicks > 0) {
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

    // ── Instrument-params decoding (shared by prepare + export) ────────

    /**
     * Decodes the raw `[InstrumentParams]` bridge payload; empty when the
     * bridge is older (a 0-byte payload has no outer length prefix to
     * read, unlike an ENCODED empty array — `BinaryReader` would underflow
     * on it, so this is checked before constructing the reader).
     */
    private fun decodeInstrumentParams(scoreHandle: Long): List<InstrumentParams> {
        val bytes = jniBridge.instrumentParams(scoreHandle)
        if (bytes.isEmpty()) return emptyList()
        val r = BinaryReader(bytes)
        val out = ArrayList<InstrumentParams>()
        r.readLengthPrefixed { inner ->
            while (inner.remaining > 0) {
                out.add(inner.readLengthPrefixed { InstrumentParamsCodec.decodePayload(it) })
            }
        }
        return out
    }

    /**
     * [decoded] as-is when non-empty (the real per-(part × instrument)
     * strip list). Otherwise falls back to one strip per staff in [staves],
     * addressed by a SYNTHETIC per-staff partIndex (`i`, not the real
     * `StaffParams.partIndex`, which multiple unrelated staves may share —
     * e.g. every fixture in the test suite defaults it to 0) so
     * `(partIndex, ordinal)` stays uniquely addressable, and
     * `liveChannel = staffIndex` reproduces the pre-strip routing exactly.
     * Triggers for an older native bridge, or a test double that only
     * stubs `staffParams`.
     */
    private fun stripsOrFallback(
        decoded: List<InstrumentParams>,
        staves: List<StaffParams>,
    ): List<InstrumentParams> = decoded.ifEmpty {
        staves.mapIndexed { i, p ->
            InstrumentParams(
                partIndex = i,
                ordinal = 0,
                liveChannel = p.staffIndex,
                bankLSB = p.bankLSB,
                program = p.program,
                isDrums = p.isDrums,
                displayName = p.displayName.ifEmpty { "Staff ${i + 1}" },
                channelVolume = p.channelVolume,
            )
        }
    }

    // ── Mixer helpers ─────────────────────────────────────────────────

    /** Position of the strip identified by [partIndex] + [ordinal] in [mixerChannels], or -1. */
    private fun channelIndex(partIndex: Int, ordinal: Int): Int =
        _mixerChannels.value.indexOfFirst { it.partIndex == partIndex && it.ordinal == ordinal }

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
     * Reads the current [MixerChannel.effectiveMute] for the strip at
     * position [idx] in [mixerChannels] and propagates the mute/unmute
     * transition to the synth via MIDI CC7 — routed through the strip's
     * own [MixerChannel.liveChannel], NOT [idx] itself (no longer the same
     * as a MIDI channel number; see [setStaffMuted]).
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
    private fun reapplyChannelAudibility(idx: Int) {
        val ch = _mixerChannels.value.getOrNull(idx) ?: return
        if (ch.effectiveMute) {
            fluidSynthEngine?.muteChannel(ch.liveChannel)
        } else {
            fluidSynthEngine?.unmuteChannel(ch.liveChannel)
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
        metronomeMixer?.close()
        metronomeMixer = null
    }
}
