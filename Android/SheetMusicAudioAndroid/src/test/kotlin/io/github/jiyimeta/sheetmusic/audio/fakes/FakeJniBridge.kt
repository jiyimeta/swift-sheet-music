package io.github.jiyimeta.sheetmusic.audio.fakes

import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine

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
}
