package io.github.jiyimeta.sheetmusic.wireformat

/**
 * Sequential little-endian binary writer. Used by every code-generated
 * codec produced by `emit-kotlin-codecs`. See [BinaryReader] for the
 * rationale behind hosting this in `:SheetMusicAndroid`.
 *
 * Mirrors the write side of the Swift wire-format encoder.
 */
class BinaryWriter {
    private val out = mutableListOf<Byte>()

    fun writeU8(v: Int) { out += (v and 0xFF).toByte() }
    fun writeU8(v: UByte) { out += v.toByte() }
    fun writeU8(v: UInt) { out += (v and 0xFFu).toByte() }

    fun writeU16(v: Int) {
        writeU8(v and 0xFF)
        writeU8((v shr 8) and 0xFF)
    }

    fun writeI32(v: Int) {
        for (i in 0..3) writeU8((v shr (i * 8)) and 0xFF)
    }

    fun writeI64(v: Long) {
        for (i in 0..7) writeU8(((v shr (i * 8)) and 0xFF).toInt())
    }

    fun writeU32(v: Long) {
        for (i in 0..3) writeU8(((v shr (i * 8)) and 0xFF).toInt())
    }

    fun writeF32(v: Float) { writeI32(java.lang.Float.floatToRawIntBits(v)) }
    fun writeF64(v: Double) { writeI64(v.toRawBits()) }

    fun writeString(v: String) {
        val bytes = v.toByteArray(Charsets.UTF_8)
        writeI32(bytes.size)
        for (b in bytes) writeU8(b.toInt() and 0xFF)
    }

    fun toByteArray(): ByteArray = out.toByteArray()
}
