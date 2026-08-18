/**
 * What the playback engine needs from a synth, and nothing more.
 *
 * `engine.ts` is written against this rather than against spessasynth so the
 * transport logic can be tested without an `AudioContext` — Node has none — and
 * so a different synth can be substituted without touching the engine. Only
 * `synth.ts` names the upstream package.
 */
export interface SynthTransport {
  /**
   * Elapsed SMF seconds, NOT wall-clock seconds: already divided by the rate, so
   * it can be handed straight to `Score.cursorRectAtPlayerSeconds`.
   */
  readonly positionSeconds: number;
  /** Whether the transport has run out of events. */
  readonly isAtEnd: boolean;
  /** Replace the loaded sequence. Leaves the transport paused at 0. */
  load(midi: Uint8Array): void;
  play(): void;
  pause(): void;
  seek(seconds: number): void;
  setRate(rate: number): void;
  /**
   * Silence or restore the output WITHOUT stopping the transport — an un-mute
   * has to land on the beat, which it cannot do if the clock stopped meanwhile.
   */
  setMuted(muted: boolean): void;
  dispose(): void;
}

/**
 * A pair of transports sharing one audio graph: the score's and the
 * metronome's.
 *
 * Two rather than one merged sequence, matching the Apple engine's separate
 * score and metronome synths and Android's two FluidSynth players. The reason is
 * the same on all three: muting the metronome has to be a gain change, and
 * reloading a merged sequence would cut every voice sounding on the score side.
 */
export interface SynthHost {
  readonly context: BaseAudioContext;
  readonly score: SynthTransport;
  readonly metronome: SynthTransport;
  dispose(): Promise<void>;
}
