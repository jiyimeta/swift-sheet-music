package io.github.kiichiio.sheetmusic.audio.model

/**
 * Per-staff instrument parameters decoded from the Swift bridge.
 * Mirrors the StaffParams struct in StaffParamsCodec.swift.
 *
 * bankLSB and program are u8 on the wire; Kotlin uses Int for ergonomics.
 */
data class StaffParams(
    val staffIndex: Int,
    val bankLSB: Int,
    val program: Int,
    val isDrums: Boolean,
    val partAddressHash: Long,
)
