import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { decodeDrawProgram, FontId, type DrawCommand } from "../src/draw-program.js";
import { splitIntoBands } from "../src/render/bands.js";

function page(...commands: DrawCommand[]) {
  return { widthMM: 210, heightMM: 2000, commands };
}

/** A filled rect is the simplest command with an exact, unpadded vertical extent. */
function rect(y: number, height = 1): DrawCommand {
  return { kind: "fillRect", x: 0, y, w: 10, h: height };
}

function rects(count: number, startY = 0): DrawCommand[] {
  return Array.from({ length: count }, (_, index) => rect(startY + index * 10));
}

function paintCommands(commands: readonly DrawCommand[]): DrawCommand[] {
  return commands.filter(
    (command) => command.kind !== "setColor" && command.kind !== "setDash",
  );
}

function colorAtFirstPaint(commands: readonly DrawCommand[]): number {
  let argb = 0xff000000;
  for (const command of commands) {
    if (command.kind === "setColor") argb = command.argb;
    if (command.kind === "fillRect") return argb;
  }
  throw new Error("band paints nothing");
}

describe("splitIntoBands", () => {
  it("empty page yields no bands", () => {
    expect(splitIntoBands(page(), 80)).toEqual([]);
  });

  it("short page stays a single band", () => {
    const bands = splitIntoBands(page(rect(0), rect(10), rect(20)), 80);
    expect(bands).toHaveLength(1);
    expect(bands[0]!.topMM).toBeCloseTo(0, 9);
    expect(bands[0]!.heightMM).toBeCloseTo(21, 9);
  });

  it("tall page splits once the minimum height is exceeded", () => {
    const bands = splitIntoBands(page(...rects(40)), 80);
    expect(bands.length).toBeGreaterThanOrEqual(4);
    for (const band of bands) {
      expect(band.heightMM).toBeGreaterThan(0);
    }
  });

  it("every drawing command lands in exactly one band", () => {
    const commands = rects(40);
    const emitted = splitIntoBands(page(...commands), 80).flatMap((band) =>
      band.commands.filter((command) => command.kind === "fillRect"),
    );
    expect(emitted).toEqual(commands);
  });

  it("bands cover the page top to bottom in order", () => {
    const bands = splitIntoBands(page(...rects(40)), 80);
    expect(bands[0]!.topMM).toBeCloseTo(0, 9);
    const last = bands[bands.length - 1]!;
    expect(last.topMM + last.heightMM).toBeCloseTo(391, 9);
    for (let i = 0; i + 1 < bands.length; i += 1) {
      expect(bands[i + 1]!.topMM).toBeGreaterThanOrEqual(bands[i]!.topMM);
    }
  });

  it("each band draws in the color that was in force where it starts", () => {
    const commands: DrawCommand[] = [{ kind: "setColor", argb: 0xffff0000 }, ...rects(40)];
    const bands = splitIntoBands(page(...commands), 80);
    expect(bands.length).toBeGreaterThan(1);
    for (const band of bands) {
      expect(band.commands[0]!.kind).toBe("setColor");
      expect(colorAtFirstPaint(band.commands)).toBe(0xffff0000);
    }
  });

  it("each band restates an active dash", () => {
    const commands: DrawCommand[] = [{ kind: "setDash", onMM: 2, offMM: 1 }, ...rects(40)];
    const bands = splitIntoBands(page(...commands), 80);
    expect(bands.length).toBeGreaterThan(1);
    for (const band of bands) {
      const dash = band.commands.find((command) => command.kind === "setDash");
      expect(dash).toEqual({ kind: "setDash", onMM: 2, offMM: 1 });
    }
  });

  it("a path under construction is never split across bands", () => {
    const commands: DrawCommand[] = [
      { kind: "moveTo", x: 0, y: 0 },
      ...Array.from({ length: 40 }, (_, index): DrawCommand => ({
        kind: "lineTo",
        x: 1,
        y: index * 10,
      })),
      { kind: "stroke", width: 0.5 },
      ...rects(40, 500),
    ];
    const bands = splitIntoBands(page(...commands), 80);
    for (const band of bands) {
      let open = false;
      for (const command of band.commands) {
        if (command.kind === "moveTo") open = true;
        if (command.kind === "stroke") {
          expect(open).toBe(true);
          open = false;
        }
        if (command.kind === "lineTo" || command.kind === "cubicTo") {
          expect(open).toBe(true);
        }
      }
      expect(open).toBe(false);
    }
  });

  it("a rotated run is never split across bands", () => {
    const commands: DrawCommand[] = [
      { kind: "setRotation", radians: 1.57, pivotX: 0, pivotY: 0 },
      ...rects(40),
      { kind: "setRotation", radians: 0, pivotX: 0, pivotY: 0 },
      ...rects(40, 500),
    ];
    const bands = splitIntoBands(page(...commands), 80);
    for (const band of bands) {
      let rotated = false;
      for (const command of band.commands) {
        if (command.kind === "setRotation") rotated = command.radians !== 0;
      }
      expect(rotated).toBe(false);
    }
  });

  it("band extent covers a stroke's width", () => {
    const bands = splitIntoBands(
      page(
        { kind: "moveTo", x: 0, y: 10 },
        { kind: "lineTo", x: 10, y: 10 },
        { kind: "stroke", width: 4 },
      ),
      80,
    );
    expect(bands).toHaveLength(1);
    expect(bands[0]!.topMM).toBeLessThanOrEqual(8);
    expect(bands[0]!.topMM + bands[0]!.heightMM).toBeGreaterThanOrEqual(12);
  });

  it("band extent covers a glyph above its baseline", () => {
    const bands = splitIntoBands(
      page({ kind: "glyph", codepoint: 0xe0a4, x: 5, y: 50, size: 7, fontId: FontId.smufl }),
      80,
    );
    expect(bands).toHaveLength(1);
    expect(bands[0]!.topMM).toBeLessThan(50);
    expect(bands[0]!.topMM + bands[0]!.heightMM).toBeGreaterThan(50);
  });

  it("splits the tall fixture and preserves paint command order", () => {
    const bytes = new Uint8Array(
      readFileSync(fileURLToPath(new URL("./fixtures/tall.smdf", import.meta.url))),
    );
    const page = decodeDrawProgram(bytes)[0]!;
    const bands = splitIntoBands(page);
    expect(bands.length).toBeGreaterThanOrEqual(4);
    expect(bands.flatMap((band) => paintCommands(band.commands))).toEqual(
      paintCommands(page.commands),
    );
  });
});
