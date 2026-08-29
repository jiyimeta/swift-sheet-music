package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Everything the engine has to do to sound one note audition, decided by shared Swift.
 *
 * Mirrors `PreviewPlanWire` in `NotePreviewCodec.swift`; the codec that fills it is generated from that
 * declaration, so a field added there and not here is a compile error rather than a silent omission.
 *
 * The decisions in here — which audition supersedes which, how long a drum rings versus a melodic note, how long
 * the audio graph has to stay alive after the note-off — are the shared `NotePreviewPolicy`'s, the same code the
 * Apple engine runs. This side executes them in FluidSynth's own messages. It used to decide them too, in a
 * hand-written copy that had neither the supersede nor the release tail, and both were audible.
 *
 * @property generation identifies this audition for the whole of its life; hand it back to end the note.
 * @property supersedesChannel channel of the audition this one replaces, or `-1` when none was sounding.
 * @property supersedesPitch pitch of that audition; meaningless when [supersedesChannel] is `-1`.
 * @property isDrum whether the note is on a drum staff. FluidSynth needs no different message for it, but the
 *   fact travels with the plan because some synths do.
 * @property ringMilliseconds how long the note rings before the engine ends it.
 * @property releaseTailMilliseconds how much longer the audio graph must keep rendering after that end.
 */
data class PreviewPlan(
    val generation: Long,
    val supersedesChannel: Int,
    val supersedesPitch: Int,
    val channel: Int,
    val pitch: Int,
    val velocity: Int,
    val isDrum: Boolean,
    val ringMilliseconds: Int,
    val releaseTailMilliseconds: Int,
)
