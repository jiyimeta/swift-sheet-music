package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Instrument/channel parameters for one mixer strip, decoded from the Swift
 * bridge. Mirrors the `InstrumentParams` struct in `InstrumentParamsCodec.swift`.
 *
 * Unlike [StaffParams] (keyed on `staffIndex`, one entry per staff), this is
 * keyed on [partIndex] + [ordinal] — one entry per DEDUPED (part × instrument)
 * strip, matching Apple's `LiveChannelPlan.Strip`. A part with a mid-score
 * instrument change contributes more than one entry; a grand-staff part with
 * no change contributes exactly one.
 *
 * bankLSB, program and channelVolume are u8 on the wire; stored as UByte to
 * match the generated codec's type expectations, mirroring [StaffParams].
 */
data class InstrumentParams(
    val partIndex: Int,
    /** Index into the part's DEDUPED instruments in first-appearance order. */
    val ordinal: Int,
    /**
     * The live single-port MIDI channel (`0...15`) this strip's program /
     * volume / mute must be routed through — NOT [StaffParams.staffIndex],
     * which only ever names a part's tick-0 channel.
     */
    val liveChannel: Int,
    val bankLSB: UByte,
    val program: UByte,
    val isDrums: Boolean,
    val displayName: String,
    val channelVolume: UByte = 100u,
) {
    /** Secondary constructor for call sites that pass Int literals. */
    constructor(
        partIndex: Int,
        ordinal: Int,
        liveChannel: Int,
        bankLSB: Int,
        program: Int,
        isDrums: Boolean,
        displayName: String,
        channelVolume: Int = 100,
    ) : this(
        partIndex = partIndex,
        ordinal = ordinal,
        liveChannel = liveChannel,
        bankLSB = bankLSB.toUByte(),
        program = program.toUByte(),
        isDrums = isDrums,
        displayName = displayName,
        channelVolume = channelVolume.toUByte(),
    )
}
