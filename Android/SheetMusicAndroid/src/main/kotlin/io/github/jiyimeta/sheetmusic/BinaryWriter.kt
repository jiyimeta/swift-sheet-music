package io.github.jiyimeta.sheetmusic

/**
 * Sequential little-endian binary writer.
 *
 * Mirrors the write side of the Swift wire-format encoder used on the JNI
 * bridge. All multi-byte integers are stored little-endian to match the
 * Swift encoding.
 *
 * This copy is used by generated codecs in this module.
 * Audio-module codecs use the equivalent class in
 * `io.github.jiyimeta.sheetmusic.audio.serialization`.
 */
class BinaryWriter {
    private val out = mutableListOf<Byte>()

    /** Writes one unsigned byte. [v] is masked to [0, 255]. */
    fun writeU8(v: Int) { out += (v and 0xFF).toByte() }

    /** Writes one unsigned byte (UByte overload for generated codec compatibility). */
    fun writeU8(v: UByte) { out += v.toByte() }

    /** Writes one unsigned byte (UInt overload for generated codec compatibility). */
    fun writeU8(v: UInt) { out += (v and 0xFFu).toByte() }

    /** Writes two bytes as an unsigned 16-bit little-endian integer. */
    fun writeU16(v: Int) {
        writeU8(v and 0xFF)
        writeU8((v shr 8) and 0xFF)
    }

    /** Writes four bytes as a signed 32-bit little-endian integer. */
    fun writeI32(v: Int) {
        for (i in 0..3) writeU8((v shr (i * 8)) and 0xFF)
    }

    /** Writes eight bytes as a signed 64-bit little-endian integer. */
    fun writeI64(v: Long) {
        for (i in 0..7) writeU8(((v shr (i * 8)) and 0xFF).toInt())
    }

    /** Writes four bytes as an unsigned 32-bit little-endian integer. [v] is a [Long] to hold the full uint range. */
    fun writeU32(v: Long) {
        for (i in 0..3) writeU8(((v shr (i * 8)) and 0xFF).toInt())
    }

    /** Writes four bytes as a little-endian IEEE 754 [Float]. */
    fun writeF32(v: Float) { writeI32(java.lang.Float.floatToRawIntBits(v)) }

    /** Writes eight bytes as a little-endian IEEE 754 [Double]. */
    fun writeF64(v: Double) { writeI64(v.toRawBits()) }

    /**
     * Writes a UTF-8 string prefixed with a 4-byte little-endian length.
     * Mirrors Swift's `BinaryReader.readString`.
     */
    fun writeString(v: String) {
        val bytes = v.toByteArray(Charsets.UTF_8)
        writeI32(bytes.size)
        for (b in bytes) writeU8(b.toInt() and 0xFF)
    }

    /** Returns the accumulated bytes as a [ByteArray]. */
    fun toByteArray(): ByteArray = out.toByteArray()
}
