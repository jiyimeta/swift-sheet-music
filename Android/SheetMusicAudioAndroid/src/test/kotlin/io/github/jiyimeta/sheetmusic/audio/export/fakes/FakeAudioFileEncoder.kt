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

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        totalFramesWritten += frames
    }

    override fun finish() { finished = true }
    override fun close() { closed = true }
}
