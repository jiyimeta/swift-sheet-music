package io.github.jiyimeta.sheetmusic

/**
 * Sequential little-endian binary reader over an in-memory byte array.
 *
 * Mirrors the read side of the Swift wire-format encoder used on the JNI
 * bridge. All multi-byte integers are little-endian to match the Swift
 * `withUnsafeBytes` store order on the wire.
 *
 * This copy is used by generated codecs in this module.
 * Audio-module codecs use the equivalent class in
 * `io.github.jiyimeta.sheetmusic.audio.serialization`.
 */
class BinaryReader(private val data: ByteArray) {
    private var offset = 0

    val remaining: Int get() = data.size - offset

    class UnderflowException : Exception("BinaryReader underflow")

    class VersionMismatchException(expected: Int, found: Int) :
        Exception("Codec version mismatch: expected $expected, found $found")

    /** Reads one unsigned byte as a [UByte]. */
    fun readU8(): UByte {
        if (offset >= data.size) throw UnderflowException()
        return data[offset++].toUByte()
    }

    /** Reads two bytes as an unsigned 16-bit little-endian integer. */
    fun readU16(): Int {
        val lo = readU8().toInt()
        val hi = readU8().toInt()
        return lo or (hi shl 8)
    }

    /** Reads four bytes as a signed 32-bit little-endian integer. */
    fun readI32(): Int {
        var v = 0
        for (i in 0..3) v = v or (readU8().toInt() shl (i * 8))
        return v
    }

    /** Reads eight bytes as a signed 64-bit little-endian integer. */
    fun readI64(): Long {
        var v = 0L
        for (i in 0..7) v = v or (readU8().toLong() shl (i * 8))
        return v
    }

    /** Reads four bytes as an unsigned 32-bit little-endian integer. */
    fun readU32(): Long {
        var v = 0L
        for (i in 0..3) v = v or (readU8().toLong() shl (i * 8))
        return v
    }

    /** Reads four bytes as a little-endian IEEE 754 [Float]. */
    fun readF32(): Float = java.lang.Float.intBitsToFloat(readI32())

    /** Reads eight bytes as a little-endian IEEE 754 [Double]. */
    fun readF64(): Double = Double.fromBits(readI64())

    /**
     * Reads a UTF-8 string prefixed with a 4-byte little-endian length.
     * Mirrors Swift's `BinaryWriter.writeString`.
     */
    fun readString(): String {
        val len = readI32()
        if (len < 0 || len > remaining) throw UnderflowException()
        val bytes = ByteArray(len)
        for (i in 0 until len) bytes[i] = readU8().toByte()
        return String(bytes, Charsets.UTF_8)
    }
}
