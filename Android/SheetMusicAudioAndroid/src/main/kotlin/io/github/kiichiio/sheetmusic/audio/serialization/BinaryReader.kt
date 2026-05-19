package io.github.kiichiio.sheetmusic.audio.serialization

/**
 * Sequential little-endian binary reader over an in-memory byte array.
 *
 * Mirrors the read side of AudioBinaryWriter.swift used on the Swift bridge.
 * All multi-byte integers are little-endian (matching Swift's `withUnsafeBytes`
 * store order on the wire).
 */
class BinaryReader(private val data: ByteArray) {
    private var offset = 0

    val remaining: Int get() = data.size - offset

    class UnderflowException : Exception("BinaryReader underflow")

    class VersionMismatchException(expected: Int, found: Int) :
        Exception("Codec version mismatch: expected $expected, found $found")

    /** Reads one unsigned byte as an [Int] in [0, 255]. */
    fun readU8(): Int {
        if (offset >= data.size) throw UnderflowException()
        return data[offset++].toInt() and 0xFF
    }

    /** Reads two bytes as an unsigned 16-bit little-endian integer. */
    fun readU16(): Int {
        val lo = readU8()
        val hi = readU8()
        return lo or (hi shl 8)
    }

    /** Reads four bytes as a signed 32-bit little-endian integer. */
    fun readI32(): Int {
        var v = 0
        for (i in 0..3) v = v or (readU8() shl (i * 8))
        return v
    }

    /** Reads eight bytes as a signed 64-bit little-endian integer. */
    fun readI64(): Long {
        var v = 0L
        for (i in 0..7) v = v or (readU8().toLong() shl (i * 8))
        return v
    }
}
