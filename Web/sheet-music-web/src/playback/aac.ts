/**
 * The one part of the M4A export that needs a browser.
 *
 * Kept deliberately thin. `AudioEncoder` is WebCodecs, which Node does not
 * have, so everything downstream of it — the container, the sample table, the
 * edit list — lives in `mp4.ts` as a pure function that can be tested without
 * one. What is left here is feeding an `AudioBuffer` in and collecting frames
 * out.
 */

/**
 * Frames one AAC-LC access unit decodes to.
 *
 * A property of the codec, not of any encoder: AAC-LC is defined on 1024-sample
 * blocks. Deriving it from a chunk's reported duration instead would be
 * arithmetic on a microsecond integer that has already been rounded.
 */
export const AAC_FRAMES_PER_SAMPLE = 1024;

/**
 * Frames of analysis delay an AAC-LC encoder emits before the signal.
 *
 * Measured on Chromium 151: one second of 44,100 frames came back as 47 access
 * units — 48,128 frames — of which 2,048 precede the signal and the remaining
 * 1,980 pad the tail out to a whole access unit. `mp4.ts` hides this with an
 * edit list rather than trimming, since the encoded frames are opaque by then.
 *
 * If another browser's encoder primes differently, the export gains a leading
 * offset — which is why `e2e/playback.spec.ts` decodes the file back and
 * measures its leading silence instead of trusting this constant.
 */
export const AAC_PRIMING_FRAMES = 2048;

export interface AacEncodeResult {
  /** Raw access units, in decode order. */
  readonly samples: Uint8Array[];
  /** `decoderConfig.description` — the AudioSpecificConfig `esds` needs. */
  readonly description: Uint8Array;
}

/**
 * `AudioEncoderConfig` plus the AAC-specific member.
 *
 * The DOM lib does not carry `aac` yet, and it is not optional in practice —
 * omitting it leaves the container format up to the browser, which is not a
 * thing a muxer can be written against.
 */
interface AacAudioEncoderConfig extends AudioEncoderConfig {
  readonly aac: { readonly format: "aac" | "adts" };
}

function aacConfig(
  sampleRate: number,
  channels: number,
  bitRate: number,
): AacAudioEncoderConfig {
  return {
    codec: "mp4a.40.2", // AAC-LC
    sampleRate,
    numberOfChannels: channels,
    bitrate: bitRate,
    // Raw access units rather than ADTS: an ADTS header on every frame would
    // have to be stripped again before muxing, and `mp4a` describes the stream
    // once in `esds` instead.
    aac: { format: "aac" },
  };
}

/** Whether this browser will encode AAC at these settings. */
export async function isAacEncodingSupported(
  sampleRate: number,
  channels: number,
  bitRate: number,
): Promise<boolean> {
  if (typeof AudioEncoder === "undefined") return false;
  try {
    const support = await AudioEncoder.isConfigSupported(
      aacConfig(sampleRate, channels, bitRate),
    );
    return support.supported === true;
  } catch {
    // `isConfigSupported` rejects rather than returning false for a config it
    // cannot even parse. Either way the answer is no.
    return false;
  }
}

/** Encode all of `buffer` to AAC-LC access units. */
export async function encodeAac(
  buffer: AudioBuffer,
  options: { readonly bitRate: number },
): Promise<AacEncodeResult> {
  if (typeof AudioEncoder === "undefined") {
    throw new Error("this browser has no WebCodecs AudioEncoder, so it cannot write M4A");
  }

  const channels = Math.max(1, buffer.numberOfChannels);
  const samples: Uint8Array[] = [];
  let description: Uint8Array | null = null;
  let failure: Error | null = null;

  const encoder = new AudioEncoder({
    output: (chunk, metadata) => {
      const config = metadata?.decoderConfig;
      if (description === null && config?.description !== undefined) {
        // `description` arrives as either an ArrayBuffer or a view onto one,
        // and the buffer may be reused after this callback returns — so copy.
        const source = config.description;
        description = ArrayBuffer.isView(source)
          ? new Uint8Array(source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength))
          : new Uint8Array(source.slice(0));
      }
      const bytes = new Uint8Array(chunk.byteLength);
      chunk.copyTo(bytes);
      samples.push(bytes);
    },
    // The encoder reports asynchronously, so a failure has to be parked and
    // rethrown from `flush` rather than escaping into nothing.
    error: (error) => {
      failure ??= error instanceof Error ? error : new Error(String(error));
    },
  });

  encoder.configure(aacConfig(buffer.sampleRate, channels, options.bitRate));

  // Fed in blocks rather than as one `AudioData`: a whole render is tens of
  // millions of frames, and copying it into a single planar array would double
  // the peak memory of an export for no benefit.
  const BLOCK_FRAMES = 8192;
  const channelData: Float32Array[] = [];
  for (let channel = 0; channel < channels; channel++) {
    channelData.push(buffer.getChannelData(channel));
  }

  for (let offset = 0; offset < buffer.length; offset += BLOCK_FRAMES) {
    const frames = Math.min(BLOCK_FRAMES, buffer.length - offset);
    const planar = new Float32Array(frames * channels);
    for (let channel = 0; channel < channels; channel++) {
      planar.set(channelData[channel]!.subarray(offset, offset + frames), channel * frames);
    }
    encoder.encode(
      new AudioData({
        format: "f32-planar",
        sampleRate: buffer.sampleRate,
        numberOfFrames: frames,
        numberOfChannels: channels,
        timestamp: Math.round((offset / buffer.sampleRate) * 1e6),
        data: planar,
      }),
    );
    if (failure !== null) break;
  }

  try {
    await encoder.flush();
  } finally {
    encoder.close();
  }
  if (failure !== null) throw failure;
  if (description === null) {
    throw new Error("the AAC encoder produced no decoder configuration");
  }
  return { samples, description };
}
