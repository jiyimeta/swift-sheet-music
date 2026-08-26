/**
 * The ISOBMFF muxer, walked as a parser would walk it.
 *
 * This is where the M4A export can go wrong quietly, so the tests read the box
 * tree back rather than compare against a golden blob: a golden would pin the
 * bytes without saying which field carries what, and every one of these fields
 * has a failure mode that still produces a file some player will open.
 *
 * Nothing here needs a browser. `AudioEncoder` lives behind `aac.ts`; this
 * function takes the frames it produced and knows nothing about where they came
 * from, which is what lets the fiddly half be tested in Node.
 */
import { describe, expect, it } from "vitest";
import { MOVIE_TIMESCALE, muxAacIntoMp4 } from "../src/playback/mp4.js";

const ascii = (bytes: Uint8Array, offset: number, length: number) =>
  String.fromCharCode(...bytes.subarray(offset, offset + length));

/** Where a container's children start, relative to the box's own first byte. */
const PAYLOAD_OFFSET: Record<string, number> = {
  moov: 8,
  trak: 8,
  mdia: 8,
  minf: 8,
  stbl: 8,
  edts: 8,
  dinf: 8,
  // A full box holding a version/flags word and an entry count before children.
  stsd: 16,
  // An AudioSampleEntry: the box header plus 28 bytes of fixed fields.
  mp4a: 36,
};

interface Box {
  readonly type: string;
  /** Offset of the box's first byte within the whole file. */
  readonly start: number;
  readonly size: number;
  /** The box's contents, header included. */
  readonly bytes: Uint8Array;
}

function childBoxes(file: Uint8Array, start: number, end: number): Box[] {
  const view = new DataView(file.buffer, file.byteOffset, file.byteLength);
  const out: Box[] = [];
  let offset = start;
  while (offset + 8 <= end) {
    const size = view.getUint32(offset);
    if (size < 8 || offset + size > end) break;
    out.push({
      type: ascii(file, offset + 4, 4),
      start: offset,
      size,
      bytes: file.subarray(offset, offset + size),
    });
    offset += size;
  }
  return out;
}

/** The box at `path`, e.g. `["moov", "trak", "mdia"]`. Throws when absent. */
function box(file: Uint8Array, path: string[]): Box {
  let scope = { start: 0, end: file.length };
  let found: Box | undefined;
  for (const type of path) {
    found = childBoxes(file, scope.start, scope.end).find((b) => b.type === type);
    if (found === undefined) {
      throw new Error(`no ${type} box under ${path.join("/")}`);
    }
    const payload = PAYLOAD_OFFSET[type] ?? 8;
    scope = { start: found.start + payload, end: found.start + found.size };
  }
  return found!;
}

const bodyView = (b: Box) =>
  new DataView(b.bytes.buffer, b.bytes.byteOffset, b.bytes.byteLength);

const SAMPLE_RATE = 44_100;
const FRAMES_PER_SAMPLE = 1024;
const DESCRIPTION = Uint8Array.from([0x12, 0x10]);

function mux(overrides: Partial<Parameters<typeof muxAacIntoMp4>[0]> = {}) {
  // Three frames with distinguishable sizes and contents, so the sample table
  // cannot be right by coincidence.
  const samples = [
    Uint8Array.from([1, 2, 3, 4, 5, 6]),
    Uint8Array.from([7, 8, 9]),
    Uint8Array.from([10, 11, 12, 13]),
  ];
  return muxAacIntoMp4({
    samples,
    description: DESCRIPTION,
    sampleRate: SAMPLE_RATE,
    channels: 2,
    framesPerSample: FRAMES_PER_SAMPLE,
    primingFrames: 2048,
    durationFrames: 1000,
    bitRate: 192_000,
    ...overrides,
  });
}

describe("muxAacIntoMp4", () => {
  it("lays the file out as ftyp, moov, mdat", () => {
    const file = mux();
    expect(childBoxes(file, 0, file.length).map((b) => b.type)).toEqual([
      "ftyp",
      "moov",
      "mdat",
    ]);
  });

  it("declares the M4A brand", () => {
    const ftyp = box(mux(), ["ftyp"]);
    expect(ascii(ftyp.bytes, 8, 4)).toBe("M4A ");
    const brands: string[] = [];
    for (let offset = 16; offset + 4 <= ftyp.size; offset += 4) {
      brands.push(ascii(ftyp.bytes, offset, 4));
    }
    expect(brands).toContain("isom");
    expect(brands).toContain("mp42");
  });

  it("writes the samples into mdat back to back, in order", () => {
    const mdat = box(mux(), ["mdat"]);
    expect([...mdat.bytes.subarray(8)]).toEqual([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
    ]);
  });

  /**
   * `stco` is an absolute file offset. Getting it wrong by the size of a box
   * produces a file whose duration and sample table are all correct and whose
   * audio is garbage — the failure this test exists for.
   */
  it("points the chunk offset at the first byte of mdat's payload", () => {
    const file = mux();
    const stco = box(file, ["moov", "trak", "mdia", "minf", "stbl", "stco"]);
    const view = bodyView(stco);
    expect(view.getUint32(12)).toBe(1); // one chunk
    expect(view.getUint32(16)).toBe(box(file, ["mdat"]).start + 8);
  });

  it("gives every sample its own size and one shared duration", () => {
    const file = mux();
    const stsz = bodyView(box(file, ["moov", "trak", "mdia", "minf", "stbl", "stsz"]));
    expect(stsz.getUint32(12)).toBe(0); // 0 = sizes are listed per sample
    expect(stsz.getUint32(16)).toBe(3);
    expect([stsz.getUint32(20), stsz.getUint32(24), stsz.getUint32(28)]).toEqual([
      6, 3, 4,
    ]);

    const stts = bodyView(box(file, ["moov", "trak", "mdia", "minf", "stbl", "stts"]));
    expect(stts.getUint32(12)).toBe(1); // one run covers every sample
    expect(stts.getUint32(16)).toBe(3);
    expect(stts.getUint32(20)).toBe(FRAMES_PER_SAMPLE);
  });

  it("puts every sample in one chunk", () => {
    const stsc = bodyView(
      box(mux(), ["moov", "trak", "mdia", "minf", "stbl", "stsc"]),
    );
    expect(stsc.getUint32(12)).toBe(1); // one entry
    expect(stsc.getUint32(16)).toBe(1); // first_chunk
    expect(stsc.getUint32(20)).toBe(3); // samples_per_chunk
    expect(stsc.getUint32(24)).toBe(1); // sample_description_index
  });

  it("carries the encoder's AudioSpecificConfig verbatim in esds", () => {
    const esds = box(mux(), [
      "moov", "trak", "mdia", "minf", "stbl", "stsd", "mp4a", "esds",
    ]);
    // The two config bytes appear inside the DecoderSpecificInfo descriptor,
    // introduced by tag 0x05 and its length.
    const body = esds.bytes;
    const tagIndex = body.indexOf(0x05, 12);
    expect(tagIndex).toBeGreaterThan(0);
    expect(body[tagIndex + 1]).toBe(DESCRIPTION.length);
    expect([...body.subarray(tagIndex + 2, tagIndex + 2 + DESCRIPTION.length)])
      .toEqual([...DESCRIPTION]);
  });

  it("declares the audio format in the sample entry", () => {
    const mp4a = bodyView(
      box(mux(), ["moov", "trak", "mdia", "minf", "stbl", "stsd", "mp4a"]),
    );
    expect(mp4a.getUint16(14)).toBe(1); // data_reference_index
    expect(mp4a.getUint16(24)).toBe(2); // channel count
    expect(mp4a.getUint16(26)).toBe(16); // sample size
    // The rate is 16.16 fixed point, so it lives in the high half.
    expect(mp4a.getUint16(32)).toBe(SAMPLE_RATE);
    expect(mp4a.getUint16(34)).toBe(0);
  });

  it("times the media track in sample-rate units", () => {
    const mdhd = bodyView(box(mux(), ["moov", "trak", "mdia", "mdhd"]));
    expect(mdhd.getUint32(20)).toBe(SAMPLE_RATE);
    // Every encoded frame is in the media, priming included — the edit list is
    // what hides the priming, not a short media duration.
    expect(mdhd.getUint32(24)).toBe(3 * FRAMES_PER_SAMPLE);
  });

  /**
   * The edit list is the whole reason the export lines up with the WAV. An AAC
   * encoder emits ~2048 frames of analysis delay before the signal; without
   * `elst` the file leads with that silence and runs long, and every other
   * assertion in this file still passes.
   */
  it("skips the encoder's priming with an edit list", () => {
    const elst = bodyView(box(mux(), ["moov", "trak", "edts", "elst"]));
    expect(elst.getUint32(12)).toBe(1); // one edit
    // segment_duration is in MOVIE units; media_time is in MEDIA units. Writing
    // both in the same timescale is the mistake this pins.
    expect(elst.getUint32(16)).toBe(Math.round((1000 / SAMPLE_RATE) * MOVIE_TIMESCALE));
    expect(elst.getInt32(20)).toBe(2048);
    expect(elst.getUint32(24)).toBe(0x0001_0000); // media_rate 1.0
  });

  it("reports the intended duration, not the padded one, in the movie header", () => {
    const file = mux();
    const expected = Math.round((1000 / SAMPLE_RATE) * MOVIE_TIMESCALE);
    expect(bodyView(box(file, ["moov", "mvhd"])).getUint32(20)).toBe(MOVIE_TIMESCALE);
    expect(bodyView(box(file, ["moov", "mvhd"])).getUint32(24)).toBe(expected);
    expect(bodyView(box(file, ["moov", "trak", "tkhd"])).getUint32(28)).toBe(expected);
  });

  /**
   * A range export can ask for fewer frames than the encoder padded out to, but
   * it can also ask for the tail of a render whose last AAC frame is partly
   * padding. Neither may claim more media than exists.
   */
  it("never claims more media than the samples hold", () => {
    const elst = bodyView(
      box(mux({ durationFrames: 999_999 }), ["moov", "trak", "edts", "elst"]),
    );
    const playable = 3 * FRAMES_PER_SAMPLE - 2048;
    expect(elst.getUint32(16)).toBe(
      Math.round((playable / SAMPLE_RATE) * MOVIE_TIMESCALE),
    );
  });

  it("refuses to mux without an AudioSpecificConfig", () => {
    expect(() => mux({ description: new Uint8Array(0) })).toThrow(
      /AudioSpecificConfig/,
    );
  });
});
