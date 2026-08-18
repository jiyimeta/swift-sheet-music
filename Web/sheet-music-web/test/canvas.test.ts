import { describe, expect, it } from "vitest";
import type { DrawProgramPage } from "../src/draw-program.js";
import { drawPage } from "../src/render/canvas.js";
import type { ScoreFonts } from "../src/render/fonts.js";

/**
 * Records the calls a real `CanvasRenderingContext2D` would have received.
 *
 * This layer pins the mapping from opcode to Canvas2D call — unit conversion,
 * face selection, state bracketing. Whether the result *looks* right is the
 * Playwright screenshot's job; neither can substitute for the other.
 */
function fakeContext() {
  const calls: Array<[string, ...unknown[]]> = [];
  const state: Record<string, unknown> = {
    fillStyle: "",
    strokeStyle: "",
    lineWidth: 0,
    font: "",
  };
  const ctx = new Proxy({} as CanvasRenderingContext2D, {
    get(_target, prop) {
      const name = String(prop);
      if (name in state) return state[name];
      if (name === "measureText") {
        return () => ({
          actualBoundingBoxAscent: 40,
          actualBoundingBoxDescent: 10,
          actualBoundingBoxLeft: 0,
          actualBoundingBoxRight: 20,
        });
      }
      return (...args: unknown[]) => {
        calls.push([name, ...args]);
      };
    },
    set(_target, prop, value) {
      state[String(prop)] = value;
      calls.push([`set:${String(prop)}`, value]);
      return true;
    },
  });
  return { ctx, calls, state };
}

const fonts: ScoreFonts = { smufl: "Bravura", textRoman: "Edwin" };

function pageWith(commands: DrawProgramPage["commands"]): DrawProgramPage {
  return { widthMM: 210, heightMM: 297, commands };
}

const countOf = (calls: Array<[string, ...unknown[]]>, name: string) =>
  calls.filter(([called]) => called === name).length;

/**
 * `drawPage` brackets its whole run in one save/restore so a caller's transform
 * survives, and each command that transforms adds its own pair. Counting the
 * difference rather than the raw total keeps these tests about the commands.
 */
const nestedRestores = (calls: Array<[string, ...unknown[]]>) =>
  countOf(calls, "restore") - 1;

describe("drawPage", () => {
  it("scales path coordinates by pxPerMM", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "moveTo", x: 1, y: 2 },
        { kind: "lineTo", x: 3, y: 4 },
        { kind: "stroke", width: 1 },
      ]),
      4,
      fonts,
    );
    expect(calls).toContainEqual(["moveTo", 4, 8]);
    expect(calls).toContainEqual(["lineTo", 12, 16]);
    expect(calls).toContainEqual(["stroke"]);
  });

  it("scales cubic control points too", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "cubicTo", cx1: 1, cy1: 2, cx2: 3, cy2: 4, x: 5, y: 6 },
      ]),
      2,
      fonts,
    );
    expect(calls).toContainEqual(["bezierCurveTo", 2, 4, 6, 8, 10, 12]);
  });

  it("clamps the stroke width to 1.5 px", () => {
    const { ctx, state } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "moveTo", x: 0, y: 0 },
        { kind: "lineTo", x: 1, y: 0 },
        { kind: "stroke", width: 0.01 },
      ]),
      1,
      fonts,
    );
    expect(state.lineWidth).toBe(1.5);
  });

  it("starts a fresh path after each stroke", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "moveTo", x: 0, y: 0 },
        { kind: "lineTo", x: 1, y: 0 },
        { kind: "stroke", width: 1 },
        { kind: "moveTo", x: 2, y: 0 },
        { kind: "lineTo", x: 3, y: 0 },
        { kind: "stroke", width: 1 },
      ]),
      1,
      fonts,
    );
    // One before the first command, one after each stroke.
    expect(countOf(calls, "beginPath")).toBe(3);
  });

  it("maps setColor to an rgba fill and stroke", () => {
    const { ctx, state } = fakeContext();
    drawPage(ctx, pageWith([{ kind: "setColor", argb: 0x80007aff }]), 1, fonts);
    expect(state.fillStyle).toBe("rgba(0, 122, 255, 0.502)");
    expect(state.strokeStyle).toBe("rgba(0, 122, 255, 0.502)");
  });

  it("selects the SMuFL face for glyph commands", () => {
    const { ctx, calls, state } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "glyph", codepoint: 0xe050, x: 10, y: 20, size: 4, fontId: 1 },
      ]),
      2,
      fonts,
    );
    expect(state.font).toBe('8px "Bravura"');
    expect(calls).toContainEqual(["fillText", "\u{e050}", 20, 40]);
  });

  it("selects the text face for text commands", () => {
    const { ctx, calls, state } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "text", text: "Allegro", x: 1, y: 2, size: 3, fontId: 0 },
      ]),
      1,
      fonts,
    );
    expect(state.font).toBe('3px "Edwin"');
    expect(calls).toContainEqual(["fillText", "Allegro", 1, 2]);
  });

  it("fills rectangles in device pixels", () => {
    const { ctx, calls } = fakeContext();
    drawPage(ctx, pageWith([{ kind: "fillRect", x: 1, y: 2, w: 3, h: 4 }]), 2, fonts);
    expect(calls).toContainEqual(["fillRect", 2, 4, 6, 8]);
  });

  it("sets and clears the dash pattern", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "setDash", onMM: 1, offMM: 0.5 },
        { kind: "moveTo", x: 0, y: 0 },
        { kind: "lineTo", x: 1, y: 0 },
        { kind: "stroke", width: 1 },
        { kind: "setDash", onMM: 0, offMM: 0 },
        { kind: "moveTo", x: 0, y: 0 },
        { kind: "lineTo", x: 1, y: 0 },
        { kind: "stroke", width: 1 },
      ]),
      2,
      fonts,
    );
    expect(calls).toContainEqual(["setLineDash", [2, 1]]);
    expect(calls).toContainEqual(["setLineDash", []]);
  });

  it("brackets a rotation with save and restore", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "setRotation", radians: 1, pivotX: 5, pivotY: 6 },
        { kind: "setRotation", radians: 0, pivotX: 0, pivotY: 0 },
      ]),
      2,
      fonts,
    );
    expect(calls).toContainEqual(["translate", 10, 12]);
    expect(calls).toContainEqual(["rotate", 1]);
    expect(calls).toContainEqual(["translate", -10, -12]);
    expect(nestedRestores(calls)).toBe(1);
    expect(countOf(calls, "save")).toBe(countOf(calls, "restore"));
  });

  it("restores an unpaired rotation at the end of the page", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([{ kind: "setRotation", radians: 1, pivotX: 0, pivotY: 0 }]),
      1,
      fonts,
    );
    expect(nestedRestores(calls)).toBe(1);
    expect(countOf(calls, "save")).toBe(countOf(calls, "restore"));
  });

  it("ignores a reset rotation that was never opened", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([{ kind: "setRotation", radians: 0, pivotX: 0, pivotY: 0 }]),
      1,
      fonts,
    );
    expect(nestedRestores(calls)).toBe(0);
  });

  it("shears italic text about its baseline and restores the transform", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "italicText", text: "3", x: 10, y: 20, size: 4, fontId: 0 },
      ]),
      1,
      fonts,
    );
    expect(calls).toContainEqual(["transform", 1, 0, 0.25, 1, -5, 0]);
    expect(calls).toContainEqual(["fillText", "3", 10, 20]);
    expect(nestedRestores(calls)).toBe(1);
  });

  it("places a stretched glyph against its measured ink box", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        {
          kind: "stretchedGlyph",
          codepoint: 0xe000,
          rightEdgeX: 100,
          topY: 10,
          bottomY: 110,
          fontSize: 20,
          xScale: 2,
          fontId: 1,
        },
      ]),
      1,
      fonts,
    );
    // measureText reports ascent 40 / descent 10 / right 20, so the box is
    // 50 tall: scaleY = (110 - 10) / 50 = 2, and the origin lands at
    // (100 - 2*20, 10 + 2*40).
    expect(calls).toContainEqual(["translate", 60, 90]);
    expect(calls).toContainEqual(["scale", 2, 2]);
    expect(calls).toContainEqual(["fillText", "\u{e000}", 0, 0]);
    expect(nestedRestores(calls)).toBe(1);
  });

  it("offsets a slice by translating rather than by moving coordinates", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([{ kind: "moveTo", x: 10, y: 1000 }]),
      2,
      fonts,
      { offsetMM: 900 },
    );
    // Commands keep their page coordinates; the context carries the offset, so
    // the renderer stays a straight translation of the Kotlin original.
    expect(calls).toContainEqual(["translate", 0, -1800]);
    expect(calls).toContainEqual(["moveTo", 20, 2000]);
  });

  it("leaves the transform alone when there is no offset", () => {
    const { ctx, calls } = fakeContext();
    drawPage(ctx, pageWith([{ kind: "moveTo", x: 1, y: 2 }]), 1, fonts);
    expect(calls.filter(([name]) => name === "translate")).toHaveLength(0);
  });

  it("returns the context to the caller's state", () => {
    const { ctx, calls } = fakeContext();
    drawPage(
      ctx,
      pageWith([
        { kind: "setRotation", radians: 1, pivotX: 0, pivotY: 0 },
        { kind: "italicText", text: "3", x: 0, y: 0, size: 4, fontId: 0 },
      ]),
      1,
      fonts,
      { offsetMM: 100 },
    );
    expect(countOf(calls, "save")).toBe(countOf(calls, "restore"));
  });
});
