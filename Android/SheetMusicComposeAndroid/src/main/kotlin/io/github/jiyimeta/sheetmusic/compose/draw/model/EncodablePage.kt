package io.github.jiyimeta.sheetmusic.compose.draw.model

/** One page worth of draw commands. */
data class EncodablePage(
    val widthMM: Double,
    val heightMM: Double,
    val commands: List<DrawCommand>,
)
