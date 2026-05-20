package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument

/**
 * Decodes the `GMInstrumentArray` blob produced by Swift's
 * `GMInstrumentCodec.encodeAll()`.
 *
 * Wire layout:
 * ```
 * u16 version (= 1)
 * i32 count
 * count × {
 *   u8  program       0..127
 *   u8  familyIndex   0..15
 *   u16 nameLen       UTF-8 byte length
 *   nameLen × u8      UTF-8 bytes
 * }
 * ```
 */
internal object GMInstrumentDecoder {
    private const val VERSION = 1

    fun decodeArray(bytes: ByteArray): List<GMInstrument> {
        val r = BinaryReader(bytes)
        val version = r.readU16()
        require(version == VERSION) {
            "GMInstrument codec version mismatch: expected $VERSION, found $version"
        }
        val count = r.readI32()
        val out = ArrayList<GMInstrument>(count)
        for (i in 0 until count) {
            val program = r.readU8()
            val familyIndex = r.readU8()
            val nameLen = r.readU16()
            val nameBytes = ByteArray(nameLen)
            for (j in 0 until nameLen) {
                nameBytes[j] = r.readU8().toByte()
            }
            val name = String(nameBytes, Charsets.UTF_8)
            out.add(
                GMInstrument(
                    program = program,
                    displayName = name,
                    familyIndex = familyIndex,
                ),
            )
        }
        return out
    }
}
