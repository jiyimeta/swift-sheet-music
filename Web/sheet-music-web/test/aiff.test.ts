/**
 * The AIFF encoder, checked against the format rather than against itself.
 *
 * AIFF is big-endian everywhere and stores its sample rate as an 80-bit IEEE
 * extended float, so almost nothing carries over from the WAVE encoder. Those
 * two differences are also the only places this can go wrong silently: a
 * little-endian sample block still has the right length, and a mis-encoded rate
 * still parses — it just plays back at the wrong speed.
 */
import { describe, expect, it } from "vitest";
import { encodeAiff } from "../src/playback/aiff.js";
import { fakeAudioBuffer } from "./audio-buffer-stub.js";

const ascii = (bytes: Uint8Array, offset: number, length: number) =>
  String.fromCharCode(...bytes.subarray(offset, offset + length));

const HEADER_BYTES = 54;

describe("encodeAiff", () => {
  it("writes a canonical FORM / COMM / SSND header", () => {
    const frames = 8;
    const out = encodeAiff(
      fakeAudioBuffer([new Float32Array(frames), new Float32Array(frames)]),
    );
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);

    expect(ascii(out, 0, 4)).toBe("FORM");
    expect(ascii(out, 8, 4)).toBe("AIFF");
    expect(ascii(out, 12, 4)).toBe("COMM");
    expect(view.getUint32(16)).toBe(18); // COMM is fixed-size
    expect(view.getUint16(20)).toBe(2); // channels
    expect(view.getUint32(22)).toBe(frames);
    expect(view.getUint16(26)).toBe(16); // bits per sample

    expect(ascii(out, 38, 4)).toBe("SSND");
    const dataBytes = frames * 2 * 2;
    expect(view.getUint32(42)).toBe(8 + dataBytes); // SSND carries two extra fields
    expect(view.getUint32(46)).toBe(0); // offset
    expect(view.getUint32(50)).toBe(0); // block size

    // FORM's size counts everything after its own 8 bytes.
    expect(view.getUint32(4)).toBe(HEADER_BYTES - 8 + dataBytes);
    expect(out.length).toBe(HEADER_BYTES + dataBytes);
  });

  /**
   * The one field with no analogue in WAVE. 44100 is 0x400E AC44 0000 0000 0000:
   * sign 0, exponent 16383 + 15, and a mantissa whose leading 1 is explicit —
   * unlike a `double`'s.
   */
  it("stores the sample rate as an 80-bit extended float", () => {
    const at = (rate: number) => {
      const out = encodeAiff(fakeAudioBuffer([new Float32Array(1)], rate));
      return [...out.subarray(28, 38)];
    };

    expect(at(44_100)).toEqual([0x40, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 0]);
    expect(at(48_000)).toEqual([0x40, 0x0e, 0xbb, 0x80, 0, 0, 0, 0, 0, 0]);
    expect(at(8_000)).toEqual([0x40, 0x0b, 0xfa, 0x00, 0, 0, 0, 0, 0, 0]);
  });

  it("interleaves the channels big-endian", () => {
    const left = Float32Array.from([1, 0, -1]);
    const right = Float32Array.from([0, 1, 0]);
    const out = encodeAiff(fakeAudioBuffer([left, right]));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);

    expect(view.getInt16(HEADER_BYTES + 0)).toBe(32767);
    expect(view.getInt16(HEADER_BYTES + 2)).toBe(0);
    expect(view.getInt16(HEADER_BYTES + 4)).toBe(0);
    expect(view.getInt16(HEADER_BYTES + 6)).toBe(32767);
    expect(view.getInt16(HEADER_BYTES + 8)).toBe(-32768);
  });

  it("clamps out-of-range samples instead of wrapping them", () => {
    const out = encodeAiff(fakeAudioBuffer([Float32Array.from([4, -4])]));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    expect(view.getInt16(HEADER_BYTES)).toBe(32767);
    expect(view.getInt16(HEADER_BYTES + 2)).toBe(-32768);
  });

  it("survives an empty buffer", () => {
    const out = encodeAiff(fakeAudioBuffer([new Float32Array(0)]));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    expect(out.length).toBe(HEADER_BYTES);
    expect(view.getUint32(22)).toBe(0); // frame count
  });
});
