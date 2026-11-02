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
 */
data class PreviewPlan(
    val generation: Long,
    val supersededVoices: List<PreviewVoice>,
    val voices: List<PreviewVoice>,
    val velocity: Int,
    val isDrum: Boolean,
    val ringMilliseconds: Int,
    val releaseTailMilliseconds: Int,
)
