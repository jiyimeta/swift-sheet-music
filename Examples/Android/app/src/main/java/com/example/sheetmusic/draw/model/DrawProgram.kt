package com.example.sheetmusic.draw.model

/**
 * Mirrors the `DrawProgramWire` struct in
 * `Sources/SheetMusicAndroidJNI/DrawProgram.swift`. `magic` / `version`
 * are validated by `DrawProgramReader` after the structural decode so
 * format drift surfaces as a typed error.
 */
data class DrawProgram(
    val magic: Long,
    val version: Long,
    val pages: List<EncodablePage>,
)
