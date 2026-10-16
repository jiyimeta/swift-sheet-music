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
  // v3: the blob table (i32 count, then i32 length + bytes each) follows the strings.
  const blobCount = view.getInt32(offset, true);
  offset += 4;
  for (let i = 0; i < blobCount; i += 1) {
    offset += 4 + view.getInt32(offset, true);
  }
  // widthMM, heightMM, commandCount
  offset += 8 + 8 + 4;
  return offset + index * COMMAND_STRIDE;
}

/**
 * A hand-assembled v3 stream: one page whose commands are `drawImage` records
 * (slots x, y, w, h; `integer` = blob index), over the given blob table. For what
 * the Swift-recorded fixture cannot say: two records sharing one blob index, and
 * an index past the table.
 */
function flatStream(
  blobs: readonly Uint8Array[],
  records: ReadonlyArray<{ blobIndex: number; rect: [number, number, number, number] }>,
  version = 3,
): Uint8Array {
  const size =
    16 + 4 + blobs.reduce((sum, b) => sum + 4 + b.length, 0) + 20 + records.length * COMMAND_STRIDE;
  const bytes = new Uint8Array(size);
  const view = new DataView(bytes.buffer);
  let at = 0;
  const u32 = (v: number) => {
    view.setUint32(at, v >>> 0, true);
    at += 4;
  };
  const f64 = (v: number) => {
    view.setFloat64(at, v, true);
    at += 8;
  };
  u32(0x534d4446);
  u32(version);
  u32(1); // pageCount
  u32(0); // stringCount
  u32(blobs.length);
  for (const blob of blobs) {
    u32(blob.length);
    bytes.set(blob, at);
    at += blob.length;
  }
  f64(210);
  f64(297);
  u32(records.length);
  for (const { blobIndex, rect } of records) {
    u32(13);
    for (let i = 0; i < 6; i += 1) f64(rect[i] ?? 0);
    u32(0xffffffff); // stringIndex -1
    u32(blobIndex);
    u32(0xffffffff); // fontId -1
  }
  return bytes;
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
      "drawImage",
      // Tail: a text in the system face, so every font id crosses the decoder.
      "text",
    ]);
  });

  it("decodes opcode 13 with a blob", () => {
    const image = decodeDrawProgram(fixture)[0]!.commands[13]!;
    expect(image.kind).toBe("drawImage");
    if (image.kind !== "drawImage") return;
    expect([image.x, image.y, image.w, image.h]).toEqual([30, 31, 32, 33]);
    // The recorded 2 x 2 PNG: 76 bytes, PNG signature first.
    expect(image.blob).toBeInstanceOf(Uint8Array);
    expect(image.blob.length).toBe(76);
    expect(Array.from(image.blob.slice(0, 8))).toEqual([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ]);
  });

  it("dedupes identical blobs to one index", () => {
    // Two pictures of one file: the stream carries its bytes once, and both
    // records name index 0. Both must resolve to equal bytes.
    const bytes = flatStream(
      [Uint8Array.from([1, 2, 3, 4])],
      [
        { blobIndex: 0, rect: [1, 2, 3, 4] },
        { blobIndex: 0, rect: [5, 6, 7, 8] },
      ],
    );
    const commands = decodeDrawProgram(bytes)[0]!.commands;
    expect(commands).toHaveLength(2);
    const [a, b] = commands;
    expect(a!.kind === "drawImage" && Array.from(a.blob)).toEqual([1, 2, 3, 4]);
    expect(b!.kind === "drawImage" && Array.from(b.blob)).toEqual([1, 2, 3, 4]);
    expect(b).toMatchObject({ kind: "drawImage", x: 5, y: 6, w: 7, h: 8 });
  });

  it("rejects a blob index past the table", () => {
    const bytes = flatStream([Uint8Array.from([1])], [{ blobIndex: 1, rect: [0, 0, 1, 1] }]);
    expect(() => decodeDrawProgram(bytes)).toThrow(/blob index 1\b/);
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
    expect(commands[14]).toEqual({
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
   * v1 numbered `setTextStyle` 12 and had no `fillPath`; read as v3 it would
   * decode without error and draw the wrong thing, so it must be refused.
   */
  it("rejects a version-1 stream", () => {
    expect(() => decodeDrawProgram(withU32(4, 1))).toThrow(/version 1\b/);
  });

  /**
   * v2 had no blob table: it would read the blob count as the first page's
   * width. Refused by the version word before any record is read.
   */
  it("rejects flat version 2", () => {
    expect(() => decodeDrawProgram(withU32(4, 2))).toThrow(/unsupported version 2\b/);
    expect(() => decodeDrawProgram(flatStream([], [], 2))).toThrow(/unsupported version 2\b/);
  });

  it("rejects an opcode past drawImage", () => {
    expect(() => decodeDrawProgram(withU32(recordOffset(fixture, 0), 14))).toThrow(
      /unknown opcode 14\b/,
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
    expect(decodeDrawProgram(view)[0]!.commands).toHaveLength(15);
  });
});
