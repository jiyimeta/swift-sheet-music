/**
 * The one file that knows spessasynth exists.
 *
 * `spessasynth_lib` is an OPTIONAL peer dependency: a host that only views
 * scores should not download a SoundFont engine. That is why it is imported
 * dynamically — a static import would make this module unresolvable for such a
 * host even though it never calls into it.
 */
import type { SynthHost, SynthTransport } from "./types.js";

export interface SpessaSynthHostOptions {
  /** Must be running (`resume()`d) before playback, which needs a user gesture. */
  readonly context: AudioContext;
  /** A General MIDI SoundFont. SF2, SF3, SFOGG and DLS are all accepted. */
  readonly soundFont: ArrayBuffer;
  /**
   * URL of spessasynth's `spessasynth_processor.min.js`, which has to be served
   * as a file — an AudioWorklet module cannot be loaded from a blob built out of
   * a bundler's module graph.
   *
   * Defaults to `spessasynth_processor.min.js` resolved against the document
   * base, which is what a host that copied the file next to its page gets.
   */
  readonly processorURL?: string | URL;
  /** Where to route the audio. Defaults to `context.destination`. */
  readonly destination?: AudioNode;
}

/** The subset of spessasynth's surface this file uses. */
interface SpessaSequencer {
  currentTime: number;
  readonly currentHighResolutionTime: number;
  readonly isFinished: boolean;
  playbackRate: number;
  skipToFirstNoteOn: boolean;
  loadNewSongList(songs: { binary: ArrayBuffer; fileName?: string }[]): void;
  play(): void;
  pause(): void;
}

interface SpessaSynth {
  readonly isReady: Promise<unknown>;
  readonly soundBankManager: {
    addSoundBank(buffer: ArrayBuffer, id: string): Promise<void>;
  };
  connect(node: AudioNode): AudioNode;
  disconnect(node?: AudioNode): AudioNode | undefined;
  destroy(): void;
}

interface SpessaModule {
  WorkletSynthesizer: new (context: BaseAudioContext) => SpessaSynth;
  Sequencer: new (
    synth: SpessaSynth,
    options?: Partial<{ skipToFirstNoteOn: boolean; initialPlaybackRate: number }>,
  ) => SpessaSequencer;
}

class SpessaTransport implements SynthTransport {
  private muted = false;

  constructor(
    private readonly synth: SpessaSynth,
    private readonly sequencer: SpessaSequencer,
    private readonly gain: GainNode,
  ) {}

  /**
   * `currentHighResolutionTime` rather than `currentTime`: the smoothed one is
   * documented as the value to visualize with, because the raw one steps with
   * the audio context's own scheduling and makes a cursor stutter.
   */
  get positionSeconds(): number {
    return this.sequencer.currentHighResolutionTime;
  }

  get isAtEnd(): boolean {
    return this.sequencer.isFinished;
  }

  load(midi: Uint8Array): void {
    // A copy, not a view: `midi` may be a subarray of the wasm heap, and
    // handing that across is both a lifetime hazard and — since wasm memory can
    // move on growth — a correctness one.
    const binary = midi.slice().buffer as ArrayBuffer;
    this.sequencer.loadNewSongList([{ binary, fileName: "score.mid" }]);
    // Loading starts playback. The engine decides when to play, so park the
    // transport at the top and let it ask.
    this.sequencer.pause();
    this.sequencer.currentTime = 0;
  }

  play(): void {
    this.sequencer.play();
  }

  pause(): void {
    this.sequencer.pause();
  }

  seek(seconds: number): void {
    this.sequencer.currentTime = Math.max(0, seconds);
  }

  setRate(rate: number): void {
    this.sequencer.playbackRate = rate;
  }

  setMuted(muted: boolean): void {
    this.muted = muted;
    // Gain, not `pause()`. The transport has to keep advancing while silent, or
    // an un-mute would land wherever the clock stopped instead of on the beat.
    this.gain.gain.value = muted ? 0 : 1;
  }

  get isMuted(): boolean {
    return this.muted;
  }

  dispose(): void {
    this.sequencer.pause();
    this.synth.disconnect();
    this.synth.destroy();
  }
}

async function makeTransport(
  module: SpessaModule,
  options: SpessaSynthHostOptions,
  destination: AudioNode,
): Promise<SpessaTransport> {
  const synth = new module.WorkletSynthesizer(options.context);
  // A copy per synth. `addSoundBank` TRANSFERS the buffer to the worklet, which
  // detaches it — handing the same one to the second synth fails with
  // "ArrayBuffer at index 0 is already detached", and the metronome would be
  // the half that broke.
  await synth.soundBankManager.addSoundBank(options.soundFont.slice(0), "main");
  await synth.isReady;

  const gain = options.context.createGain();
  synth.connect(gain);
  gain.connect(destination);

  // `skipToFirstNoteOn` is the setting that would otherwise break every
  // position this package hands back: with it on, the sequencer's zero is the
  // first note-on rather than the start of the sequence, so a score with a rest
  // or a count-in in front reports positions shifted by that much and the cursor
  // sits in the wrong measure.
  const sequencer = new module.Sequencer(synth, {
    skipToFirstNoteOn: false,
    initialPlaybackRate: 1,
  });
  sequencer.skipToFirstNoteOn = false;
  sequencer.pause();
  return new SpessaTransport(synth, sequencer, gain);
}

/**
 * Build the score + metronome transport pair on one `AudioContext`.
 *
 * Both get the same SoundFont: the metronome's clicks are GM percussion (notes
 * 76 / 77 on channel 9) in the sequence `Score.renderMetronomeMidi` produced, so
 * a General MIDI bank is all it needs. Supplying a dedicated click bank is a
 * later slice.
 */
export async function createSpessaSynthHost(
  options: SpessaSynthHostOptions,
): Promise<SynthHost> {
  const module = (await import("spessasynth_lib")) as unknown as SpessaModule;
  const processorURL =
    options.processorURL ?? "spessasynth_processor.min.js";
  await options.context.audioWorklet.addModule(processorURL.toString());

  const destination = options.destination ?? options.context.destination;
  const score = await makeTransport(module, options, destination);
  const metronome = await makeTransport(module, options, destination);
  // Off until the host asks for it, and silenced by gain so its transport can
  // still be advanced in lockstep with the score's.
  metronome.setMuted(true);

  return {
    context: options.context,
    score,
    metronome,
    async dispose() {
      score.dispose();
      metronome.dispose();
      await options.context.close();
    },
  };
}
