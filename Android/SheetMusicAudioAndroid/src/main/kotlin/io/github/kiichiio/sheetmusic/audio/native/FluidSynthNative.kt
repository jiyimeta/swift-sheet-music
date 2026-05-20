package io.github.kiichiio.sheetmusic.audio.native

/**
 * Kotlin native bindings for FluidSynth via libsheetmusicaudio.so.
 *
 * libsheetmusicaudio.so is a thin C++ wrapper built by this module's
 * externalNativeBuild (see src/main/cpp/CMakeLists.txt). It links
 * dynamically against libfluidsynth.so from the VolcanoMobile .aar.
 *
 * All handles are opaque Long (interpreted as native pointers by the
 * C side). Pass 0L to signal "no handle / invalid".
 */
internal object FluidSynthNative {
    init { System.loadLibrary("sheetmusicaudio") }

    // ── Synth lifecycle / loading ────────────────────────────────────
    external fun newSynth(sampleRate: Int): Long       // returns native handle, 0 on failure
    external fun deleteSynth(handle: Long)
    external fun sfload(handle: Long, path: String, resetPresets: Boolean): Int
    external fun programSelect(
        handle: Long, channel: Int, sfid: Int, bank: Int, program: Int,
    ): Int

    // ── Voice control ────────────────────────────────────────────────
    external fun noteOn(handle: Long, channel: Int, pitch: Int, velocity: Int): Int
    external fun noteOff(handle: Long, channel: Int, pitch: Int): Int
    external fun allNotesOff(handle: Long, channel: Int): Int
    external fun cc(handle: Long, channel: Int, controller: Int, value: Int): Int
    /**
     * Reads the current value of MIDI CC [controller] on [channel].
     * Returns the CC value (0–127), or -1 on failure.
     */
    external fun getCC(handle: Long, channel: Int, controller: Int): Int
    external fun setGain(handle: Long, value: Float)
    /**
     * Sets the channel type for [channel].
     * [type]: 0 = CHANNEL_TYPE_MELODIC, 1 = CHANNEL_TYPE_DRUM.
     * Locks the channel into drum or melodic semantics regardless of channel number.
     */
    external fun setChannelType(handle: Long, channel: Int, type: Int): Int

    // ── Rendering ────────────────────────────────────────────────────
    /**
     * Render [frameCount] stereo float samples into [left] / [right] at
     * offset 0, stride 1. Returns FluidSynth's status code (0 on success).
     */
    external fun writeFloat(
        handle: Long, frameCount: Int,
        left: FloatArray, right: FloatArray,
    ): Int

    // ── Player ───────────────────────────────────────────────────────
    external fun newPlayer(synthHandle: Long): Long
    external fun deletePlayer(handle: Long)
    external fun playerAddMem(handle: Long, bytes: ByteArray): Int
    external fun playerPlay(handle: Long): Int
    external fun playerStop(handle: Long): Int
    external fun playerJoin(handle: Long): Int
    external fun playerSeek(handle: Long, tick: Long): Int
    external fun playerGetCurrentTick(handle: Long): Long
}
