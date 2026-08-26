/**
 * Format dispatch: which formats exist, what they are called, and what happens
 * when one cannot be produced here.
 *
 * The M4A path is absent on purpose — it needs `AudioEncoder`, which Node does
 * not have, so `e2e/playback.spec.ts` owns it. What is testable here is the
 * table every host reads to name a download, and the MP3 refusal.
 */
import { describe, expect, it } from "vitest";
import {
  AUDIO_FILE_TYPES,
  encodeAudioFile,
  isExportFormatSupported,
} from "../src/playback/audio-file.js";
import { fakeAudioBuffer } from "./audio-buffer-stub.js";

const ascii = (bytes: Uint8Array, offset: number, length: number) =>
  String.fromCharCode(...bytes.subarray(offset, offset + length));

const buffer = () => fakeAudioBuffer([Float32Array.from([0, 1, 0, -1])]);

describe("AUDIO_FILE_TYPES", () => {
  /**
   * A host naming a download needs both, and would otherwise hardcode them —
   * which is exactly what `Examples/Web/main.js` did while WAV was the only
   * format.
   */
  it("names a MIME type and an extension for every format", () => {
    expect(AUDIO_FILE_TYPES.wav).toEqual({ mimeType: "audio/wav", fileExtension: "wav" });
    expect(AUDIO_FILE_TYPES.aiff).toEqual({ mimeType: "audio/aiff", fileExtension: "aiff" });
    expect(AUDIO_FILE_TYPES.m4a).toEqual({ mimeType: "audio/mp4", fileExtension: "m4a" });
    expect(AUDIO_FILE_TYPES.mp3).toEqual({ mimeType: "audio/mpeg", fileExtension: "mp3" });
  });
});

describe("encodeAudioFile", () => {
  it("writes WAVE bytes for wav", async () => {
    const result = await encodeAudioFile(buffer(), { format: "wav" });
    expect(ascii(result.bytes, 0, 4)).toBe("RIFF");
    expect(result.mimeType).toBe("audio/wav");
    expect(result.fileExtension).toBe("wav");
  });

  it("writes AIFF bytes for aiff", async () => {
    const result = await encodeAudioFile(buffer(), { format: "aiff" });
    expect(ascii(result.bytes, 0, 4)).toBe("FORM");
    expect(result.fileExtension).toBe("aiff");
  });

  /**
   * No browser ships an MP3 encoder: WebCodecs has no `mp3` codec and
   * `MediaRecorder` does not accept `audio/mpeg`. Shipping a wasm LAME would
   * mean an LGPL dependency in an MIT package for a format the host can reach
   * by running the WAV through its own encoder.
   */
  it("refuses MP3, naming the platform rather than the caller", async () => {
    await expect(encodeAudioFile(buffer(), { format: "mp3" })).rejects.toThrow(
      /mp3.*browser|browser.*mp3/i,
    );
  });
});

describe("isExportFormatSupported", () => {
  it("always reports the PCM formats as available", async () => {
    expect(await isExportFormatSupported("wav")).toBe(true);
    expect(await isExportFormatSupported("aiff")).toBe(true);
  });

  it("never reports MP3 as available", async () => {
    expect(await isExportFormatSupported("mp3")).toBe(false);
  });

  /** Node has no `AudioEncoder`, so the probe has to answer rather than throw. */
  it("reports M4A as unavailable where there is no AudioEncoder", async () => {
    expect(await isExportFormatSupported("m4a")).toBe(false);
  });
});
