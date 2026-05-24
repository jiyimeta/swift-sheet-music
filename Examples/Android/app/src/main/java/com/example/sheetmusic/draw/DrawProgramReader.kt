package com.example.sheetmusic.draw

import com.example.sheetmusic.draw.model.DrawProgram

/**
 * Validates a structurally decoded `DrawProgram` against the header
 * constants the Swift encoder writes. The auto-generated
 * [DrawProgramCodec] handles the byte layout; this wrapper enforces
 * magic / version invariants so format drift surfaces as a typed
 * error rather than a silent mis-parse.
 *
 * Mirrors `DrawProgramCodec` in
 * `Sources/SheetMusicAndroidJNI/DrawProgram.swift`.
 */
object DrawProgramReader {

    private const val MAGIC = 0x534D_4450L      // "SMDP"
    private const val VERSION = 4L

    class BadMagicException(actual: Long) :
        RuntimeException("bad draw-program magic: 0x${actual.toString(16)}")

    class UnsupportedVersionException(actual: Long) :
        RuntimeException("unsupported draw-program version: $actual")

    fun decode(bytes: ByteArray): DrawProgram {
        val program = DrawProgramCodec.decode(bytes)
        if (program.magic != MAGIC) throw BadMagicException(program.magic)
        if (program.version != VERSION) throw UnsupportedVersionException(program.version)
        return program
    }
}
