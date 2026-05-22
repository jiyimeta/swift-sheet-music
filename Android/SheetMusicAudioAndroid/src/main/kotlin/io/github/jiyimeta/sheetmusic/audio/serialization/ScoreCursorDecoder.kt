package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor

/**
 * Decoder for [ScoreCursor].
 *
 * Wire format produced by Swift's `@WireFormatChoice` on `ScoreCursorWire`:
 *   u8 discriminator (0 = Item, 1 = Beat) + payload
 *
 * No version envelope.
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

    fun decode(data: ByteArray): ScoreCursor = decodePayload(BinaryReader(data))
}
