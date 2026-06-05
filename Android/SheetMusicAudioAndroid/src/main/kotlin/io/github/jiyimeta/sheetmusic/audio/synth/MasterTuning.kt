package io.github.jiyimeta.sheetmusic.audio.synth

import kotlin.math.roundToInt

/**
 * A4 master-tuning math, mirroring Swift `MasterTuning` in SheetMusicAudioCore.
 * FluidSynth honors MIDI Master Tuning RPNs, so Android retunes by sending these
 * CC pairs to each melodic channel. Kept in lockstep with the Swift helper by
 * [MasterTuningTest]'s golden assertions.
 */
internal object MasterTuning {
    data class CC(val controller: Int, val value: Int)

    /** Split a cents offset (from A4=440) into nearest-semitone coarse + remaining fine cents. */
    fun split(cents: Double): Pair<Int, Double> {
        val coarse = (cents / 100.0).roundToInt()
        return coarse to (cents - 100.0 * coarse)
    }

    /** CC pairs (in order) to retune one channel by [cents] on an RPN-honoring synth. */
    fun rpnControlChanges(cents: Double): List<CC> {
        val (coarse, fineCents) = split(cents)
        val fine14 = (8192 + (fineCents / 100.0 * 8192.0).roundToInt()).coerceIn(0, 16383)
        val coarseValue = (64 + coarse).coerceIn(0, 127)
        return listOf(
            CC(101, 0), CC(100, 2), CC(6, coarseValue), CC(38, 0),
            CC(101, 0), CC(100, 1), CC(6, fine14 ushr 7), CC(38, fine14 and 0x7F),
            CC(101, 127), CC(100, 127),
        )
    }
}
