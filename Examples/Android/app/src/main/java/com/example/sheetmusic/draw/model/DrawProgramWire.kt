package com.example.sheetmusic.draw.model

/**
 * Internal wire envelope for a draw program. Produced by
 * [com.example.sheetmusic.draw.DrawProgramWireCodec]; validated and
 * unwrapped by [com.example.sheetmusic.draw.DrawProgramReader].
 *
 * Mirrors the `DrawProgramWire` struct in
 * `Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`.
 */
data class DrawProgramWire(
    val magic: UInt,
    val version: UInt,
    val pages: List<EncodablePage>,
)
