package io.github.jiyimeta.sheetmusic.audio.serialization

/**
 * Sequential little-endian binary writer.
 *
 * Mirrors the write side of AudioBinaryWriter.swift used on the Swift bridge.
 * All multi-byte integers are stored little-endian to match the Swift encoding.
 */
class BinaryWriter {
    private val out = mutableListOf<Byte>()

    /** Writes one unsigned byte. [v] is masked to [0, 255]. */
    fun writeU8(v: Int) { out += (v and 0xFF).toByte() }

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

    /** Returns the accumulated bytes as a [ByteArray]. */
    fun toByteArray(): ByteArray = out.toByteArray()
}
