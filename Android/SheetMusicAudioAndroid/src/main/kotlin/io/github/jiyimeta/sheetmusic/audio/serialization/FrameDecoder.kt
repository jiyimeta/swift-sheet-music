package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.Frame

/**
 * Decoder for [Frame].
 *
 * Wire format:
 *   version (u16) + tick (i64) + timeMicros (i64) + ScoreCursor payload
 *
 * Returns null for an empty byte array (no frame available).
 */
object FrameDecoder {
    fun decode(data: ByteArray): Frame? {
        if (data.isEmpty()) return null
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        val tick = r.readI64()
        val timeMicros = r.readI64()
        val cursor = ScoreCursorDecoder.decodePayload(r)
        return Frame(
            tick = tick,
            timeSeconds = timeMicros.toDouble() / 1_000_000.0,
            cursor = cursor,
        )
    }
}
