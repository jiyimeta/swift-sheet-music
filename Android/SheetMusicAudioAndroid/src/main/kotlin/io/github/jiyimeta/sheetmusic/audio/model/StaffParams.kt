package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Per-staff instrument parameters decoded from the Swift bridge.
 * Mirrors the StaffParams struct in StaffParamsCodec.swift.
 *
 * bankLSB and program are u8 on the wire; stored as UByte to match
 * the generated codec's type expectations.
 */
data class StaffParams(
    val staffIndex: Int,
    val bankLSB: UByte,
    val program: UByte,
    val isDrums: Boolean,
    val partAddressHash: Long,
) {
    /** Secondary constructor for call sites that pass Int literals. */
    constructor(
        staffIndex: Int,
        bankLSB: Int,
        program: Int,
        isDrums: Boolean,
        partAddressHash: Long,
    ) : this(
        staffIndex = staffIndex,
        bankLSB = bankLSB.toUByte(),
        program = program.toUByte(),
        isDrums = isDrums,
        partAddressHash = partAddressHash,
    )
}
