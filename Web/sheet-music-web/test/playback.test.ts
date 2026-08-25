/**
 * Pins the WebAssembly build's playback data against the Apple one.
 *
 * `MidiRenderer` is deterministic and so are `LiveChannelPlan` and
 * `MidiSynthPostProcess`, so identical input must give byte-identical SMFs on
 * both builds. That equality is the same kind of evidence the draw-program
 * comparison in `bridge.test.ts` provides, for the other half of the engine.
 *
 * The fixture's middle measure repeats on purpose. Without a repeat the notated
 * and player clocks coincide, every conversion `PlaybackClock` makes is the
 * identity, and a build that dropped the projection entirely would still match.
 *
 * Expected values come from `swift run GenWebFixtures`, never typed by hand.
 * Requires `Scripts/wasm-build-web.sh` to have run.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { loadSheetMusic, type Score, type SheetMusic } from "../src/index.js";

const fixturePath = (name: string) =>
  fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));

const scoreBytes = new Uint8Array(readFileSync(fixturePath("repeat.mscz")));
const expectations = JSON.parse(
  readFileSync(fixturePath("repeat-playback.json"), "utf8"),
) as {
  totalNotatedSeconds: number;
  totalPlayerSeconds: number;
  measureCount: number;
  division: number;
  openingQuarterBpm: number;
  midiByteCount: number;
  midiDigest: number;
  metronomeMidiByteCount: number;
  metronomeMidiDigest: number;
  metronomeBeatCount: number;
  measureStartPlayerSeconds: number[];
  cursorProbes: {
    playerSeconds: number;
    xMM: number;
    yMM: number;
    widthMM: number;
    heightMM: number;
    measureIndex: number;
    notatedSeconds: number;
  }[];
};

/** The metrics table the browser installs, so both sides measure alike. */
const metricsBytes = new Uint8Array(
  readFileSync(fileURLToPath(new URL("../assets/bravura.smft", import.meta.url))),
);

/** FNV-1a, 32-bit — the same walk `GenWebFixtures.digest` does in Swift. */
function digest(bytes: Uint8Array): number {
  let hash = 2166136261;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

describe("playback parity with the Apple build", () => {
  let sheetMusic: SheetMusic;
  let score: Score;

  beforeAll(async () => {
    sheetMusic = await loadSheetMusic({
      bundleURL: new URL("../dist/", import.meta.url),
      platform: "node",
    });
    expect(sheetMusic.installSMuFLMetrics(metricsBytes)).toBe(true);
    score = sheetMusic.loadScore(scoreBytes);
    // The cursor rects come off the cached document, so a layout has to exist —
    // and it has to be the same one the fixture generator laid out.
    score.layout({ pageWidthMM: 210, pageHeightMM: 297 });
  });

  afterAll(() => {
    score?.release();
  });

  it("renders the same score SMF bytes", () => {
    const midi = score.renderMidi();
    expect(midi.length).toBe(expectations.midiByteCount);
    expect(digest(midi)).toBe(expectations.midiDigest);
  });

  it("renders the same metronome SMF bytes", () => {
    const midi = score.renderMetronomeMidi();
    expect(midi.length).toBe(expectations.metronomeMidiByteCount);
    expect(digest(midi)).toBe(expectations.metronomeMidiDigest);
  });

  it("reports the same summary", () => {
    const summary = score.playbackSummary();
    expect(summary).not.toBeNull();
    expect(summary!.measureCount).toBe(expectations.measureCount);
    expect(summary!.division).toBe(expectations.division);
    expect(summary!.openingQuarterBpm).toBeCloseTo(
      expectations.openingQuarterBpm,
      9,
    );
    expect(summary!.totalNotatedSeconds).toBeCloseTo(
      expectations.totalNotatedSeconds,
      9,
    );
    expect(summary!.totalPlayerSeconds).toBeCloseTo(
      expectations.totalPlayerSeconds,
      9,
    );
  });

  /** The property the fixture exists to exercise. */
  it("the repeat makes the player clock longer than the notated one", () => {
    const summary = score.playbackSummary()!;
    expect(summary.totalPlayerSeconds).toBeGreaterThan(
      summary.totalNotatedSeconds,
    );
  });

  it("seeks each measure to the same player position", () => {
    expect(expectations.measureStartPlayerSeconds.length).toBe(
      expectations.measureCount,
    );
    expectations.measureStartPlayerSeconds.forEach((seconds, index) => {
      expect(score.playerSecondsForMeasure(index)).toBeCloseTo(seconds, 9);
    });
  });

  it("round-trips beat positions through player seconds", () => {
    const positions = [
      { measureIndex: 0, tickInMeasure: 0 },
      { measureIndex: 1, tickInMeasure: 480 },
      { measureIndex: 1, tickInMeasure: 960 },
      { measureIndex: 2, tickInMeasure: 0 },
    ];
    for (const position of positions) {
      const seconds = score.playerSecondsForPosition(position);
      expect(seconds).toBeGreaterThanOrEqual(0);
      expect(score.positionAtPlayerSeconds(seconds)).toEqual(position);
    }
  });

  it("uses null for an unresolved player position", () => {
    const missing = score.positionAtPlayerSeconds(
      expectations.totalPlayerSeconds + 100,
    );
    expect(missing).toBeNull();
  });

  it("resolves the same cursor rects", () => {
    expect(expectations.cursorProbes.length).toBeGreaterThan(0);
    for (const probe of expectations.cursorProbes) {
      const rect = score.cursorRectAtPlayerSeconds(probe.playerSeconds);
      expect(rect).not.toBeNull();
      expect(rect!.xMM).toBeCloseTo(probe.xMM, 9);
      expect(rect!.yMM).toBeCloseTo(probe.yMM, 9);
      expect(rect!.widthMM).toBeCloseTo(probe.widthMM, 9);
      expect(rect!.heightMM).toBeCloseTo(probe.heightMM, 9);
      expect(rect!.measureIndex).toBe(probe.measureIndex);
      expect(rect!.notatedSeconds).toBeCloseTo(probe.notatedSeconds, 9);
    }
  });

  it("counts the same metronome beats", () => {
    const beats = score.metronomeBeats();
    expect(beats.length).toBe(expectations.metronomeBeatCount * 2);
  });

  it("hands back an ordered loop pair for the whole score", () => {
    const pair = score.loopPlayerSeconds({
      fromMeasureIndex: 0,
      toMeasureExclusive: expectations.measureCount,
    });
    expect(Array.from(pair)).toHaveLength(2);
    expect(pair[0]).toBe(0);
    expect(pair[1]).toBeCloseTo(expectations.totalPlayerSeconds, 9);
  });

  it("fails safely after release", () => {
    const throwaway = sheetMusic.loadScore(scoreBytes);
    throwaway.release();
    expect(() => throwaway.renderMidi()).toThrow();
    expect(() => throwaway.playbackSummary()).toThrow();
    expect(() => throwaway.cursorRectAtPlayerSeconds(0)).toThrow();
  });
});
