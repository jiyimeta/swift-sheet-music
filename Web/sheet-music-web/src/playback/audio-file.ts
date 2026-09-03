/**
 * One encoded audio file from one rendered `AudioBuffer`.
 *
 * The formats are the four `AudioFileFormat` names every platform in this
 * project shares. Three of them a browser can produce; MP3 it cannot, and
 * saying so out loud is better than quietly offering three where the app offers
 * four.
 */
import { AAC_FRAMES_PER_SAMPLE, AAC_PRIMING_FRAMES, encodeAac, isAacEncodingSupported } from "./aac.js";
import { encodeAiff } from "./aiff.js";
import { muxAacIntoMp4 } from "./mp4.js";
import { encodeWav } from "./wav.js";

export type AudioExportFormat = "wav" | "aiff" | "m4a" | "mp3";

export interface AudioFileType {
  readonly mimeType: string;
  readonly fileExtension: string;
}

/**
 * What to call a file of each format.
 *
 * Exported because every host needs both halves — one for the `Blob`, one for
 * the download's name — and deriving them at each call site is how the two
 * drift apart.
 */
export const AUDIO_FILE_TYPES: Record<AudioExportFormat, AudioFileType> = {
  wav: { mimeType: "audio/wav", fileExtension: "wav" },
  aiff: { mimeType: "audio/aiff", fileExtension: "aiff" },
  m4a: { mimeType: "audio/mp4", fileExtension: "m4a" },
  mp3: { mimeType: "audio/mpeg", fileExtension: "mp3" },
};

/** Bits per second for the compressed formats when the caller names none. */
export const DEFAULT_BIT_RATE = 192_000;

export interface AudioFileResult {
  readonly bytes: Uint8Array;
  readonly mimeType: string;
  readonly fileExtension: string;
}

export interface AudioFileOptions {
  readonly format: AudioExportFormat;
  /** Compressed formats only. Defaults to `DEFAULT_BIT_RATE`. */
  readonly bitRate?: number;
}

/**
 * Whether this browser can write `format`.
 *
 * Async because the only honest answer for M4A comes from
 * `AudioEncoder.isConfigSupported`. A host can call this to hide a format
 * rather than let `encodeAudioFile` throw at the end of a long render.
 */
export async function isExportFormatSupported(
  format: AudioExportFormat,
  options: { readonly sampleRate?: number; readonly channels?: number; readonly bitRate?: number } = {},
): Promise<boolean> {
  switch (format) {
    case "wav":
    case "aiff":
      // Plain byte writing. Nothing to ask the browser about.
      return true;
    case "m4a":
      return isAacEncodingSupported(
        options.sampleRate ?? 44_100,
        options.channels ?? 2,
        options.bitRate ?? DEFAULT_BIT_RATE,
      );
    case "mp3":
      // Not a capability question. See `encodeAudioFile`.
      return false;
  }
}

/**
 * No browser ships an MP3 encoder — WebCodecs has no `mp3` codec and
 * `MediaRecorder` refuses `audio/mpeg`. Bundling a wasm LAME would put an LGPL
 * dependency in an MIT package, for a format a host can reach by running the
 * WAV through an encoder of its own. Android throws the same way on a device
 * whose MediaCodec has no MP3 encoder.
 */
const MP3_UNAVAILABLE =
  "mp3 cannot be written in a browser: no encoder exists for it. Export wav and convert.";

/**
 * Throw, with a reason, when `format` cannot be written here.
 *
 * Separate from `encodeAudioFile` so a caller can find out BEFORE rendering.
 * An export that was never going to succeed should fail while the user is still
 * looking at the button, not after the whole score has been rendered.
 */
export async function assertExportFormatSupported(
  format: AudioExportFormat,
  options: { readonly sampleRate?: number; readonly channels?: number; readonly bitRate?: number } = {},
): Promise<void> {
  if (format === "mp3") throw new Error(MP3_UNAVAILABLE);
  if (!(await isExportFormatSupported(format, options))) {
    throw new Error(
      `this browser cannot write ${format}: its WebCodecs AudioEncoder does not offer AAC`,
    );
  }
}

/** Encode `buffer` as `options.format`. */
export async function encodeAudioFile(
  buffer: AudioBuffer,
  options: AudioFileOptions,
): Promise<AudioFileResult> {
  const type = AUDIO_FILE_TYPES[options.format];
  switch (options.format) {
    case "wav":
      return { bytes: encodeWav(buffer), ...type };
    case "aiff":
      return { bytes: encodeAiff(buffer), ...type };
    case "m4a": {
      const bitRate = options.bitRate ?? DEFAULT_BIT_RATE;
      const { samples, description } = await encodeAac(buffer, { bitRate });
      const bytes = muxAacIntoMp4({
        samples,
        description,
        sampleRate: buffer.sampleRate,
        channels: Math.max(1, buffer.numberOfChannels),
        framesPerSample: AAC_FRAMES_PER_SAMPLE,
        primingFrames: AAC_PRIMING_FRAMES,
        durationFrames: buffer.length,
        bitRate,
      });
      return { bytes, ...type };
    }
    case "mp3":
      throw new Error(MP3_UNAVAILABLE);
  }
}
