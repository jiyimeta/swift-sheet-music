package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument

/**
 * Decodes the `[GMInstrument]` blob produced by Swift's
 * `GMInstrumentCodec.encodeAll()` (which goes through `@WireFormat` on
 * `GMInstrument` and `@WireFormatEnum` on `GMInstrument.Family`).
 *
 * Wire layout:
 * ```
 * i32 instrumentCount       ← Array<T> length prefix
 * instrumentCount × {
 *   u8  program             0..127
 *   i32 nameByteCount       ← String length prefix
 *   nameByteCount × u8      UTF-8 bytes
 *   u8  familyOrdinal       0..15 (index into Swift's Family.allCases)
 * }
 * ```
 *
 * No version envelope — the `.so` and `.aar` ship together from the same
 * git commit, so a wire mismatch would already manifest as a structural
 * decode failure, not a missed version assertion.
 */
internal object GMInstrumentDecoder {
    fun decodeArray(bytes: ByteArray): List<GMInstrument> {
        val r = BinaryReader(bytes)
        val count = r.readI32()
        val out = ArrayList<GMInstrument>(count)
        for (i in 0 until count) {
            val program = r.readU8().toInt()
            val nameLen = r.readI32()
            require(nameLen >= 0) { "GMInstrument name length is negative: $nameLen" }
            val nameBytes = ByteArray(nameLen)
            for (j in 0 until nameLen) {
                nameBytes[j] = r.readU8().toByte()
            }
            val name = String(nameBytes, Charsets.UTF_8)
            val familyOrdinal = r.readU8().toInt()
            out.add(
                GMInstrument(
                    program = program,
                    displayName = name,
                    familyIndex = familyOrdinal,
                ),
            )
        }
        return out
    }
}
