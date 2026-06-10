package io.github.jiyimeta.sheetmusic.compose.draw

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram

/**
 * Validates a structurally decoded draw-program wire envelope against the
 * header constants the Swift encoder writes. The auto-generated
 * [DrawProgramWireCodec] handles the byte layout; this wrapper enforces
 * magic / version invariants so format drift surfaces as a typed error
 * rather than a silent mis-parse.
 *
 * Mirrors `DrawProgramCodec` in
 * `Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`.
 */
object DrawProgramReader {

    private val MAGIC: UInt = 0x534D_4450u   // "SMDP"
    private val VERSION: UInt = 6u

    class BadMagicException(actual: UInt) :
        RuntimeException("bad draw-program magic: 0x${actual.toString(16)}")

    class UnsupportedVersionException(actual: UInt) :
        RuntimeException("unsupported draw-program version: $actual")

    fun decode(bytes: ByteArray): DrawProgram {
        val wire = DrawProgramWireCodec.decode(bytes)
        if (wire.magic != MAGIC) throw BadMagicException(wire.magic)
        if (wire.version != VERSION) throw UnsupportedVersionException(wire.version)
        return DrawProgram(pages = wire.pages)
    }
}
