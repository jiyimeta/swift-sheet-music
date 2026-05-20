package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.StaffParams

/**
 * Array decoder for [StaffParams].
 *
 * Wire format per entry:
 *   staffIndex (i32) + bankLSB (u8) + program (u8) + isDrums (u8) + reserved (u8)
 *   + partAddressHash (i64)
 */
object StaffParamsDecoder {
    fun decodeArray(data: ByteArray): List<StaffParams> {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        val count = r.readI32()
        return List(count) {
            val staffIndex = r.readI32()
            val bankLSB = r.readU8()
            val program = r.readU8()
            val isDrums = r.readU8() != 0
            r.readU8() // reserved
            val hash = r.readI64()
            StaffParams(
                staffIndex = staffIndex,
                bankLSB = bankLSB,
                program = program,
                isDrums = isDrums,
                partAddressHash = hash,
            )
        }
    }
}
