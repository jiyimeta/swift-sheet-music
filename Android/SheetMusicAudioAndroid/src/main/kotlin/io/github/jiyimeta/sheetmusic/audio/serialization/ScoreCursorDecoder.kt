package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor

/**
 * Decoder for [ScoreCursor] — single values.
 *
 * Wire format:
 *   version (u16) + kind (u8) + payload
 *     kind 0 → Item(ScoreItemID payload)
 *     kind 1 → Beat(measureIndex: i32, tickInMeasure: i32)
 */
object ScoreCursorDecoder {
    fun decodePayload(r: BinaryReader): ScoreCursor = when (val kind = r.readU8()) {
        0 -> ScoreCursor.Item(ScoreItemIDDecoder.decodePayload(r))
        1 -> ScoreCursor.Beat(
            measureIndex = r.readI32(),
            tickInMeasure = r.readI32(),
        )
        else -> error("Unknown ScoreCursor kind: $kind")
    }

    fun decode(data: ByteArray): ScoreCursor {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        return decodePayload(r)
    }
}
