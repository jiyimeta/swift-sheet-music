package io.github.jiyimeta.sheetmusic.wireformat

/**
 * Sequential little-endian binary reader. Used by every code-generated
 * codec produced by `emit-kotlin-codecs`, regardless of which module
 * the codec is compiled into. Hosted in `:SheetMusicAndroid` so that
 * `:SheetMusicAudioAndroid` (which has `api(project(":SheetMusicAndroid"))`)
 * and the Examples/Android app (which depends on `sheet-music-android`)
 * all see this single canonical copy transitively.
 *
 * Mirrors the read side of the Swift wire-format encoder used on the JNI
 * bridge — see `Sources/SheetMusicWireFormat/`. Multi-byte integers are
 * little-endian (matching Swift's `withUnsafeBytes` store order on the
 * wire).
 */
class BinaryReader(private val data: ByteArray) {
    private var offset = 0

    val remaining: Int get() = data.size - offset

    class UnderflowException : Exception("BinaryReader underflow")

    fun readU8(): UByte {
        if (offset >= data.size) throw UnderflowException()
        return data[offset++].toUByte()
    }

    fun readU16(): Int {
        val lo = readU8().toInt()
        val hi = readU8().toInt()
        return lo or (hi shl 8)
    }

    fun readI32(): Int {
        var v = 0
        for (i in 0..3) v = v or (readU8().toInt() shl (i * 8))
        return v
    }

    fun readI64(): Long {
        var v = 0L
        for (i in 0..7) v = v or (readU8().toLong() shl (i * 8))
        return v
    }

    fun readU32(): Long {
        var v = 0L
        for (i in 0..3) v = v or (readU8().toLong() shl (i * 8))
        return v
    }

    fun readF32(): Float = java.lang.Float.intBitsToFloat(readI32())

    fun readF64(): Double = Double.fromBits(readI64())

    fun readString(): String {
        val len = readI32()
        if (len < 0 || len > remaining) throw UnderflowException()
        val bytes = ByteArray(len)
        for (i in 0 until len) bytes[i] = readU8().toByte()
        return String(bytes, Charsets.UTF_8)
    }
}
