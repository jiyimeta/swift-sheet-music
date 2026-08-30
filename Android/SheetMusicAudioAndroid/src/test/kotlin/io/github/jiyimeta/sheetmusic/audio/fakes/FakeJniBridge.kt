package io.github.jiyimeta.sheetmusic.audio.fakes

import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.PreviewPlan
import io.github.jiyimeta.sheetmusic.audio.serialization.PreviewPlanCodec

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
        return frameAtTickResult
    }
    open override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
        frameForCursorCalls += cursorBytes
        return frameForCursorResult
    }
    override fun countIn(scoreHandle: Long, cursorBytes: ByteArray): ByteArray = countInResult
    override fun staffParams(scoreHandle: Long): ByteArray = staffParamsResult
    override fun instrumentParams(scoreHandle: Long): ByteArray = instrumentParamsResult
    override fun pitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long {
        pitchAndStaffCalls += noteIdBytes
        return pitchAndStaffOfNoteResult
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
     * Builds the plan for each [previewPolicyBegin]. The default plans a plain audition that supersedes
     * nothing; override it to script a supersede, a drum's longer ring, or an unusual tail.
     */
    var previewPlanFor: (
        channel: Int, pitch: Int, velocity: Int, isDrum: Boolean, ringMillis: Int,
    ) -> PreviewPlan = { channel, pitch, velocity, isDrum, ringMillis ->
        PreviewPlan(
            generation = ++previewGeneration,
            supersedesChannel = -1,
            supersedesPitch = 0,
            channel = channel,
            pitch = pitch,
            velocity = velocity,
            isDrum = isDrum,
            ringMilliseconds = ringMillis,
            releaseTailMilliseconds = 800,
        )
    }

    /**
     * What [previewPolicyEnd] answers, packed as `channel shl 8 or pitch`, or -1 for "superseded".
     *
     * The default ends the newest plan's own note and nothing else — the shape the real policy has, stated
     * once here rather than re-derived in every test that needs an audition to end normally.
     */
    var previewPolicyEndResult: (generation: Long) -> Long = { generation ->
        previewPolicyBeginCalls.lastOrNull()
            ?.takeIf { it.generation == generation }
            ?.let { it.channel.toLong() shl 8 or it.pitch.toLong() }
            ?: -1L
    }

    var previewPolicyCreateResult: Long = 7L
    val previewPolicyReleaseCalls = mutableListOf<Long>()
    val previewPolicySilenceCalls = mutableListOf<Long>()

    override fun previewPolicyCreate(): Long = previewPolicyCreateResult

    override fun previewPolicyRelease(policyHandle: Long) {
        previewPolicyReleaseCalls += policyHandle
    }

    override fun previewPolicyBegin(
        policyHandle: Long,
        channel: Int,
        pitch: Int,
        velocity: Int,
        isDrum: Boolean,
        ringMilliseconds: Int,
    ): ByteArray {
        val plan = previewPlanFor(channel, pitch, velocity, isDrum, ringMilliseconds)
        previewPolicyBeginCalls += plan
        return PreviewPlanCodec.encode(plan)
    }

    override fun previewPolicyEnd(policyHandle: Long, generation: Long): Long =
        previewPolicyEndResult(generation)

    override fun previewPolicySilence(policyHandle: Long): Long {
        previewPolicySilenceCalls += policyHandle
        return -1L
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
