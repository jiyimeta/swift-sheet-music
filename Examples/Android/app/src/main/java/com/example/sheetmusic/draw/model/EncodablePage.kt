package com.example.sheetmusic.draw.model

/** One page worth of draw commands. */
data class EncodablePage(
    val widthMM: Double,
    val heightMM: Double,
    val commands: List<DrawCommand>,
)
