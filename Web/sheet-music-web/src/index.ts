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
export { drawPage, loadScoreFonts } from "./render/canvas.js";
export type { FontURLs, ScoreFonts } from "./render/canvas.js";

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
    return bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes);
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
