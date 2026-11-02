package io.github.jiyimeta.sheetmusic.audio.fakes

import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.PreviewPlan
import io.github.jiyimeta.sheetmusic.audio.model.PreviewVoice
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.PreviewPlanCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.jiyimeta.wirelet.BinaryWriter

/**
 * Test double for [AndroidPlaybackEngine.JniBridge].
 *
 * Each field is a var so individual tests can override just the methods
 * they care about. All defaults return safe empty / no-op values so tests
 * only set what they need.
 */
internal open class FakeJniBridge(
    var renderMidiResult: ByteArray = byteArrayOf(),
    var renderMetronomeMidiResult: ByteArray = byteArrayOf(),
    /** Empty by default — "this position has no count-in", so play starts the score immediately. */
    var renderCountInMetronomeMidiResult: ByteArray = byteArrayOf(),
    var timelineSummaryResult: LongArray = longArrayOf(960L, 2_000_000L, 480L),
    var frameAtTickResult: ByteArray = byteArrayOf(),
    var frameForCursorResult: ByteArray = byteArrayOf(),
    /** Empty by default — an undecodable payload, which the engine reads as "no count-in". */
    var countInResult: ByteArray = byteArrayOf(),
    var staffParamsResult: ByteArray = byteArrayOf(),
    /** Empty by default — triggers `AndroidPlaybackEngine`'s per-staff fallback. */
    var instrumentParamsResult: ByteArray = byteArrayOf(),
    var pitchAndStaffOfNoteResult: Long = -1L,
    var earliestOfResult: ByteArray = byteArrayOf(),
    var itemEndTickResult: Long = -1L,
    var resolveExportTickRangeResult: LongArray = longArrayOf(0L, 1920L),
) : AndroidPlaybackEngine.JniBridge {

    val frameAtTickCalls = mutableListOf<Long>()
    val frameForCursorCalls = mutableListOf<ByteArray>()
    /** The score handle each [frameAtTick] / [frameForCursor] call resolved against, in order. */
    val frameScoreHandles = mutableListOf<Long>()
    val pitchAndStaffCalls = mutableListOf<ByteArray>()
    val earliestOfCalls = mutableListOf<ByteArray>()

    override fun renderMidi(scoreHandle: Long): ByteArray = renderMidiResult
    override fun renderMetronomeMidi(scoreHandle: Long): ByteArray = renderMetronomeMidiResult
    override fun renderCountInMetronomeMidi(
        scoreHandle: Long,
        cursorBytes: ByteArray,
        baseTick: Long,
    ): ByteArray = renderCountInMetronomeMidiResult
    override fun timelineSummary(scoreHandle: Long): LongArray = timelineSummaryResult
    override fun frameAtTick(scoreHandle: Long, tick: Long): ByteArray {
        frameAtTickCalls += tick
        frameScoreHandles += scoreHandle
        return frameAtTickResult
    }
    open override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
        frameForCursorCalls += cursorBytes
        frameScoreHandles += scoreHandle
        return frameForCursorResult
    }
    /**
     * Identity — the projection of a score without repeats, which is what every fixture here describes unless
     * it overrides this with its own unroll table.
     */
    override fun unrolledTickForNotated(scoreHandle: Long, notatedTick: Long): Long = notatedTick

    // ── Carrying the transport across a score swap ─────────────────────────
    //
    // Off by default — [snapshotScore] answers 0, so the engine keeps no copy and a swap stops and rewinds, which is
    // what every fixture written before the carry expects. A test that exercises the carry turns [keepsSnapshots] on
    // and scripts what the shared Swift would answer.

    /** Whether [snapshotScore] hands out copies: handles 100, 101, … in order. */
    var keepsSnapshots: Boolean = false
    private var nextSnapshot = 100L
    /** The handles [snapshotScore] was asked to copy, in order. */
    val snapshotScoreCalls = mutableListOf<Long>()
    /** The handles released through [releaseScore], in order. */
    val releaseScoreCalls = mutableListOf<Long>()
    /** What [carryCursor] answers for the cursor bytes it was handed; carries nothing by default. */
    var carryCursorResult: (cursorBytes: ByteArray) -> ByteArray = { ByteArray(0) }
    /** `(from, to)` for every [carryCursor] call. */
    val carryCursorCalls = mutableListOf<Pair<Long, Long>>()
    /** What [carryLoop] answers for the loop it was handed; carries nothing by default. */
    var carryLoopResult: (startTick: Long, endTick: Long) -> LongArray = { _, _ -> LongArray(0) }
    /** `(from, to)` for every [carryLoop] call. */
    val carryLoopCalls = mutableListOf<Pair<Long, Long>>()

    override fun snapshotScore(scoreHandle: Long): Long {
        snapshotScoreCalls += scoreHandle
        return if (keepsSnapshots) nextSnapshot++ else 0L
    }

    override fun releaseScore(scoreHandle: Long) {
        releaseScoreCalls += scoreHandle
    }

    override fun carryCursor(fromScoreHandle: Long, toScoreHandle: Long, cursorBytes: ByteArray): ByteArray {
        carryCursorCalls += fromScoreHandle to toScoreHandle
        return carryCursorResult(cursorBytes)
    }

    override fun carryLoop(fromScoreHandle: Long, toScoreHandle: Long, startTick: Long, endTick: Long): LongArray {
        carryLoopCalls += fromScoreHandle to toScoreHandle
        return carryLoopResult(startTick, endTick)
    }

    override fun countIn(scoreHandle: Long, cursorBytes: ByteArray): ByteArray = countInResult
    override fun staffParams(scoreHandle: Long): ByteArray = staffParamsResult
    override fun instrumentParams(scoreHandle: Long): ByteArray = instrumentParamsResult
    override fun pitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long {
        pitchAndStaffCalls += noteIdBytes
        return pitchAndStaffOfNoteResult
    }

    /**
     * What [previewRoute] answers, given the pitch it was asked for (negative: the note's own) — what the shared Swift
     * would route. `null`, the default, keeps the interface's own answer: [pitchAndStaffOfNote] with no routing.
     */
    var previewRouteResult: ((pitch: Int) -> LongArray)? = null
    /** `(scoreHandle, preparedScoreHandle, pitch)` for every [previewRoute] call. */
    val previewRouteCalls = mutableListOf<Triple<Long, Long, Int>>()

    override fun previewRoute(
        scoreHandle: Long,
        preparedScoreHandle: Long,
        noteIdBytes: ByteArray,
        pitch: Int,
    ): LongArray {
        previewRouteCalls += Triple(scoreHandle, preparedScoreHandle, pitch)
        val scripted = previewRouteResult
            ?: return super.previewRoute(scoreHandle, preparedScoreHandle, noteIdBytes, pitch)
        return scripted(pitch)
    }
    override fun earliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray {
        earliestOfCalls += idsBytes
        return earliestOfResult
    }

    val itemEndTickCalls = mutableListOf<ByteArray>()
    override fun itemEndTick(scoreHandle: Long, idBytes: ByteArray): Long {
        itemEndTickCalls += idBytes
        return itemEndTickResult
    }

    val resolveExportTickRangeCalls = mutableListOf<ByteArray>()
    override fun resolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray {
        resolveExportTickRangeCalls += rangeBytes
        return resolveExportTickRangeResult
    }

    var buildClickSoundFontResult: ByteArray = byteArrayOf()
    val buildClickSoundFontCalls = mutableListOf<Pair<ByteArray, ByteArray>>()
    override fun buildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray): ByteArray {
        buildClickSoundFontCalls += strongWav to weakWav
        return buildClickSoundFontResult
    }

    // ── Note auditions ─────────────────────────────────────────────────────
    //
    // The policy these stand in for is Swift, and `NotePreviewPolicyTests` over there is what pins it. These
    // exist so a test can hand the engine a PLAN and watch what the engine does with it, which is the whole of
    // this side's job: send the supersede, sound the note, end the note the policy names and no other.

    /** Every plan handed out, in order. */
    val previewPolicyBeginCalls = mutableListOf<PreviewPlan>()

    private var previewGeneration = 0L

    /**
     * Builds the plan for each [previewPolicyBegin]. The default plans a plain audition of the notes asked for that
     * supersedes nothing; override it to script a supersede, a drum's longer ring, or an unusual tail.
     */
    var previewPlanFor: (
        voices: List<PreviewVoice>, velocity: Int, isDrum: Boolean, ringMillis: Int,
    ) -> PreviewPlan = { voices, velocity, isDrum, ringMillis ->
        PreviewPlan(
            generation = ++previewGeneration,
            supersededVoices = emptyList(),
            voices = voices,
            velocity = velocity,
            isDrum = isDrum,
            ringMilliseconds = ringMillis,
            releaseTailMilliseconds = 800,
        )
    }

    /**
     * What [previewPolicyEnd] answers: the notes to silence, or empty for "superseded".
     *
     * The default ends the newest plan's own notes and nothing else — the shape the real policy has, stated
     * once here rather than re-derived in every test that needs an audition to end normally.
     */
    var previewPolicyEndResult: (generation: Long) -> List<PreviewVoice> = { generation ->
        previewPolicyBeginCalls.lastOrNull()
            ?.takeIf { it.generation == generation }
            ?.voices
            ?: emptyList()
    }

    var previewPolicyCreateResult: Long = 7L
    val previewPolicyReleaseCalls = mutableListOf<Long>()
    val previewPolicySilenceCalls = mutableListOf<Long>()

    /** What [onsetNoteItems] answers for any item: the notes a tap sounds. Empty by default ("nothing starts"). */
    var onsetNoteItemsResult: List<NoteID> = emptyList()

    override fun previewPolicyCreate(): Long = previewPolicyCreateResult

    override fun previewPolicyRelease(policyHandle: Long) {
        previewPolicyReleaseCalls += policyHandle
    }

    override fun previewPolicyBegin(
        policyHandle: Long,
        voices: ByteArray,
        velocity: Int,
        isDrum: Boolean,
        ringMilliseconds: Int,
    ): ByteArray {
        val notes = (0 until voices.size / 2).map {
            PreviewVoice(channel = voices[it * 2].toInt() and 0xFF, pitch = voices[it * 2 + 1].toInt() and 0xFF)
        }
        if (notes.isEmpty()) return ByteArray(0)
        val plan = previewPlanFor(notes, velocity, isDrum, ringMilliseconds)
        previewPolicyBeginCalls += plan
        return PreviewPlanCodec.encode(plan)
    }

    override fun previewPolicyEnd(policyHandle: Long, generation: Long): ByteArray =
        packed(previewPolicyEndResult(generation))

    override fun previewPolicySilence(policyHandle: Long): ByteArray {
        previewPolicySilenceCalls += policyHandle
        return ByteArray(0)
    }

    override fun onsetNoteItems(scoreHandle: Long, itemBytes: ByteArray): ByteArray {
        if (onsetNoteItemsResult.isEmpty()) return ByteArray(0)
        val w = BinaryWriter()
        w.writeLengthPrefixed {
            for (id in onsetNoteItemsResult) {
                writeLengthPrefixed { ScoreItemIDCodec.encodePayload(ScoreItemID.Note(id), this) }
            }
        }
        return w.toByteArray()
    }

    /** Packs notes the way the policy's JNI entry points answer them: `channel, pitch`, a byte each. */
    private fun packed(voices: List<PreviewVoice>): ByteArray {
        val bytes = ByteArray(voices.size * 2)
        voices.forEachIndexed { index, voice ->
            bytes[index * 2] = voice.channel.toByte()
            bytes[index * 2 + 1] = voice.pitch.toByte()
        }
        return bytes
    }

    /**
     * Cents the engine asked to retune by, in order — the half of master tuning that is still this side's,
     * now that the RPN encoding itself is shared Swift.
     */
    val masterTuningCalls = mutableListOf<Double>()

    /**
     * One placeholder message per retune, and none at all for zero cents.
     *
     * Not a marker carrying the cents, unlike [MarkerMasterTuning]: this answer goes back through
     * `MidiControlChangeCodec`, whose bytes are bytes, so the cents could not survive the trip. Tests that
     * care which cents were asked for read [masterTuningCalls]; tests that care about the resulting RPN build
     * their own `AudioExporter` and inject [MarkerMasterTuning] directly.
     */
    override fun masterTuningControlChanges(cents: Double): ByteArray {
        masterTuningCalls += cents
        return if (cents == 0.0) {
            byteArrayOf()
        } else {
            byteArrayOf(MarkerMasterTuning.CONTROLLER.toByte(), 1)
        }
    }
}
