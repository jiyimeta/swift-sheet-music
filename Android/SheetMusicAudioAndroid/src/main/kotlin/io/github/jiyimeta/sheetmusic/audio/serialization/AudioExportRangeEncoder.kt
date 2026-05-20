package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange

/**
 * Serializes [AudioExportRange] to the JNI wire format consumed by the
 * Swift `AudioExportRange` decoder.
 *
 * Layout:
 *   u16 version = 1   (little-endian)
 *   u8  tag
 *     0 = Full              (no payload)
 *     1 = CurrentLoop       (no payload)
 *     2 = Region            payload = ScoreCursor(from) + ScoreCursor(to)
 *     3 = RegionThroughEnd  payload = ScoreCursor(from) + ScoreItemID(last)
 */
internal object AudioExportRangeEncoder {
    fun encode(range: AudioExportRange): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1) // version
        when (range) {
            is AudioExportRange.Full -> w.writeU8(0)
            is AudioExportRange.CurrentLoop -> w.writeU8(1)
            is AudioExportRange.Region -> {
                w.writeU8(2)
                ScoreCursorCodec.encodePayload(range.from, w)
                ScoreCursorCodec.encodePayload(range.to, w)
            }
            is AudioExportRange.RegionThroughEnd -> {
                w.writeU8(3)
                ScoreCursorCodec.encodePayload(range.from, w)
                ScoreItemIDCodec.encodePayload(range.last, w)
            }
        }
        return w.toByteArray()
    }
}
