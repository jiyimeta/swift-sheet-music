package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.Frame

/**
 * Decoder for [Frame].
 *
 * Wire format produced by Swift's `@WireFormat` on `FrameWire`:
 *   tick (i64) + timeSeconds (f64 IEEE 754) + ScoreCursor payload
 *
 * No version envelope. Returns null for an empty byte array (no frame available).
 */
object FrameDecoder {
    fun decode(data: ByteArray): Frame? {
        if (data.isEmpty()) return null
        val r = BinaryReader(data)
        val tick = r.readI64()
        val timeSeconds = r.readF64()
        val cursor = ScoreCursorDecoder.decodePayload(r)
        return Frame(
            tick = tick,
            timeSeconds = timeSeconds,
            cursor = cursor,
        )
    }
}
