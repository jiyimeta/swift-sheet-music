package io.github.kiichiio.sheetmusic.audio.serialization

import io.github.kiichiio.sheetmusic.audio.model.MetronomeBeat

/**
 * Array decoder for [MetronomeBeat].
 *
 * Wire format:
 *   version (u16) + count (i32) + count × (tick: i64, kind: i32, reserved: i32)
 *   kind 0 = downbeat, kind 1 = upbeat
 */
object MetronomeBeatDecoder {
    fun decodeArray(data: ByteArray): List<MetronomeBeat> {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        val count = r.readI32()
        return List(count) {
            val tick = r.readI64()
            val kind = r.readI32()
            r.readI32() // reserved
            MetronomeBeat(tick = tick, isDownbeat = kind == 0)
        }
    }
}
