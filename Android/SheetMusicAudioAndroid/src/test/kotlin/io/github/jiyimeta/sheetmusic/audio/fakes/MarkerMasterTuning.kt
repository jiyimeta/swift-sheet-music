package io.github.jiyimeta.sheetmusic.audio.fakes

import io.github.jiyimeta.sheetmusic.audio.model.MidiControlChange
import kotlin.math.roundToInt

/**
 * Stands in for the shared master-tuning arithmetic, marking a channel's retune with the CENTS it was asked
 * for instead of encoding them as an RPN.
 *
 * The split into coarse semitones and fine cents lives in Swift (`MasterTuning` in SheetMusicAudioCore),
 * where `MasterTuningTests` pins it and the Apple engine reads it from the same place. What is left on this
 * side — and what was actually wrong on Android once — is WHICH cents each channel is retuned by. A marker
 * lets the assertions say that outright, where a decoded RPN said it by arithmetic and so re-tested Swift's
 * job through a Kotlin copy of it.
 *
 * Marker values are tenths of a cent, so a fractional calibration is still visible in the call log.
 */
internal object MarkerMasterTuning {
    /** An otherwise unused controller number, so a marker can never be mistaken for a real message. */
    const val CONTROLLER = 3

    operator fun invoke(cents: Double): List<MidiControlChange> =
        listOf(MidiControlChange(CONTROLLER, (cents * 10).roundToInt()))

    /** The synth call-log entry that a retune of [cents] on [channel] leaves behind. */
    fun marker(channel: Int, cents: Double): String =
        "cc($channel,$CONTROLLER,${(cents * 10).roundToInt()})"
}
