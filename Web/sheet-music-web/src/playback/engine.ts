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
import type { CursorRect, MeasureRange, PlaybackSummary, Score } from "../index.js";
import type { SynthHost } from "./types.js";

export type PlaybackState = "stopped" | "counting-in" | "playing" | "paused";

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

  private currentMeasureIndex(): number {
    const index = this.score.measureIndexAtPlayerSeconds(
      this.host.score.positionSeconds,
    );
    return index < 0 ? 0 : index;
  }

  private seekBoth(seconds: number): void {
    this.host.score.seek(seconds);
    this.host.metronome.seek(seconds);
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
