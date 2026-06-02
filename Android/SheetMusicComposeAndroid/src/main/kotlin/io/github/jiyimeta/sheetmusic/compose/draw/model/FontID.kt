package io.github.jiyimeta.sheetmusic.compose.draw.model

/**
 * Identifies which font a `DrawCommand.Glyph` / `DrawCommand.Text` should
 * paint with. Ordinal layout must match the Swift `DrawProgram.FontID`
 * declaration order in `Sources/SheetMusicAndroidJNI/DrawProgram.swift`.
 */
enum class FontID {
    TEXT_ROMAN,
    SMUFL,
}
