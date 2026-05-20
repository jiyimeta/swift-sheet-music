package io.github.kiichiio.sheetmusic.audio.fakes

import io.github.kiichiio.sheetmusic.audio.AndroidPlaybackEngine

/**
 * Test double for [AndroidPlaybackEngine.JniBridge].
 *
 * Each field is a var so individual tests can override just the methods
 * they care about. All defaults return safe empty / no-op values so tests
 * only set what they need.
 */
internal open class FakeJniBridge(
    var renderMidiResult: ByteArray = byteArrayOf(),
    var timelineSummaryResult: LongArray = longArrayOf(960L, 2_000_000L, 480L),
    var frameAtTickResult: ByteArray = byteArrayOf(),
    var frameForCursorResult: ByteArray = byteArrayOf(),
    var metronomeBeatsResult: ByteArray = byteArrayOf(),
    var staffParamsResult: ByteArray = byteArrayOf(),
    var pitchAndStaffOfNoteResult: Long = -1L,
    var earliestOfResult: ByteArray = byteArrayOf(),
    var itemEndTickResult: Long = -1L,
) : AndroidPlaybackEngine.JniBridge {

    val frameAtTickCalls = mutableListOf<Long>()
    val frameForCursorCalls = mutableListOf<ByteArray>()
    val pitchAndStaffCalls = mutableListOf<ByteArray>()
    val earliestOfCalls = mutableListOf<ByteArray>()

    override fun renderMidi(scoreHandle: Long): ByteArray = renderMidiResult
    override fun timelineSummary(scoreHandle: Long): LongArray = timelineSummaryResult
    override fun frameAtTick(scoreHandle: Long, tick: Long): ByteArray {
        frameAtTickCalls += tick
        return frameAtTickResult
    }
    open override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
        frameForCursorCalls += cursorBytes
        return frameForCursorResult
    }
    override fun metronomeBeats(scoreHandle: Long): ByteArray = metronomeBeatsResult
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
}
