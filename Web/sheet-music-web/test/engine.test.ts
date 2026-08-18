/**
 * The transport state machine, driven with a fake synth and a hand-cranked
 * scheduler.
 *
 * No audio and no `AudioContext`: what is under test is the sequencing of
 * play / pause / seek / loop-wrap / count-in, all of which is decided in
 * TypeScript. Whether spessasynth then makes a sound is its own concern and is
 * covered by the browser run in `e2e/playback.spec.ts`.
 *
 * The score side IS real — a fixture parsed by the wasm bridge — because the
 * positions the engine compares are the ones the bridge computes, and a stubbed
 * score would make the loop and count-in assertions vacuous.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { loadSheetMusic, type Score, type SheetMusic } from "../src/index.js";
import { PlaybackEngine } from "../src/playback/engine.js";
import type { FrameScheduler } from "../src/playback/engine.js";
import type { SynthHost, SynthTransport } from "../src/playback/types.js";

const fixturePath = (name: string) =>
  fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));

const metricsBytes = new Uint8Array(
  readFileSync(fileURLToPath(new URL("../assets/bravura.smft", import.meta.url))),
);

class FakeTransport implements SynthTransport {
  positionSeconds = 0;
  isAtEnd = false;
  loaded: Uint8Array | null = null;
  playing = false;
  rate = 1;
  muted = false;
  loadCount = 0;
  readonly seeks: number[] = [];

  load(midi: Uint8Array): void {
    this.loaded = midi;
    this.loadCount += 1;
    this.positionSeconds = 0;
    this.playing = false;
  }

  play(): void {
    this.playing = true;
  }

  pause(): void {
    this.playing = false;
  }

  seek(seconds: number): void {
    this.positionSeconds = seconds;
    this.seeks.push(seconds);
  }

  setRate(rate: number): void {
    this.rate = rate;
  }

  setMuted(muted: boolean): void {
    this.muted = muted;
  }

  dispose(): void {
    this.playing = false;
  }
}

class FakeHost implements SynthHost {
  readonly score = new FakeTransport();
  readonly metronome = new FakeTransport();
  readonly context = {
    state: "running",
    resume: async () => {},
  } as unknown as BaseAudioContext;

  async dispose(): Promise<void> {}
}

/** Runs queued frames on demand instead of on a real animation frame. */
class ManualScheduler implements FrameScheduler {
  private queue = new Map<number, () => void>();
  private next = 1;

  request(callback: () => void): number {
    const id = this.next++;
    this.queue.set(id, callback);
    return id;
  }

  cancel(id: number): void {
    this.queue.delete(id);
  }

  /** Runs every currently-queued frame once. */
  tick(times = 1): void {
    for (let i = 0; i < times; i++) {
      const pending = [...this.queue.entries()];
      this.queue.clear();
      for (const [, callback] of pending) callback();
    }
  }
}

describe("PlaybackEngine", () => {
  let sheetMusic: SheetMusic;
  let score: Score;

  beforeAll(async () => {
    sheetMusic = await loadSheetMusic({
      bundleURL: new URL("../dist/", import.meta.url),
      platform: "node",
    });
    expect(sheetMusic.installSMuFLMetrics(metricsBytes)).toBe(true);
    score = sheetMusic.loadScore(
      new Uint8Array(readFileSync(fixturePath("repeat.mscz"))),
    );
    // The cursor rect comes off the cached layout, so playback needs one.
    score.layout({ pageWidthMM: 210, pageHeightMM: 297 });
  });

  afterAll(() => {
    score?.release();
  });

  async function makeEngine(host = new FakeHost(), scheduler = new ManualScheduler()) {
    const cursors: (unknown | null)[] = [];
    const states: string[] = [];
    const engine = await PlaybackEngine.create({
      score,
      host,
      scheduler,
      onCursor: (rect) => cursors.push(rect),
      onStateChange: (state) => states.push(state),
    });
    return { engine, host, scheduler, cursors, states };
  }

  it("loads both sequences up front and parks them", async () => {
    const { host } = await makeEngine();
    expect(host.score.loaded?.length).toBeGreaterThan(14);
    expect(host.metronome.loaded?.length).toBeGreaterThan(14);
    expect(host.score.playing).toBe(false);
    expect(host.metronome.muted).toBe(true);
  });

  it("starts both transports on play", async () => {
    const { engine, host } = await makeEngine();
    await engine.play();
    expect(engine.state).toBe("playing");
    expect(host.score.playing).toBe(true);
    expect(host.metronome.playing).toBe(true);
  });

  it("stops both transports on pause", async () => {
    const { engine, host } = await makeEngine();
    await engine.play();
    engine.pause();
    expect(engine.state).toBe("paused");
    expect(host.score.playing).toBe(false);
    expect(host.metronome.playing).toBe(false);
  });

  it("seeks both transports to a measure's player position", async () => {
    const { engine, host } = await makeEngine();
    engine.seekToMeasure(2);
    const expected = score.playerSecondsForMeasure(2);
    expect(expected).toBeGreaterThan(0);
    expect(host.score.positionSeconds).toBeCloseTo(expected, 9);
    expect(host.metronome.positionSeconds).toBeCloseTo(expected, 9);
  });

  it("ignores a seek to a measure that does not exist", async () => {
    const { engine, host } = await makeEngine();
    engine.seekToMeasure(9999);
    expect(host.score.seeks).toHaveLength(0);
  });

  /** One transport at a different rate is clicks drifting away from the piece. */
  it("sends the rate to both transports", async () => {
    const { engine, host } = await makeEngine();
    engine.setRate(0.5);
    expect(host.score.rate).toBe(0.5);
    expect(host.metronome.rate).toBe(0.5);
  });

  it("mutes only the metronome, and does not stop its transport", async () => {
    const { engine, host } = await makeEngine();
    await engine.play();
    engine.setMetronomeMuted(false);
    expect(host.metronome.muted).toBe(false);
    engine.setMetronomeMuted(true);
    expect(host.metronome.muted).toBe(true);
    expect(host.metronome.playing).toBe(true);
    expect(host.score.muted).toBe(false);
  });

  it("wraps both transports back to the loop start", async () => {
    const { engine, host, scheduler } = await makeEngine();
    engine.setLoop({ fromMeasureIndex: 0, toMeasureExclusive: 1 });
    const [start, end] = Array.from(
      score.loopPlayerSeconds({ fromMeasureIndex: 0, toMeasureExclusive: 1 }),
    );
    await engine.play();

    host.score.positionSeconds = end! + 0.01;
    scheduler.tick();

    expect(host.score.positionSeconds).toBeCloseTo(start!, 9);
    expect(host.metronome.positionSeconds).toBeCloseTo(start!, 9);
    expect(engine.state).toBe("playing");
  });

  it("does not wrap before the loop end", async () => {
    const { engine, host, scheduler } = await makeEngine();
    engine.setLoop({ fromMeasureIndex: 0, toMeasureExclusive: 2 });
    await engine.play();
    host.score.positionSeconds = 0.01;
    scheduler.tick();
    expect(host.score.seeks).toHaveLength(0);
  });

  it("clears a loop when the range is inverted", async () => {
    const { engine, host, scheduler } = await makeEngine();
    engine.setLoop({ fromMeasureIndex: 2, toMeasureExclusive: 1 });
    await engine.play();
    host.score.isAtEnd = true;
    scheduler.tick();
    // No loop survived, so end-of-sequence stops rather than wrapping.
    expect(engine.state).toBe("stopped");
  });

  it("stops at the end of the sequence when no loop is set", async () => {
    const { engine, host, scheduler } = await makeEngine();
    await engine.play();
    host.score.isAtEnd = true;
    scheduler.tick();
    expect(engine.state).toBe("stopped");
    expect(host.score.playing).toBe(false);
  });

  it("keeps looping past the end of the sequence", async () => {
    const { engine, host, scheduler } = await makeEngine();
    engine.setLoop({ fromMeasureIndex: 0, toMeasureExclusive: 1 });
    await engine.play();
    host.score.isAtEnd = true;
    host.score.positionSeconds = 999;
    scheduler.tick();
    expect(engine.state).toBe("playing");
  });

  /**
   * The count has to sound whatever the metronome toggle says — counting in is
   * an explicit request, not the toggle — and the score must stay silent until
   * the pre-roll elapses.
   */
  it("runs the metronome alone through a count-in, then starts the score", async () => {
    const { engine, host, scheduler } = await makeEngine();
    engine.setMetronomeMuted(true);
    await engine.play({ countIn: true });

    expect(engine.state).toBe("counting-in");
    expect(host.metronome.playing).toBe(true);
    expect(host.metronome.muted).toBe(false);
    expect(host.score.playing).toBe(false);

    const seconds = score.countInSeconds(0);
    expect(seconds).toBeGreaterThan(0);

    host.metronome.positionSeconds = seconds - 0.001;
    scheduler.tick();
    expect(engine.state).toBe("counting-in");
    expect(host.score.playing).toBe(false);

    host.metronome.positionSeconds = seconds;
    scheduler.tick();
    expect(engine.state).toBe("playing");
    expect(host.score.playing).toBe(true);
    // The body sequence is back and the host's toggle applies again.
    expect(host.metronome.muted).toBe(true);
  });

  it("reports a cursor rect while playing", async () => {
    const { engine, cursors, scheduler } = await makeEngine();
    await engine.play();
    scheduler.tick();
    expect(cursors.length).toBeGreaterThan(0);
    expect(cursors.at(-1)).not.toBeNull();
  });

  it("clears the cursor on stop", async () => {
    const { engine, cursors } = await makeEngine();
    await engine.play();
    engine.stop();
    expect(cursors.at(-1)).toBeNull();
  });

  it("stops polling once disposed", async () => {
    const { engine, host, scheduler } = await makeEngine();
    await engine.play();
    engine.dispose();
    host.score.isAtEnd = true;
    // The frame that would have stopped the transport must not run.
    scheduler.tick();
    expect(host.score.playing).toBe(true);
    // `play` is async, so its guard surfaces as a rejection, not a throw.
    await expect(engine.play()).rejects.toThrow("disposed");
  });
});
