import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import {
  loadSheetMusic,
  type EditIntent,
  type ElementRef,
  type NoteDurationSpec,
  type NoteRef,
  type Score,
  type SheetMusic,
} from "../src/index.js";
import { PlaybackEngine, type FrameScheduler } from "../src/playback/engine.js";
import type { SynthHost, SynthTransport } from "../src/playback/types.js";

const fixturePath = (name: string) =>
  fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));

const metricsBytes = new Uint8Array(
  readFileSync(fileURLToPath(new URL("../assets/bravura.smft", import.meta.url))),
);

interface ReplayFixture {
  readonly fingerprints: readonly string[];
  readonly steps: readonly ReplayStep[];
}

interface ReplayStep {
  readonly op: string;
  readonly at?: ReplayPath;
  readonly from?: ReplayPath;
  readonly to?: ReplayPath;
  readonly pitch?: number;
  readonly tpc?: number;
  readonly accidental?: string;
  readonly duration?: ReplayDuration;
  readonly actualNotes?: number;
  readonly normalNotes?: number;
  readonly sourceTieForward?: number;
  readonly targetTieBack?: number;
  readonly base64?: string;
}

interface ReplayPath extends ElementRef {
  readonly noteIndexInChord?: number;
}

interface ReplayDuration {
  readonly value?: NoteDurationSpec;
  readonly numerator?: number;
  readonly denominator?: number;
}

interface SampleEditExpectations {
  readonly probes: readonly GeometryProbe[];
}

interface GeometryProbe {
  readonly xMM: number;
  readonly yMM: number;
  readonly activeVoice: number;
  readonly minimumWidthMM: number;
  readonly hit: unknown;
  readonly caret: unknown;
}

// One entry per `ReplayChain` on the Swift side: "edit-replay" is the standard note- and slot-level chain,
// "edit-replay-parity" the structural one covering EditIntent cases 30-40. Both pairs are recorded by
// EditReplayWebGoldenTests.swift, so a chain added there is picked up here by adding its stem to this list.
const replayChains = (["edit-replay", "edit-replay-parity"] as const).map((stem) => ({
  stem,
  fixture: JSON.parse(readFileSync(fixturePath(`${stem}.json`), "utf8")) as ReplayFixture,
  bytes: new Uint8Array(readFileSync(fixturePath(`${stem}.mscx`))),
}));

const editExpectations = JSON.parse(
  readFileSync(fixturePath("sample-edit-expectations.json"), "utf8"),
) as SampleEditExpectations;
const sampleBytes = new Uint8Array(readFileSync(fixturePath("sample.mscz")));

function duration(duration: ReplayDuration | undefined): NoteDurationSpec | undefined {
  if (duration === undefined) return undefined;
  if (duration.value !== undefined) return duration.value;
  return {
    numerator: requireNumber(duration.numerator, "duration.numerator"),
    denominator: requireNumber(duration.denominator, "duration.denominator"),
  };
}

function elementRef(path: ReplayPath | undefined): ElementRef {
  const ref = requirePath(path);
  return {
    partIndex: ref.partIndex,
    staffIndexInPart: ref.staffIndexInPart,
    measureIndex: ref.measureIndex,
    voiceIndex: ref.voiceIndex,
    elementIndex: ref.elementIndex,
  };
}

function noteRef(path: ReplayPath | undefined): NoteRef {
  const ref = requirePath(path);
  return {
    ...elementRef(ref),
    noteIndexInChord: requireNumber(ref.noteIndexInChord, "noteIndexInChord"),
  };
}

function requirePath(path: ReplayPath | undefined): ReplayPath {
  if (path === undefined) throw new Error("replay step is missing a path");
  return path;
}

function requireNumber(value: number | undefined, name: string): number {
  if (value === undefined) throw new Error(`replay step is missing ${name}`);
  return value;
}

function requireString(value: string | undefined, name: string): string {
  if (value === undefined) throw new Error(`replay step is missing ${name}`);
  return value;
}

function intent(step: ReplayStep): EditIntent {
  switch (step.op) {
    case "inputNote":
      return {
        type: "inputNote",
        at: elementRef(step.at),
        pitch: requireNumber(step.pitch, "pitch"),
        tpc: requireNumber(step.tpc, "tpc"),
        duration: duration(step.duration),
      };
    case "writeNote":
      return {
        type: "writeNote",
        at: elementRef(step.at),
        pitch: requireNumber(step.pitch, "pitch"),
        tpc: requireNumber(step.tpc, "tpc"),
        duration: duration(step.duration),
      };
    case "writeRest":
      return {
        type: "writeRest",
        at: elementRef(step.at),
        duration: requireDuration(step.duration),
      };
    case "setRestDuration":
      return {
        type: "setRestDuration",
        at: elementRef(step.at),
        duration: requireDuration(step.duration),
      };
    case "setChordDuration":
      return {
        type: "setChordDuration",
        at: elementRef(step.at),
        duration: requireDuration(step.duration),
      };
    case "delete":
      return { type: "delete", at: elementRef(step.at) };
    case "setNotePitch":
      return {
        type: "setNotePitch",
        at: noteRef(step.at),
        pitch: requireNumber(step.pitch, "pitch"),
        tpc: requireNumber(step.tpc, "tpc"),
        accidental: step.accidental ?? null,
      };
    case "setAccidental":
      return {
        type: "setAccidental",
        at: noteRef(step.at),
        accidental: step.accidental ?? null,
      };
    case "addNoteToChord":
      return {
        type: "addNoteToChord",
        at: elementRef(step.at),
        pitch: requireNumber(step.pitch, "pitch"),
        tpc: requireNumber(step.tpc, "tpc"),
        accidental: step.accidental ?? null,
      };
    case "removeNoteFromChord":
      return { type: "removeNoteFromChord", at: noteRef(step.at) };
    case "setTie":
      return {
        type: "setTie",
        from: noteRef(step.from),
        to: noteRef(step.to),
        sourceTieForward: step.sourceTieForward ?? null,
        targetTieBack: step.targetTieBack ?? null,
      };
    case "createTuplet":
      return {
        type: "createTuplet",
        at: elementRef(step.at),
        actualNotes: requireNumber(step.actualNotes, "actualNotes"),
        normalNotes: requireNumber(step.normalNotes, "normalNotes"),
      };
    case "removeTuplet":
      return { type: "removeTuplet", at: elementRef(step.at) };
    default:
      throw new Error(`unsupported scalar replay op: ${step.op}`);
  }
}

function requireDuration(value: ReplayDuration | undefined): NoteDurationSpec {
  const result = duration(value);
  if (result === undefined) throw new Error("replay step is missing duration");
  return result;
}

function bytes(base64: string): Uint8Array {
  return new Uint8Array(Buffer.from(base64, "base64"));
}

class FakeTransport implements SynthTransport {
  positionSeconds = 0;
  isAtEnd = false;
  playing = false;

  programChange(): void {}
  controlChange(): void {}
  async addSoundBankOnTop(): Promise<void> {}
  load(): void {}
  play(): void {
    this.playing = true;
  }
  pause(): void {
    this.playing = false;
  }
  seek(seconds: number): void {
    this.positionSeconds = seconds;
  }
  setRate(): void {}
  setMuted(): void {}
  dispose(): void {}
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

class ManualScheduler implements FrameScheduler {
  request(): number {
    return 1;
  }

  cancel(): void {}
}

describe("editing facade", () => {
  let sheetMusic: SheetMusic;

  beforeAll(async () => {
    sheetMusic = await loadSheetMusic({
      bundleURL: new URL("../dist/", import.meta.url),
      platform: "node",
    });
    expect(sheetMusic.installSMuFLMetrics(metricsBytes)).toBe(true);
  });

  it.each(replayChains)(
    "replays the $stem editing script through the JavaScript facade",
    ({ stem, fixture: replayFixture, bytes: replayBytes }) => {
      const score = sheetMusic.loadScore(replayBytes);
      try {
        score.beginEditing();
        expect(score.fingerprint).toBe(replayFixture.fingerprints[0]);

        replayFixture.steps.forEach((step, index) => {
          const outcome =
            step.op === "intentBytes"
              ? score.applyEditIntentBytes(bytes(requireString(step.base64, "base64")))
              : step.op === "undo"
                ? score.undo()
                : step.op === "redo"
                  ? score.redo()
                  : score.applyEdit(intent(step));

          expect(outcome.accepted, `${stem} step ${index} ${step.op}`).toBe(true);
          expect(score.fingerprint, `${stem} fingerprint after step ${index}`).toBe(
            replayFixture.fingerprints[index + 1],
          );
        });
      } finally {
        score.release();
      }
    },
  );

  it("matches sample edit hit-test and caret geometry expectations", () => {
    const score = sheetMusic.loadScore(sampleBytes);
    try {
      score.layout({ pageWidthMM: 210, pageHeightMM: 297 });
      for (const probe of editExpectations.probes) {
        const hit = score.hitTest(probe.xMM, probe.yMM, probe.activeVoice);
        expect(hit).toEqual(probe.hit);
        expect(score.caretRect(hit!, probe.minimumWidthMM)).toEqual(probe.caret);
      }
    } finally {
      score.release();
    }
  });

  it("throws on released editing calls and stale playback", async () => {
    const released = sheetMusic.loadScore(sampleBytes);
    released.release();
    expect(() =>
      released.applyEdit({
        type: "delete",
        at: { partIndex: 0, staffIndexInPart: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 0 },
      }),
    ).toThrow(/released/i);
    expect(() => released.hitTest(0, 0)).toThrow(/released/i);

    const score = sheetMusic.loadScore(sampleBytes);
    try {
      const engine = await PlaybackEngine.create({
        score,
        host: new FakeHost(),
        scheduler: new ManualScheduler(),
      });
      score.beginEditing();
      const outcome = score.applyEdit({
        type: "setNotePitch",
        at: {
          partIndex: 0,
          staffIndexInPart: 0,
          measureIndex: 0,
          voiceIndex: 0,
          elementIndex: 0,
          noteIndexInChord: 0,
        },
        pitch: 61,
        tpc: 21,
        accidental: "accidentalSharp",
      });
      expect(outcome.accepted).toBe(true);
      await expect(engine.play()).rejects.toThrow(/edited after this engine/);
      engine.dispose();
    } finally {
      score.release();
    }
  });

  it("reports editState undo, redo, and lastAffected transitions", () => {
    const score = sheetMusic.loadScore(sampleBytes);
    try {
      score.beginEditing();
      expect(score.editState()).toMatchObject({
        active: true,
        canUndo: false,
        canRedo: false,
        lastAffected: null,
      });

      const outcome = score.applyEdit({
        type: "setNotePitch",
        at: {
          partIndex: 0,
          staffIndexInPart: 0,
          measureIndex: 0,
          voiceIndex: 0,
          elementIndex: 0,
          noteIndexInChord: 0,
        },
        pitch: 61,
        tpc: 21,
        accidental: "accidentalSharp",
      });
      expect(outcome.accepted).toBe(true);
      const edited = score.editState();
      expect(edited.canUndo).toBe(true);
      expect(edited.canRedo).toBe(false);
      expect(edited.lastAffected).not.toBeNull();

      expect(score.undo().accepted).toBe(true);
      expect(score.editState().canRedo).toBe(true);

      expect(score.redo().accepted).toBe(true);
      expect(score.editState().canRedo).toBe(false);
    } finally {
      score.release();
    }
  });
});
