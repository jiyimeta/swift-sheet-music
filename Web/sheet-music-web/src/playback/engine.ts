/**
 * Transport, cursor, loop and count-in over a `SynthHost`.
 *
 * The division of labour matches Android's: WebAssembly owns the score and
 * answers questions about it (what to play, where the cursor goes, where a
 * measure starts on the player's clock); this file owns the transport and the
 * poll loop. Nothing here parses or engraves.
 *
 * Every position is on the PLAYER clock — the unrolled sequence the synth
 * actually plays, which is longer than the score on anything with repeats. The
 * bridge converts; this file never does arithmetic on times beyond comparing
 * them.
 */
import type {
  CursorRect,
  MeasureRange,
  MixerStrip,
  PlaybackSummary,
  Score,
} from "../index.js";
import type { SynthHost } from "./types.js";
import { encodeWav, sliceBuffer } from "./wav.js";

export interface AudioExportOptions {
  /** Defaults to 44100. */
  readonly sampleRate?: number;
  /**
   * Measures to export, or the whole score when omitted. Pass the active loop's
   * range to write exactly what is being looped.
   */
  readonly range?: MeasureRange;
  /**
   * Extra seconds rendered past the end so release tails are not cut off.
   * Defaults to 2. Applies to the score's end, not to a range's.
   */
  readonly tailSeconds?: number;
}

export type PlaybackState = "stopped" | "counting-in" | "playing" | "paused";

/** A strip plus whatever the host has changed about it. */
export interface MixerChannelState {
  readonly strip: MixerStrip;
  /** GM patch in force. Starts at `strip.program`. */
  readonly program: number;
  /** CC 7 in force, 0–127. Starts at `strip.volume`. */
  readonly volume: number;
  readonly muted: boolean;
}

/**
 * Injected so the poll loop can be driven by hand under test. Node has no
 * `requestAnimationFrame`, and a test that waited on real frames would be both
 * slow and flaky.
 */
export interface FrameScheduler {
  request(callback: () => void): number;
  cancel(id: number): void;
}

export interface PlaybackEngineOptions {
  readonly score: Score;
  readonly host: SynthHost;
  /** Fired on every polled frame while the transport is moving. */
  readonly onCursor?: (rect: CursorRect | null) => void;
  readonly onStateChange?: (state: PlaybackState) => void;
  /** Defaults to `requestAnimationFrame` / `cancelAnimationFrame`. */
  readonly scheduler?: FrameScheduler;
}

function defaultScheduler(): FrameScheduler {
  const raf = (globalThis as {
    requestAnimationFrame?: (cb: () => void) => number;
    cancelAnimationFrame?: (id: number) => void;
  });
  if (raf.requestAnimationFrame && raf.cancelAnimationFrame) {
    return {
      request: (cb) => raf.requestAnimationFrame!(cb),
      cancel: (id) => raf.cancelAnimationFrame!(id),
    };
  }
  // A host without rAF (a Worker, Node) gets a timer. 16 ms rather than 0 so a
  // runaway loop cannot starve the thread.
  return {
    request: (cb) => setTimeout(cb, 16) as unknown as number,
    cancel: (id) => clearTimeout(id as unknown as ReturnType<typeof setTimeout>),
  };
}

export class PlaybackEngine {
  private _state: PlaybackState = "stopped";
  private frameId: number | null = null;
  private disposed = false;
  /** `[startSeconds, endSeconds]` on the player clock, or `null`. */
  private loopBounds: [number, number] | null = null;
  private loopRange: MeasureRange | null = null;
  /** Where a count-in-started playback begins once the count elapses. */
  private countInTarget: { measureIndex: number; seconds: number } | null = null;
  private rate = 1;
  private metronomeMuted = true;
  /** Mixer state, keyed by MIDI channel. */
  private readonly mixer = new Map<number, MixerChannelState>();

  private constructor(
    private readonly score: Score,
    private readonly host: SynthHost,
    private readonly summary: PlaybackSummary,
    private readonly scheduler: FrameScheduler,
    private readonly onCursor?: (rect: CursorRect | null) => void,
    private readonly onStateChange?: (state: PlaybackState) => void,
  ) {}

  /**
   * Load both sequences and park at the top.
   *
   * Rendering the SMFs is the expensive part and happens once here rather than
   * per play, because the score does not change under playback — editing has not
   * reached this surface.
   */
  static async create(options: PlaybackEngineOptions): Promise<PlaybackEngine> {
    const summary = options.score.playbackSummary();
    if (summary === null) {
      throw new Error("score has been released");
    }
    const engine = new PlaybackEngine(
      options.score,
      options.host,
      summary,
      options.scheduler ?? defaultScheduler(),
      options.onCursor,
      options.onStateChange,
    );
    engine.host.score.load(options.score.renderMidi());
    engine.host.metronome.load(options.score.renderMetronomeMidi());
    engine.host.metronome.setMuted(true);
    for (const strip of options.score.mixerStrips()) {
      engine.mixer.set(strip.channel, {
        strip,
        program: strip.program,
        volume: strip.volume,
        muted: false,
      });
    }
    engine.assertMixer();
    return engine;
  }

  get state(): PlaybackState {
    return this._state;
  }

  /** The current position on the player clock. */
  get playerSeconds(): number {
    return this.host.score.positionSeconds;
  }

  get playbackSummary(): PlaybackSummary {
    return this.summary;
  }

  /**
   * Start (or resume) playback.
   *
   * With `countIn`, the metronome transport is loaded with the count-in sequence
   * and started alone; the score transport joins on the polled frame the
   * pre-roll elapses. The wait is watched on the metronome's own clock rather
   * than `setTimeout` — a wall-clock wait quantizes the downbeat to whichever
   * output buffer noticed the deadline, which is audible as an unsteady count.
   */
  async play(options?: { countIn?: boolean }): Promise<void> {
    this.assertLive();
    if (this._state === "playing" || this._state === "counting-in") return;

    const context = this.host.context as AudioContext;
    if (typeof context.resume === "function" && context.state === "suspended") {
      await context.resume();
    }

    if (options?.countIn === true && this._state !== "paused") {
      const measureIndex = this.currentMeasureIndex();
      const sequence = this.score.renderCountInMetronomeMidi(measureIndex);
      const seconds = this.score.countInSeconds(measureIndex);
      if (sequence.length > 0 && seconds > 0) {
        const target = this.score.playerSecondsForMeasure(measureIndex);
        this.countInTarget = { measureIndex, seconds };
        this.host.metronome.load(sequence);
        // The count has to be audible whatever the metronome toggle says:
        // counting in is an explicit request, not the toggle.
        this.host.metronome.setMuted(false);
        this.host.metronome.setRate(this.rate);
        this.host.score.seek(target >= 0 ? target : 0);
        this.host.metronome.play();
        this.setState("counting-in");
        this.startPolling();
        return;
      }
      // No count-in at this position; fall through to an ordinary start.
    }

    this.assertMixer();
    this.host.score.play();
    this.host.metronome.play();
    this.setState("playing");
    this.startPolling();
  }

  pause(): void {
    this.assertLive();
    if (this._state === "stopped") return;
    this.host.score.pause();
    this.host.metronome.pause();
    this.stopPolling();
    this.setState("paused");
    this.emitCursor();
  }

  /** Stop and rewind to the top, clearing any pending count-in. */
  stop(): void {
    this.assertLive();
    this.host.score.pause();
    this.host.metronome.pause();
    this.stopPolling();
    this.countInTarget = null;
    this.restoreBodyMetronome();
    this.seekBoth(this.loopBounds ? this.loopBounds[0] : 0);
    this.setState("stopped");
    this.onCursor?.(null);
  }

  seekToMeasure(measureIndex: number): void {
    this.assertLive();
    const seconds = this.score.playerSecondsForMeasure(measureIndex);
    if (seconds < 0) return;
    this.seekBoth(seconds);
    this.emitCursor();
  }

  setRate(rate: number): void {
    this.assertLive();
    this.rate = rate;
    // Both transports, always. Sending it to one leaves the clicks drifting
    // away from the piece.
    this.host.score.setRate(rate);
    this.host.metronome.setRate(rate);
  }

  setMetronomeMuted(muted: boolean): void {
    this.assertLive();
    this.metronomeMuted = muted;
    // Not while counting in: the count stays audible until it ends, and
    // `restoreBodyMetronome` applies this flag then.
    if (this._state !== "counting-in") {
      this.host.metronome.setMuted(muted);
    }
  }

  // MARK: mixer

  /** One entry per deduped (part × instrument) strip, in score order. */
  mixerChannels(): MixerChannelState[] {
    return [...this.mixer.values()];
  }

  /** Select a patch. Ignored for a percussion strip, whose program is inert. */
  setStripProgram(channel: number, program: number): void {
    this.assertLive();
    const state = this.mixer.get(channel);
    if (state === undefined || state.strip.isDrums) return;
    this.mixer.set(channel, { ...state, program });
    this.assertStrip(channel);
  }

  /** CC 7, 0–127. */
  setStripVolume(channel: number, volume: number): void {
    this.assertLive();
    const state = this.mixer.get(channel);
    if (state === undefined) return;
    this.mixer.set(channel, { ...state, volume: Math.max(0, Math.min(127, volume)) });
    this.assertStrip(channel);
  }

  /**
   * Mute by sending CC 7 = 0 rather than by silencing a node: the strips share
   * one synth, so there is no per-strip node to turn down, and a channel volume
   * of zero is what the mixer already speaks in.
   */
  setStripMuted(channel: number, muted: boolean): void {
    this.assertLive();
    const state = this.mixer.get(channel);
    if (state === undefined) return;
    this.mixer.set(channel, { ...state, muted });
    this.assertStrip(channel);
  }

  /** Pass `null` to clear. An empty or inverted range also clears. */
  setLoop(range: MeasureRange | null): void {
    this.assertLive();
    if (range === null) {
      this.loopRange = null;
      this.loopBounds = null;
      return;
    }
    const bounds = this.score.loopPlayerSeconds(range);
    const start = bounds.at(0);
    const end = bounds.at(1);
    if (bounds.length !== 2 || start === undefined || end === undefined) {
      this.loopRange = null;
      this.loopBounds = null;
      return;
    }
    this.loopRange = range;
    this.loopBounds = [start, end];
  }

  /**
   * Rectangles to tint for the active loop, flattened as `[x, y, w, h, …]` in
   * document millimetres. Empty when no loop is set.
   */
  loopHighlightRects(): Float64Array {
    if (this.loopRange === null) return new Float64Array(0);
    return this.score.loopHighlightRects(this.loopRange);
  }

  // MARK: export

  /** Whether this host can export at all. */
  get canExport(): boolean {
    return typeof this.host.renderOffline === "function";
  }

  /**
   * Render the score to a 16-bit PCM `.wav`, faster than real time.
   *
   * Carries the mixer exactly as it stands, so the file matches what is being
   * heard. The metronome does not: clicks are a rehearsal aid, and no other
   * platform's export includes them either.
   *
   * A range is rendered by trimming a full-score render rather than by starting
   * the transport inside the sequence, which an offline render cannot be asked
   * for. The audible difference is at the leading edge: a note already ringing
   * there is cut mid-tail instead of re-struck — the same thing looping that
   * range sounds like.
   *
   * Throws when the host has no offline path (`canExport` is `false`).
   */
  async exportWav(options: AudioExportOptions = {}): Promise<Uint8Array> {
    this.assertLive();
    const renderOffline = this.host.renderOffline;
    if (renderOffline === undefined) {
      throw new Error("this synth host cannot render offline");
    }

    const sampleRate = options.sampleRate ?? 44_100;
    const tail = options.tailSeconds ?? 2;
    const bounds = options.range ? this.score.loopPlayerSeconds(options.range) : null;
    if (options.range !== undefined && bounds !== null && bounds.length !== 2) {
      throw new Error("the export range resolves to no measures");
    }

    const start = bounds?.at(0) ?? 0;
    const end = bounds?.at(1) ?? this.summary.totalPlayerSeconds;
    // The whole sequence is rendered either way — the transport cannot be
    // started partway through — so the length asked for is always the end of
    // the range, plus the tail when that end is the end of the score.
    const rendersToScoreEnd = end >= this.summary.totalPlayerSeconds - 1e-9;
    const buffer = await renderOffline.call(this.host, {
      sampleRate,
      seconds: end + (rendersToScoreEnd ? tail : 0),
    });

    return encodeWav(
      start > 0 ? sliceBuffer(buffer, start, buffer.duration) : buffer,
    );
  }

  dispose(): void {
    if (this.disposed) return;
    this.stopPolling();
    this.disposed = true;
  }

  // MARK: internals

  private assertLive(): void {
    if (this.disposed) {
      throw new Error("playback engine has been disposed");
    }
  }

  private setState(state: PlaybackState): void {
    if (this._state === state) return;
    this._state = state;
    this.onStateChange?.(state);
  }

  /**
   * Push every strip's program and volume at the synth.
   *
   * Called after the sequence is loaded and after every transport move. Once
   * would not be enough: loading a song and seeking both reset a sequencer's
   * channel state, and the sequence carries no program or CC 7 of its own to
   * restore it — that is exactly what was stripped so a seek could not fight a
   * live override. Six MIDI messages per strip-ful, which is nothing next to
   * being on the wrong instrument.
   */
  private assertMixer(): void {
    for (const channel of this.mixer.keys()) this.assertStrip(channel);
  }

  private assertStrip(channel: number): void {
    const state = this.mixer.get(channel);
    if (state === undefined) return;
    if (!state.strip.isDrums) {
      this.host.score.programChange(channel, state.strip.bank, state.program);
    }
    this.host.score.controlChange(channel, 7, state.muted ? 0 : state.volume);
  }

  private currentMeasureIndex(): number {
    const index = this.score.measureIndexAtPlayerSeconds(
      this.host.score.positionSeconds,
    );
    return index < 0 ? 0 : index;
  }

  private seekBoth(seconds: number): void {
    this.host.score.seek(seconds);
    this.host.metronome.seek(seconds);
    // A seek resets the sequencer's channel state, and the sequence has no
    // program or CC 7 of its own to put it back.
    this.assertMixer();
  }

  /**
   * Swap the count-in sequence back out for the plain body one and re-apply the
   * host's metronome toggle. Idempotent, so `stop()` can call it unconditionally.
   */
  private restoreBodyMetronome(): void {
    if (this.countInTarget === null) return;
    this.countInTarget = null;
    this.host.metronome.load(this.score.renderMetronomeMidi());
    this.host.metronome.setRate(this.rate);
    this.host.metronome.setMuted(this.metronomeMuted);
  }

  private startPolling(): void {
    if (this.frameId !== null) return;
    const tick = () => {
      this.frameId = null;
      if (this.disposed) return;
      this.poll();
      if (this._state === "playing" || this._state === "counting-in") {
        this.frameId = this.scheduler.request(tick);
      }
    };
    this.frameId = this.scheduler.request(tick);
  }

  private stopPolling(): void {
    if (this.frameId === null) return;
    this.scheduler.cancel(this.frameId);
    this.frameId = null;
  }

  /** One polled frame. Public only to the class; the scheduler drives it. */
  private poll(): void {
    if (this._state === "counting-in") {
      const target = this.countInTarget;
      if (target !== null && this.host.metronome.positionSeconds >= target.seconds) {
        // The metronome sequence runs `seconds` ahead of the score's, so both
        // clocks agree from here on without any further correction.
        this.restoreBodyMetronome();
        this.assertMixer();
        this.host.score.play();
        this.setState("playing");
      }
      this.emitCursor();
      return;
    }

    if (this.loopBounds !== null) {
      const [start, end] = this.loopBounds;
      if (this.host.score.positionSeconds >= end) {
        this.seekBoth(start);
        this.emitCursor();
        return;
      }
    } else if (this.host.score.isAtEnd) {
      this.stop();
      return;
    }

    this.emitCursor();
  }

  private emitCursor(): void {
    if (this.onCursor === undefined) return;
    this.onCursor(
      this.score.cursorRectAtPlayerSeconds(this.host.score.positionSeconds),
    );
  }
}

export function createPlaybackEngine(
  options: PlaybackEngineOptions,
): Promise<PlaybackEngine> {
  return PlaybackEngine.create(options);
}
