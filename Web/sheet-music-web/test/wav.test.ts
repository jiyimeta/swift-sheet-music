/**
 * The WAVE encoder, checked against the format rather than against itself.
 *
 * Written in this package rather than taken from the synth so a host that swaps
 * in its own `SynthHost` still gets an export — which also means nothing else
 * verifies these bytes.
 *
 * Node has no `AudioBuffer`, so the input is a stand-in with the same surface
 * the encoder uses. That is the whole surface: `numberOfChannels`, `length`,
 * `sampleRate` and `getChannelData`.
 */
import { describe, expect, it } from "vitest";
import { encodeWav } from "../src/playback/wav.js";

function fakeBuffer(channels: Float32Array[], sampleRate = 44_100): AudioBuffer {
  return {
    numberOfChannels: channels.length,
    length: channels[0]?.length ?? 0,
    sampleRate,
    duration: (channels[0]?.length ?? 0) / sampleRate,
    getChannelData: (index: number) => channels[index]!,
  } as unknown as AudioBuffer;
}

const ascii = (bytes: Uint8Array, offset: number, length: number) =>
  String.fromCharCode(...bytes.subarray(offset, offset + length));

describe("encodeWav", () => {
  it("writes a canonical 44-byte header", () => {
    const frames = 8;
    const out = encodeWav(fakeBuffer([new Float32Array(frames), new Float32Array(frames)]));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);

    expect(ascii(out, 0, 4)).toBe("RIFF");
    expect(ascii(out, 8, 4)).toBe("WAVE");
    expect(ascii(out, 12, 4)).toBe("fmt ");
    expect(ascii(out, 36, 4)).toBe("data");

    expect(view.getUint32(16, true)).toBe(16); // fmt chunk size
    expect(view.getUint16(20, true)).toBe(1); // PCM
    expect(view.getUint16(22, true)).toBe(2); // channels
    expect(view.getUint32(24, true)).toBe(44_100);
    expect(view.getUint16(34, true)).toBe(16); // bits per sample

    const dataBytes = frames * 2 * 2;
    expect(view.getUint32(40, true)).toBe(dataBytes);
    // RIFF size counts everything after its own 8 bytes.
    expect(view.getUint32(4, true)).toBe(36 + dataBytes);
    expect(out.length).toBe(44 + dataBytes);
  });

  it("derives byte rate and block align from the format", () => {
    const out = encodeWav(fakeBuffer([new Float32Array(4)], 22_050));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    expect(view.getUint16(32, true)).toBe(2); // mono, 16-bit
    expect(view.getUint32(28, true)).toBe(22_050 * 2);
  });

  it("interleaves the channels", () => {
    const left = Float32Array.from([1, 0, -1]);
    const right = Float32Array.from([0, 1, 0]);
    const out = encodeWav(fakeBuffer([left, right]));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    // L R L R L R, full scale on each side.
    expect(view.getInt16(44, true)).toBe(32767);
    expect(view.getInt16(46, true)).toBe(0);
    expect(view.getInt16(48, true)).toBe(0);
    expect(view.getInt16(50, true)).toBe(32767);
    expect(view.getInt16(52, true)).toBe(-32768);
  });

  /**
   * A synth summing several voices routinely exceeds ±1. Letting that wrap
   * turns the loudest passage into white noise, which is a far worse artefact
   * than the clipping it would have been.
   */
  it("clamps out-of-range samples instead of wrapping them", () => {
    const out = encodeWav(fakeBuffer([Float32Array.from([4, -4])]));
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    expect(view.getInt16(44, true)).toBe(32767);
    expect(view.getInt16(46, true)).toBe(-32768);
  });

  it("survives an empty buffer", () => {
    const out = encodeWav(fakeBuffer([new Float32Array(0)]));
    expect(out.length).toBe(44);
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    expect(view.getUint32(40, true)).toBe(0);
  });
});
