package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID

/**
 * Decoder for [ScoreItemID] — single values and arrays.
 *
 * Single-value wire format:
 *   version (u16) + kind (u8) + payload
 *     kind 0 → Note(NoteID payload)
 *     kind 1 → Rest(RestID payload)
 *     kind 2 → Tuplet(TupletID payload)
 *     kind 3 → Clef(ClefAnchor payload)
 *
 * Array wire format:
 *   version (u16) + count (i32) + count × (kind (u8) + payload)
 */
object ScoreItemIDDecoder {
    fun decodePayload(r: BinaryReader): ScoreItemID = when (val kind = r.readU8()) {
        0 -> ScoreItemID.Note(NoteIDDecoder.decodePayload(r))
        1 -> ScoreItemID.Rest(RestIDDecoder.decodePayload(r))
        2 -> ScoreItemID.Tuplet(TupletIDDecoder.decodePayload(r))
        3 -> ScoreItemID.Clef(ClefAnchorDecoder.decodePayload(r))
        else -> error("Unknown ScoreItemID kind: $kind")
    }

    fun decode(data: ByteArray): ScoreItemID {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        return decodePayload(r)
    }

    fun decodeArray(data: ByteArray): List<ScoreItemID> {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        val count = r.readI32()
        return List(count) { decodePayload(r) }
    }
}
