package com.example.sheetmusic.draw.model

/**
 * View-friendly representation of a decoded draw program. `magic` /
 * `version` are validated by `DrawProgramReader` before this object is
 * constructed; only `pages` survives the header-strip.
 */
data class DrawProgram(
    val pages: List<EncodablePage>,
)
