package io.github.jiyimeta.sheetmusic.compose.draw.model

/**
 * Internal wire envelope for a draw program. Produced by
 * [io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramWireCodec]; validated and
 * unwrapped by [io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader].
 *
 * Mirrors the `DrawProgramWire` struct in
 * `Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`.
 */
data class DrawProgramWire(
    val magic: UInt,
    val version: UInt,
    val pages: List<EncodablePage>,
)
