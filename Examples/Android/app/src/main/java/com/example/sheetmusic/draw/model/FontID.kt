package com.example.sheetmusic.draw.model

/**
 * Identifies which font a `DrawCommand.Glyph` / `DrawCommand.Text` should
 * paint with. Ordinal layout must match the Swift `DrawProgram.FontID`
 * raw values in `Sources/SheetMusicBridgeCore/Draw/DrawProgram.swift` —
 * the generated `FontIDCodec` writes `ordinal` and decodes by indexing
 * `entries`, so only append.
 */
enum class FontID {
    TEXT_ROMAN,
    SMUFL,

    /**
     * The platform UI family — SF on Apple, Segoe UI on Windows. This app has
     * none and draws the text face (Edwin).
     */
    SYSTEM,
}
