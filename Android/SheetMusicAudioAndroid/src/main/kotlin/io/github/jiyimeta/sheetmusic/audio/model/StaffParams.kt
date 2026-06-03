package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Per-staff instrument parameters decoded from the Swift bridge.
 * Mirrors the StaffParams struct in StaffParamsCodec.swift.
 *
 * bankLSB, program and channelVolume are u8 on the wire; stored as UByte to
 * match the generated codec's type expectations.
 *
 * The score-derived fields ([partIndex], [staffIndexInPart], [displayName],
 * [trackName], [instrumentLongName], [channelVolume], [defaultClefType]) are
 * surfaced at iOS parity for the Reader inspector. String fields use "" to
 * mean "absent" (the wire carries no optionals). [displayName] is derived once
 * in shared Swift (`Score.staffDisplayName(at:)`), so consumers should prefer
 * it over re-deriving a label from [trackName] / [instrumentLongName].
 */
data class StaffParams(
    val staffIndex: Int,
    val bankLSB: UByte,
    val program: UByte,
    val isDrums: Boolean,
    val partAddressHash: Long,
    val partIndex: Int = 0,
    val staffIndexInPart: Int = 0,
    val displayName: String = "",
    val trackName: String = "",
    val instrumentLongName: String = "",
    val channelVolume: UByte = 100u,
    val defaultClefType: String = "",
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
