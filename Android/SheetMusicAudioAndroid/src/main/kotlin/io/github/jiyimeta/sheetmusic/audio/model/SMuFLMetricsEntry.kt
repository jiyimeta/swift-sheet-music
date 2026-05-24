package io.github.jiyimeta.sheetmusic

/** Mirrors the SMuFLMetricsEntry wire type. */
data class SMuFLMetricsEntry(
    val codepoint: Long,
    val advance: Float,
    val bboxX: Float,
    val bboxY: Float,
    val bboxW: Float,
    val bboxH: Float,
)
