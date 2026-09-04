/**
 * Reader for the `DrawProgramFlat` payload `computeLayout` returns.
 *
 * The byte layout is defined by
 * `Sources/SheetMusicBridgeCore/Draw/DrawProgramFlat.swift` — magic, version, a
 * deduplicated string side table, then fixed-stride command records. Nothing
 * here knows about Wirelet: the Swift side encodes to this format precisely so
 * that a hand-written decoder can be correct, unlike one written against
 * `@WireFormat`'s tag/varint framing.
 *
 * Keep `SMDF_VERSION` in lockstep with `DrawProgramFlat.version`.
 */

const SMDF_MAGIC = 0x534d4446; // "SMDF"
const SMDF_VERSION = 1;
/** opcode + 6 × f64 + stringIndex + integer + fontId. */
const COMMAND_STRIDE = 4 + 6 * 8 + 4 + 4 + 4;

/** `DrawProgram.FontID` — 0 body text (Edwin), 1 music glyphs (Bravura). */
export const FontId = { textRoman: 0, smufl: 1 } as const;
export type FontId = (typeof FontId)[keyof typeof FontId];

export type DrawCommand =
  | { kind: "moveTo"; x: number; y: number }
  | { kind: "lineTo"; x: number; y: number }
  | { kind: "stroke"; width: number }
  | { kind: "fillRect"; x: number; y: number; w: number; h: number }
  | {
      kind: "glyph";
      codepoint: number;
      x: number;
      y: number;
      size: number;
      fontId: FontId;
    }
  | {
      kind: "text";
      text: string;
      x: number;
      y: number;
      size: number;
      fontId: FontId;
    }
  | { kind: "setColor"; argb: number }
  | {
      kind: "cubicTo";
      cx1: number;
      cy1: number;
      cx2: number;
      cy2: number;
      x: number;
      y: number;
    }
  | {
      kind: "stretchedGlyph";
      codepoint: number;
      rightEdgeX: number;
      topY: number;
      bottomY: number;
      fontSize: number;
      xScale: number;
      fontId: FontId;
    }
  | { kind: "setRotation"; radians: number; pivotX: number; pivotY: number }
  | { kind: "setDash"; onMM: number; offMM: number }
  | {
      /**
       * Superseded by `setTextStyle` and no longer emitted by the bridge.
       * Still decoded so a stream that carries it renders.
       */
      kind: "italicText";
      text: string;
      x: number;
      y: number;
      size: number;
      fontId: FontId;
    }
  | {
      /**
       * Font style for every subsequent `text` and `glyph`, until the next
       * `setTextStyle`. A state command like `setColor` / `setDash` /
       * `setRotation`.
       *
       * `flags` is a bitmask: bit 0 bold, bit 1 italic. MuseScore's own role
       * defaults set tempo marks, rehearsal marks and instrument-change text
       * bold; before this opcode the wire could not say so, and this renderer
       * drew them at regular weight while the Apple one drew them bold.
       */
      kind: "setTextStyle";
      flags: number;
    };

/** Bit positions in a `setTextStyle` mask. Mirrors Swift's `DrawCommand.TextStyleFlag`. */
export const TEXT_STYLE_BOLD = 1;
/** @see TEXT_STYLE_BOLD */
export const TEXT_STYLE_ITALIC = 2;

export interface DrawProgramPage {
  /** Page width in document millimetres. */
  readonly widthMM: number;
  /** Page height in document millimetres. */
  readonly heightMM: number;
  readonly commands: readonly DrawCommand[];
}

/**
 * Reads little-endian scalars, bounds-checking every access. A partially-read
 * draw program renders as plausible nonsense, which is far harder to diagnose
 * than a thrown error — so every shortfall throws.
 */
class Cursor {
  private offset = 0;

  constructor(private readonly view: DataView) {}

  private need(bytes: number): void {
    if (this.offset + bytes > this.view.byteLength) {
      throw new Error(
        `draw program truncated: need ${bytes} bytes at ${this.offset}, have ${
          this.view.byteLength - this.offset
        }`,
      );
    }
  }

  u32(): number {
    this.need(4);
    const v = this.view.getUint32(this.offset, true);
    this.offset += 4;
    return v;
  }

  i32(): number {
    this.need(4);
    const v = this.view.getInt32(this.offset, true);
    this.offset += 4;
    return v;
  }

  f64(): number {
    this.need(8);
    const v = this.view.getFloat64(this.offset, true);
    this.offset += 8;
    return v;
  }

  bytes(count: number): Uint8Array {
    if (count < 0) {
      throw new Error(`draw program: negative length ${count}`);
    }
    this.need(count);
    const slice = new Uint8Array(
      this.view.buffer,
      this.view.byteOffset + this.offset,
      count,
    );
    this.offset += count;
    return slice;
  }

  /** Fails before a command record is read rather than part-way through it. */
  needCommandRecord(): void {
    this.need(COMMAND_STRIDE);
  }
}

function asFontId(raw: number): FontId {
  if (raw !== FontId.textRoman && raw !== FontId.smufl) {
    throw new Error(`draw program: unknown fontId ${raw}`);
  }
  return raw;
}

/**
 * Decode a `DrawProgramFlat` payload.
 *
 * @throws if the magic, version, opcode, string index or font id is not one this
 * build understands, or if the payload is truncated.
 */
export function decodeDrawProgram(bytes: Uint8Array): DrawProgramPage[] {
  const cursor = new Cursor(
    new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
  );

  const magic = cursor.u32();
  if (magic !== SMDF_MAGIC) {
    throw new Error(`draw program: bad magic 0x${magic.toString(16)}`);
  }
  const version = cursor.u32();
  if (version !== SMDF_VERSION) {
    throw new Error(`draw program: unsupported version ${version}`);
  }
  const pageCount = cursor.i32();
  const stringCount = cursor.i32();

  const decoder = new TextDecoder("utf-8", { fatal: true });
  const strings: string[] = [];
  for (let i = 0; i < stringCount; i += 1) {
    strings.push(decoder.decode(cursor.bytes(cursor.i32())));
  }

  const pages: DrawProgramPage[] = [];
  for (let p = 0; p < pageCount; p += 1) {
    const widthMM = cursor.f64();
    const heightMM = cursor.f64();
    const commandCount = cursor.i32();
    const commands: DrawCommand[] = [];
    for (let c = 0; c < commandCount; c += 1) {
      cursor.needCommandRecord();
      commands.push(readCommand(cursor, strings));
    }
    pages.push({ widthMM, heightMM, commands });
  }
  return pages;
}

function readCommand(cursor: Cursor, strings: readonly string[]): DrawCommand {
  const opcode = cursor.i32();
  const s: number[] = [];
  for (let i = 0; i < 6; i += 1) {
    s.push(cursor.f64());
  }
  const stringIndex = cursor.i32();
  const integer = cursor.u32();
  const fontIdRaw = cursor.i32();

  const str = (): string => {
    const value = strings[stringIndex];
    if (value === undefined) {
      throw new Error(`draw program: bad string index ${stringIndex}`);
    }
    return value;
  };

  switch (opcode) {
    case 0:
      return { kind: "moveTo", x: s[0]!, y: s[1]! };
    case 1:
      return { kind: "lineTo", x: s[0]!, y: s[1]! };
    case 2:
      return { kind: "stroke", width: s[0]! };
    case 3:
      return { kind: "fillRect", x: s[0]!, y: s[1]!, w: s[2]!, h: s[3]! };
    case 4:
      return {
        kind: "glyph",
        codepoint: integer,
        x: s[0]!,
        y: s[1]!,
        size: s[2]!,
        fontId: asFontId(fontIdRaw),
      };
    case 5:
      return {
        kind: "text",
        text: str(),
        x: s[0]!,
        y: s[1]!,
        size: s[2]!,
        fontId: asFontId(fontIdRaw),
      };
    case 6:
      return { kind: "setColor", argb: integer };
    case 7:
      return {
        kind: "cubicTo",
        cx1: s[0]!,
        cy1: s[1]!,
        cx2: s[2]!,
        cy2: s[3]!,
        x: s[4]!,
        y: s[5]!,
      };
    case 8:
      return {
        kind: "stretchedGlyph",
        codepoint: integer,
        rightEdgeX: s[0]!,
        topY: s[1]!,
        bottomY: s[2]!,
        fontSize: s[3]!,
        xScale: s[4]!,
        fontId: asFontId(fontIdRaw),
      };
    case 9:
      return { kind: "setRotation", radians: s[0]!, pivotX: s[1]!, pivotY: s[2]! };
    case 10:
      return { kind: "setDash", onMM: s[0]!, offMM: s[1]! };
    case 11:
      return {
        kind: "italicText",
        text: str(),
        x: s[0]!,
        y: s[1]!,
        size: s[2]!,
        fontId: asFontId(fontIdRaw),
      };
    case 12:
      // Masked rather than range-checked: the encoder widens a u8 into the
      // record's u32 integer slot, so the high bytes are always zero, and a
      // stream where they are not is one this decoder cannot interpret anyway.
      // Refusing it would trade an unknown-but-inert style bit for a whole page
      // that does not draw.
      return { kind: "setTextStyle", flags: integer & 0xff };
    default:
      throw new Error(`draw program: unknown opcode ${opcode}`);
  }
}
