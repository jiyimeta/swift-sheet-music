package io.github.jiyimeta.sheetmusic.audio.export.fakes

import io.github.jiyimeta.sheetmusic.audio.export.AudioFileEncoder

/**
 * Test double for [AudioFileEncoder]. Records the total number of frames
 * appended and whether [finish] / [close] were called, without touching the
 * filesystem or any encoder back-end.
 */
internal class FakeAudioFileEncoder : AudioFileEncoder {
    var totalFramesWritten: Int = 0
    var finished: Boolean = false
    var closed: Boolean = false

    /** Every sample handed over, left then right, block by block. */
    val samples = mutableListOf<Float>()

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        totalFramesWritten += frames
        for (i in 0 until frames) samples += left[i]
        for (i in 0 until frames) samples += right[i]
    }

    override fun finish() { finished = true }
    override fun close() { closed = true }
}
