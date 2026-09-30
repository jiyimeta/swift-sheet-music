import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  decodeDrawProgram,
  FontId,
  TEXT_STYLE_ITALIC,
  TEXT_STYLE_SEMIBOLD,
} from "../src/draw-program.js";

/**
 * Bytes produced by the Swift encoder, not assembled here. Regenerate with
 * `swift run GenWebFixtures Web/sheet-music-web/test/fixtures`.
 */
const fixture = new Uint8Array(
  readFileSync(
    fileURLToPath(new URL("./fixtures/all-opcodes.smdf", import.meta.url)),
  ),
);

/** opcode + 6 × f64 + stringIndex + integer + fontId. */
const COMMAND_STRIDE = 64;
/** Byte offset of the fontId field inside a command record. */
const FONT_ID_FIELD = 60;

/**
 * Byte offset of the first page's command record `index`, found by walking the
 * header and string table rather than hard-coded, so the tests survive a change
 * to the fixture's strings.
 */
function recordOffset(bytes: Uint8Array, index: number): number {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const stringCount = view.getInt32(12, true);
  let offset = 16;
  for (let i = 0; i < stringCount; i += 1) {
    offset += 4 + view.getInt32(offset, true);
  }
  // widthMM, heightMM, commandCount
  offset += 8 + 8 + 4;
  return offset + index * COMMAND_STRIDE;
}

/** A copy of the fixture with one little-endian i32 / u32 overwritten. */
function withU32(offset: number, value: number): Uint8Array {
  const bytes = fixture.slice();
  new DataView(bytes.buffer).setUint32(offset, value >>> 0, true);
  return bytes;
}

describe("decodeDrawProgram", () => {
  it("reads the page list", () => {
    const pages = decodeDrawProgram(fixture);
    expect(pages).toHaveLength(2);
    expect(pages[0]!.widthMM).toBe(210);
    expect(pages[0]!.heightMM).toBe(297);
    expect(pages[1]!.commands).toHaveLength(0);
  });

  it("reads every opcode in declaration order", () => {
    const commands = decodeDrawProgram(fixture)[0]!.commands;
    expect(commands.map((c) => c.kind)).toEqual([
      "moveTo",
      "lineTo",
      "stroke",
      "fillRect",
      "glyph",
      "text",
      "setColor",
      "cubicTo",
      "stretchedGlyph",
      "setRotation",
      "setDash",
      "setTextStyle",
      "fillPath",
      // Tail: a text in the system face, so every font id crosses the decoder.
      "text",
    ]);
  });

  it("reads scalar payloads", () => {
    const commands = decodeDrawProgram(fixture)[0]!.commands;
    expect(commands[0]).toEqual({ kind: "moveTo", x: 1, y: 2 });
    expect(commands[1]).toEqual({ kind: "lineTo", x: 3, y: 4 });
    expect(commands[2]).toEqual({ kind: "stroke", width: 0.5 });
    expect(commands[3]).toEqual({ kind: "fillRect", x: 5, y: 6, w: 7, h: 8 });
    expect(commands[7]).toEqual({
      kind: "cubicTo",
      cx1: 15,
      cy1: 16,
      cx2: 17,
      cy2: 18,
      x: 19,
      y: 20,
    });
    expect(commands[9]).toEqual({
      kind: "setRotation",
      radians: 1.5707963267948966,
      pivotX: 25,
      pivotY: 26,
    });
    expect(commands[10]).toEqual({ kind: "setDash", onMM: 0.75, offMM: 0.25 });
    expect(commands[12]).toEqual({ kind: "fillPath" });
  });

  it("reads text style flags, including the semibold bit", () => {
    const commands = decodeDrawProgram(fixture)[0]!.commands;
    expect(commands[11]).toEqual({
      kind: "setTextStyle",
      flags: TEXT_STYLE_SEMIBOLD | TEXT_STYLE_ITALIC,
    });
  });

  it("reads strings from the side table", () => {
    const commands = decodeDrawProgram(fixture)[0]!.commands;
    expect(commands[5]).toEqual({
      kind: "text",
      text: "Allegro",
      x: 12,
      y: 13,
      size: 14,
      fontId: 0,
    });
    expect(commands[13]).toEqual({
      kind: "text",
      text: "12",
      x: 27,
      y: 28,
      size: 29,
      fontId: FontId.system,
    });
  });

  it("reads glyph and colour integers unsigned", () => {
    const commands = decodeDrawProgram(fixture)[0]!.commands;
    expect(commands[4]).toEqual({
      kind: "glyph",
      codepoint: 0xe050,
      x: 9,
      y: 10,
      size: 11,
      fontId: 1,
    });
    // 0xFF007AFF read as a signed i32 would be negative; the alpha byte makes
    // this the case that catches it.
    expect(commands[6]).toEqual({ kind: "setColor", argb: 0xff007aff });
    expect(commands[8]).toEqual({
      kind: "stretchedGlyph",
      codepoint: 0xe000,
      rightEdgeX: 21,
      topY: 22,
      bottomY: 23,
      fontSize: 24,
      xScale: 1.5,
      fontId: 1,
    });
  });

  it("rejects a bad magic", () => {
    const bad = fixture.slice();
    bad[0] = 0;
    expect(() => decodeDrawProgram(bad)).toThrow(/magic/i);
  });

  it("rejects an unsupported version", () => {
    const bad = fixture.slice();
    bad[4] = 0xfe;
    expect(() => decodeDrawProgram(bad)).toThrow(/version/i);
  });

  /**
   * v1 numbered `setTextStyle` 12 and had no `fillPath`; read as v2 it would
   * decode without error and draw the wrong thing, so it must be refused.
   */
  it("rejects a version-1 stream", () => {
    expect(() => decodeDrawProgram(withU32(4, 1))).toThrow(/version 1\b/);
  });

  it("rejects an opcode past fillPath", () => {
    expect(() => decodeDrawProgram(withU32(recordOffset(fixture, 0), 13))).toThrow(
      /unknown opcode 13\b/,
    );
  });

  it("rejects a font id past system", () => {
    // Record 4 is the Bravura glyph; its font id is the one being corrupted.
    expect(decodeDrawProgram(fixture)[0]!.commands[4]!.kind).toBe("glyph");
    const bad = withU32(recordOffset(fixture, 4) + FONT_ID_FIELD, 3);
    expect(() => decodeDrawProgram(bad)).toThrow(/unknown fontId 3\b/);
  });

  it("rejects truncation", () => {
    expect(() => decodeDrawProgram(fixture.slice(0, fixture.length - 1))).toThrow(
      /truncated/i,
    );
  });

  /** A slice's byteOffset is non-zero; the decoder must honour it. */
  it("decodes from a view with a non-zero byte offset", () => {
    const padded = new Uint8Array(fixture.length + 8);
    padded.set(fixture, 8);
    const view = padded.subarray(8);
    expect(decodeDrawProgram(view)[0]!.commands).toHaveLength(14);
  });
});
