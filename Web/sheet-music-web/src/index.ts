/**
 * Browser and Node facade over the wasm bridge.
 *
 * `loadSheetMusic` is async even though everything under it is synchronous:
 * moving layout onto a Worker with OffscreenCanvas is a planned optimization,
 * and it can only be done without breaking hosts if the entry point was never
 * promised to be synchronous.
 */
import {
  decodeDrawProgram,
  type DrawProgramPage,
} from "./draw-program.js";

export type {
  DrawCommand,
  DrawProgramPage,
  FontId,
} from "./draw-program.js";
export {
  drawPage,
  loadScoreFonts,
  MAX_CANVAS_DIMENSION_PX,
  planPageTiles,
} from "./render/canvas.js";
export type {
  DrawPageOptions,
  FontURLs,
  PageTile,
  ScoreFonts,
} from "./render/canvas.js";

/** What the host shows in a title bar or a document list. */
export interface ScoreMetadata {
  readonly title: string;
  readonly composer: string;
  readonly partCount: number;
  readonly staffCount: number;
  /**
   * The tempo governing the start, in quarter-note BPM. MuseScore's 120 default
   * when the score sets none.
   */
  readonly openingQuarterBpm: number;
}

export interface LayoutRequest {
  /** Viewport / page width in document millimetres. */
  readonly pageWidthMM: number;
  /** Page height in document millimetres. */
  readonly pageHeightMM: number;
}

/**
 * What a transport UI needs before the first frame is drawn.
 *
 * Two lengths, not one. `totalNotatedSeconds` is the score's own; the synth
 * plays the UNROLLED sequence, whose length is `totalPlayerSeconds` and which is
 * longer on any score with repeats. Every position this package hands back or
 * takes in for playback is on the *player* clock unless its name says otherwise.
 */
export interface PlaybackSummary {
  readonly totalNotatedSeconds: number;
  readonly totalPlayerSeconds: number;
  readonly measureCount: number;
  /** Ticks per quarter note. */
  readonly division: number;
  /** The tempo governing the start, in quarter-note BPM. */
  readonly openingQuarterBpm: number;
}

/**
 * Where to draw the playback cursor, in document millimetres — the same unit
 * the draw program uses, so one `pxPerMM` scales both.
 */
export interface CursorRect {
  readonly xMM: number;
  readonly yMM: number;
  readonly widthMM: number;
  readonly heightMM: number;
  /** The measure the cursor is parked in. */
  readonly measureIndex: number;
  /**
   * The position on the score's own clock — differs from the player position
   * that produced it on any score with repeats.
   */
  readonly notatedSeconds: number;
}

/** A measure range to loop over. `toMeasureExclusive` may equal the count. */
export interface MeasureRange {
  readonly fromMeasureIndex: number;
  readonly toMeasureExclusive: number;
}

/**
 * The raw `@JS` surface BridgeJS exposes. Not part of this package's API — the
 * generated declarations live in the built bundle, which is not present at
 * type-check time, so the shape is restated here and pinned by the parity test.
 */
interface BridgeExports {
  engineVersionStamp(): string;
  loadScore(bytes: number[] | Uint8Array): number;
  releaseScore(handle: number): void;
  scoreMetadata(handle: number): ScoreMetadata | null;
  scoreFingerprint(handle: number): string;
  installSMuFLMetrics(bytes: number[] | Uint8Array): boolean;
  computeLayout(
    handle: number,
    pageWidthMM: number,
    pageHeightMM: number,
  ): number[] | Uint8Array;
  pageBreaks(handle: number, pageHeightMM: number): number[] | Float64Array;
  renderMidi(handle: number): number[] | Uint8Array;
  renderMetronomeMidi(handle: number): number[] | Uint8Array;
  renderCountInMetronomeMidi(
    handle: number,
    fromMeasureIndex: number,
  ): number[] | Uint8Array;
  countInSeconds(handle: number, fromMeasureIndex: number): number;
  playbackSummary(handle: number): PlaybackSummary | null;
  metronomeBeats(handle: number): number[] | Float64Array;
  cursorRectAtPlayerSeconds(
    handle: number,
    playerSeconds: number,
  ): CursorRect | null;
  playerSecondsForMeasure(handle: number, measureIndex: number): number;
  measureIndexAtPlayerSeconds(handle: number, playerSeconds: number): number;
  loopPlayerSeconds(
    handle: number,
    fromMeasureIndex: number,
    toMeasureExclusive: number,
  ): number[] | Float64Array;
  loopHighlightRects(
    handle: number,
    fromMeasureIndex: number,
    toMeasureExclusive: number,
  ): number[] | Float64Array;
  buildClickSoundFont(
    strongWav: number[] | Uint8Array,
    weakWav: number[] | Uint8Array,
  ): number[] | Uint8Array;
}

/**
 * BridgeJS lowers `[UInt8]` / `[Double]` as a boxed `number[]` on some paths and
 * a typed array on others, and the generated `.d.ts` says `number[]`. Normalize
 * once here rather than at a dozen call sites.
 */
function asBytes(value: number[] | Uint8Array): Uint8Array {
  return value instanceof Uint8Array ? value : Uint8Array.from(value);
}

function asDoubles(value: number[] | Float64Array): Float64Array {
  return value instanceof Float64Array ? value : Float64Array.from(value);
}

/**
 * One loaded score.
 *
 * The handle is owned by the caller: `release()` frees the score and its cached
 * layout inside wasm memory. Nothing collects it for you, so a viewer that
 * opens files in a loop and forgets leaks until the page is closed — the same
 * contract the Android bridge has.
 */
export class Score {
  private handle: number;

  constructor(
    private readonly bridge: BridgeExports,
    handle: number,
  ) {
    this.handle = handle;
  }

  private live(): number {
    if (this.handle === 0) {
      throw new Error("score has been released");
    }
    return this.handle;
  }

  get metadata(): ScoreMetadata {
    const metadata = this.bridge.scoreMetadata(this.live());
    if (metadata === null) {
      throw new Error("score has been released");
    }
    return metadata;
  }

  /**
   * FNV-1a digest with no per-process seed, so it equals the value an Apple or
   * Android build computes for the same score.
   *
   * A decimal string rather than a number: the digest is 64 bits and a
   * JavaScript number is an f64 that would round anything past 2^53.
   *
   * Scoped to the mutable musical content — notes, timing, spelling. Metadata is
   * not in it, so two scores that differ only by title share a fingerprint.
   * Treating this as "is this the same document" would be wrong.
   */
  get fingerprint(): string {
    return this.bridge.scoreFingerprint(this.live());
  }

  /** The `DrawProgramFlat` bytes, undecoded. Useful for parity checks. */
  layoutBytes(request: LayoutRequest): Uint8Array {
    const bytes = this.bridge.computeLayout(
      this.live(),
      request.pageWidthMM,
      request.pageHeightMM,
    );
    if (bytes.length === 0) {
      throw new Error("layout failed");
    }
    return asBytes(bytes);
  }

  layout(request: LayoutRequest): DrawProgramPage[] {
    return decodeDrawProgram(this.layoutBytes(request));
  }

  /**
   * Page-boundary document-Y offsets in millimetres, `[0, …, contentBottom]`.
   *
   * Requires a prior `layout()` for the same score — the boundaries are read off
   * the cached document rather than engraved afresh, which is what keeps the
   * call cheap. Returns an empty array otherwise.
   */
  pageBreaks(request: { readonly pageHeightMM: number }): number[] {
    return Array.from(this.bridge.pageBreaks(this.live(), request.pageHeightMM));
  }

  /**
   * The Standard MIDI File a synth plays: the live channel plan applied, and the
   * baked-in CC 7 / tick-0 program stripped off every mixer-owned channel so a
   * live mixer is the sole authority.
   */
  renderMidi(): Uint8Array {
    return asBytes(this.bridge.renderMidi(this.live()));
  }

  /**
   * The metronome's own sequence — the score's tempo map plus the click track.
   *
   * A second sequence rather than clicks merged into the score's, because that
   * is what makes muting the metronome a gain change: reloading a merged
   * sequence would cut every voice sounding on the score side.
   */
  renderMetronomeMidi(): Uint8Array {
    return asBytes(this.bridge.renderMetronomeMidi(this.live()));
  }

  /**
   * The metronome sequence with a count-in in front: the pre-roll's clicks fill
   * `[0, countInSeconds)` and the body's clicks sit behind them, so one
   * sequencer plays the count and then the piece.
   *
   * Empty when the position has no count-in.
   */
  renderCountInMetronomeMidi(fromMeasureIndex: number): Uint8Array {
    return asBytes(
      this.bridge.renderCountInMetronomeMidi(this.live(), fromMeasureIndex),
    );
  }

  /**
   * How long the count-in for `fromMeasureIndex` lasts. `0` means "start now".
   *
   * Watch the metronome sequencer's own position against this rather than
   * waiting it out with `setTimeout` — a wall-clock wait quantizes the downbeat
   * to whichever output buffer noticed the deadline, which is audible.
   */
  countInSeconds(fromMeasureIndex: number): number {
    return this.bridge.countInSeconds(this.live(), fromMeasureIndex);
  }

  playbackSummary(): PlaybackSummary | null {
    return this.bridge.playbackSummary(this.live());
  }

  /**
   * Click positions for a visual beat indicator, flattened as
   * `[playerSeconds, isDownbeat, …]` — two entries per beat, the flag `1` or
   * `0`.
   *
   * Only for showing beats. The clicks themselves are events in
   * `renderMetronomeMidi`'s sequence.
   */
  metronomeBeats(): Float64Array {
    return asDoubles(this.bridge.metronomeBeats(this.live()));
  }

  /**
   * Where to draw the cursor for a position on the player's clock, or `null`
   * when no layout has been computed for this score — the cached document is
   * what turns a position into geometry, so call `layout()` first.
   */
  cursorRectAtPlayerSeconds(playerSeconds: number): CursorRect | null {
    return this.bridge.cursorRectAtPlayerSeconds(this.live(), playerSeconds);
  }

  /**
   * The player position a measure starts at — a seek target. `-1` for an
   * out-of-range index, which `0` could not express: that is the top of the
   * score, a real position.
   */
  playerSecondsForMeasure(measureIndex: number): number {
    return this.bridge.playerSecondsForMeasure(this.live(), measureIndex);
  }

  /** The measure sounding at a player position, or `-1` for an empty score. */
  measureIndexAtPlayerSeconds(playerSeconds: number): number {
    return this.bridge.measureIndexAtPlayerSeconds(this.live(), playerSeconds);
  }

  /**
   * `[startSeconds, endSeconds]` on the player clock for a measure-range loop,
   * or an empty array for an empty or inverted range.
   *
   * The wrap is the host's job: a sequencer's own loop covers the whole
   * sequence, not a range inside it.
   */
  loopPlayerSeconds(range: MeasureRange): Float64Array {
    return asDoubles(
      this.bridge.loopPlayerSeconds(
        this.live(),
        range.fromMeasureIndex,
        range.toMeasureExclusive,
      ),
    );
  }

  /**
   * Rectangles to tint for a measure-range loop, flattened as
   * `[x, y, width, height, …]` in document millimetres — one per system the
   * range spans, so a loop crossing a line break highlights both halves.
   *
   * Empty until `layout()` has run for this score.
   */
  loopHighlightRects(range: MeasureRange): Float64Array {
    return asDoubles(
      this.bridge.loopHighlightRects(
        this.live(),
        range.fromMeasureIndex,
        range.toMeasureExclusive,
      ),
    );
  }

  release(): void {
    if (this.handle !== 0) {
      this.bridge.releaseScore(this.handle);
      this.handle = 0;
    }
  }
}

export class SheetMusic {
  constructor(private readonly bridge: BridgeExports) {}

  /**
   * This wasm image's build identity, as a decimal string. Compare it with a
   * cached copy's before trusting the cache. A string for the same reason
   * `Score.fingerprint` is one.
   */
  engineVersionStamp(): string {
    return this.bridge.engineVersionStamp();
  }

  /**
   * Install the Bravura glyph-metrics table. Ship
   * `@jiyimeta/sheet-music-web/assets/bravura.smft`.
   *
   * Not optional in practice: without it the engraver falls back to rectangle
   * approximations and the spacing is visibly wrong — but it still engraves, so
   * nothing else will tell you.
   */
  installSMuFLMetrics(bytes: Uint8Array): boolean {
    return this.bridge.installSMuFLMetrics(bytes);
  }

  /**
   * Build a bank-128 SoundFont from two click WAVs, mapping the strong click to
   * note 76 and the weak one to note 77 — the notes the metronome sequence
   * plays.
   *
   * Load it into the metronome's synth ahead of the score's General MIDI bank to
   * replace the GM wood blocks with your own clicks. Empty when either WAV fails
   * to parse, which means "keep the GM clicks".
   */
  buildClickSoundFont(strongWav: Uint8Array, weakWav: Uint8Array): Uint8Array {
    return asBytes(this.bridge.buildClickSoundFont(strongWav, weakWav));
  }

  /**
   * Parse `.mscx` / `.mscz` / `.musicxml` / `.mxl` / `.mid` — the format is
   * sniffed from the leading bytes.
   */
  loadScore(bytes: Uint8Array): Score {
    const handle = this.bridge.loadScore(bytes);
    if (handle === 0) {
      throw new Error("failed to parse score");
    }
    return new Score(this.bridge, handle);
  }
}

/**
 * The PackageToJS-generated bundle, imported dynamically so this package
 * type-checks without it having been built.
 */
interface GeneratedBundle {
  instantiate(options: unknown): Promise<{ exports: BridgeExports }>;
  defaultNodeSetup(options?: unknown): Promise<unknown>;
  defaultBrowserSetup(options: unknown): Promise<unknown>;
}

export interface LoadOptions {
  /**
   * Directory holding the output of `Scripts/wasm-build-web.sh` — the one
   * containing `instantiate.js`, `platforms/` and the `.wasm`.
   */
  readonly bundleURL: URL | string;
  /**
   * Which host setup to use. Defaults to `node` when `process.versions.node` is
   * present and `browser` otherwise, which is right for every case except a
   * bundler pretending to be Node.
   */
  readonly platform?: "browser" | "node";
}

function defaultPlatform(): "browser" | "node" {
  const maybeProcess = (globalThis as { process?: { versions?: { node?: string } } })
    .process;
  return maybeProcess?.versions?.node !== undefined ? "node" : "browser";
}

/** Instantiate the wasm module and return the facade. */
export async function loadSheetMusic(
  options: LoadOptions,
): Promise<SheetMusic> {
  const base = new URL(
    typeof options.bundleURL === "string"
      ? options.bundleURL
      : options.bundleURL.href,
  );
  // A directory URL must end in a slash or `new URL(relative, base)` resolves
  // against its parent.
  if (!base.pathname.endsWith("/")) {
    base.pathname += "/";
  }
  const platform = options.platform ?? defaultPlatform();

  const instantiateModule = (await import(
    /* @vite-ignore */ new URL("instantiate.js", base).href
  )) as GeneratedBundle;

  let setup: unknown;
  if (platform === "node") {
    const nodeModule = (await import(
      /* @vite-ignore */ new URL("platforms/node.js", base).href
    )) as GeneratedBundle;
    setup = await nodeModule.defaultNodeSetup({});
  } else {
    const browserModule = (await import(
      /* @vite-ignore */ new URL("platforms/browser.js", base).href
    )) as GeneratedBundle;
    setup = await browserModule.defaultBrowserSetup({
      module: fetch(new URL("sheet-music-wasm.wasm", base)),
      getImports: () => ({}),
    });
  }

  const { exports } = await instantiateModule.instantiate(setup);
  return new SheetMusic(exports);
}
