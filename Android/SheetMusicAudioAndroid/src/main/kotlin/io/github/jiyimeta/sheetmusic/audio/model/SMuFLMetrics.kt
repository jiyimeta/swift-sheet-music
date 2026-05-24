package io.github.jiyimeta.sheetmusic

/** Mirrors the SMuFLMetrics wire type. */
data class SMuFLMetrics(
    val magic: Long,
    val version: Long,
    val referenceSize: Double,
    val entries: List<SMuFLMetricsEntry>,
)
