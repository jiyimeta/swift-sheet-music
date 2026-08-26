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
  /**
   * Select a patch on one channel.
   *
   * Not a convenience: the sequence carries no tick-0 program of its own — it is
   * stripped so a backward seek cannot replay it over a live override — so a
   * host that never calls this hears General MIDI's default patch, Acoustic
   * Grand Piano, on every melodic channel.
   */
  programChange(channel: number, bank: number, program: number): void;
  /** Send a MIDI control change. CC 7 is channel volume, CC 10 pan. */
  controlChange(channel: number, controller: number, value: number): void;
  /**
   * Load a SoundFont ahead of the ones already loaded, under `id`.
   *
   * Ahead, not instead: a click bank defines two percussion notes and nothing
   * else, so the General MIDI bank underneath still has to answer for
   * everything the click bank does not.
   *
   * Optional — a host without bank layering simply cannot swap the click.
   */
  addSoundBankOnTop?(soundFont: ArrayBuffer, id: string): Promise<void>;
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
  /**
   * Render the loaded score to an `AudioBuffer` faster than real time, or leave
   * it undefined if this synth cannot.
   *
   * Optional for the same reason `SynthBackend.makeOfflineInstance` returns
   * `nil` on Apple: a transport-only test double, or a synth without an offline
   * path, is still a usable host — it just cannot export.
   *
   * The render starts from the top of the sequence and carries the CURRENT
   * mixer state, so what comes out matches what is being heard. Trimming to a
   * range is the caller's job.
   */
  renderOffline?(options: {
    readonly sampleRate: number;
    readonly seconds: number;
  }): Promise<AudioBuffer>;
  dispose(): Promise<void>;
}
