package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID

/**
 * Decoder for [ScoreItemID] — single values and arrays.
 *
 * Single-value wire format (no version envelope):
 *   u8 discriminator (0 = Note, 1 = Rest, 2 = Tuplet, 3 = Clef) + payload
 *
 * Array wire format:
 *   i32 count + count × (u8 discriminator + payload)
 */
object ScoreItemIDDecoder {
    fun decodePayload(r: BinaryReader): ScoreItemID = when (val kind = r.readU8()) {
        0 -> ScoreItemID.Note(NoteIDDecoder.decodePayload(r))
        1 -> ScoreItemID.Rest(RestIDDecoder.decodePayload(r))
        2 -> ScoreItemID.Tuplet(TupletIDDecoder.decodePayload(r))
        3 -> ScoreItemID.Clef(ClefAnchorDecoder.decodePayload(r))
        else -> error("Unknown ScoreItemID kind: $kind")
    }

    fun decode(data: ByteArray): ScoreItemID = decodePayload(BinaryReader(data))

    fun decodeArray(data: ByteArray): List<ScoreItemID> {
        val r = BinaryReader(data)
        val count = r.readI32()
        return List(count) { decodePayload(r) }
    }
}
