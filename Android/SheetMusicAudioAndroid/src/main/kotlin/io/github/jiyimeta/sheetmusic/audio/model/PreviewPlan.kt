package io.github.jiyimeta.sheetmusic.audio.model

/**
 * One note of an audition, as the pair of MIDI coordinates that identify it. Mirrors `PreviewVoiceWire` in
 * `NotePreviewCodec.swift`.
 */
data class PreviewVoice(
    val channel: Int,
    val pitch: Int,
)

/**
 * One move of a channel's pitch wheel an audition makes before its notes start: [value] (14-bit, [CENTER] for none)
 * on [channel]. Mirrors `PreviewPitchBendWire` in `NotePreviewCodec.swift`.
 */
data class PreviewPitchBend(
    val channel: Int,
    val value: Int,
) {
    companion object {
        /** The wheel at rest — a plain note, a drum, playback's start. MIDI's own center, not a choice of ours. */
        const val CENTER = 8192
    }
}

/**
 * One note a host asks the engine to audition: the note [noteId] names, sounded at [pitch] — or the note's own for a
 * negative one — and, with an explicit pitch, bent by [cents]. The note's own pitch sounds with the note's own
 * microtonal offset, read from the score; [cents] is for a grace note, which its host auditions through its parent's
 * `NoteID` at the grace's pitch, and whose accidental the parent's ID cannot reach.
 */
data class PreviewNote(
    val noteId: NoteID,
    val pitch: Int = -1,
    val cents: Double = 0.0,
)

/**
 * Everything the engine has to do to sound one audition — one or more notes struck together — decided by shared
 * Swift.
 *
 * Mirrors `PreviewPlanWire` in `NotePreviewCodec.swift`; the codec that fills it is generated from that
 * declaration, so a field added there and not here is a compile error rather than a silent omission.
 *
 * The decisions in here — which audition supersedes which, how long a drum rings versus a melodic note, how long
 * the audio graph has to stay alive after the note-off — are the shared `NotePreviewPolicy`'s, the same code the
 * Apple engine runs. This side executes them in the synth's own messages. It used to decide them too, in a
 * hand-written copy that had neither the supersede nor the release tail, and both were audible.
 *
 * @property generation identifies this audition for the whole of its life; hand it back to end the notes.
 * @property supersededVoices the notes of the audition this one replaces, to silence first; empty when none was
 *   sounding.
 * @property voices the notes to strike, never empty. A tap on a beat strikes every note starting there.
 * @property isDrum whether any of the notes is on a drum staff. SwiftySynth needs no different message for it, but
 *   the fact travels with the plan because some synths do.
 * @property ringMilliseconds how long the notes ring before the engine ends them.
 * @property releaseTailMilliseconds how much longer the audio graph must keep rendering after that end.
 * @property pitchBends the pitch wheels to move before the notes start, in order: the center back on a channel an
 *   earlier audition bent, then the struck notes' microtonal offset — one channel carries one wheel, so a beat sounds
 *   under its last note's, as playback does. Empty for a plain audition on unbent channels.
 */
data class PreviewPlan(
    val generation: Long,
    val supersededVoices: List<PreviewVoice>,
    val voices: List<PreviewVoice>,
    val velocity: Int,
    val isDrum: Boolean,
    val ringMilliseconds: Int,
    val releaseTailMilliseconds: Int,
    val pitchBends: List<PreviewPitchBend> = emptyList(),
)
