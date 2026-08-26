/**
 * Canonical 16-bit PCM WAVE encoding for an `AudioBuffer`.
 *
 * Written here rather than taken from the synth: a host that swaps
 * `createSpessaSynthHost` for its own `SynthHost` still gets an export, and the
 * bytes stay the package's own contract rather than a dependency's. It is the
 * same shape `SheetMusicAudioCore.ClickSoundFontBuilder` reads and the Android
 * module's `WavPcmEncoder` writes — 44 bytes of header, then interleaved
 * little-endian samples.
 *
 * 16-bit because that is what every consumer of a rendered score accepts;
 * float32 WAVE exists but doubles the file for headroom nothing here uses.
 */

/** Bytes of a `.wav` file holding `buffer`'s audio, 16-bit PCM. */
export function encodeWav(buffer: AudioBuffer): Uint8Array {
  const channels = Math.max(1, buffer.numberOfChannels);
  const frames = buffer.length;
  const bytesPerSample = 2;
  const blockAlign = channels * bytesPerSample;
  const dataBytes = frames * blockAlign;

  const out = new Uint8Array(44 + dataBytes);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  };

  ascii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true); // PCM fmt chunk size
  view.setUint16(20, 1, true); // format: PCM
  view.setUint16(22, channels, true);
  view.setUint32(24, buffer.sampleRate, true);
  view.setUint32(28, buffer.sampleRate * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 8 * bytesPerSample, true);
  ascii(36, "data");
  view.setUint32(40, dataBytes, true);

  // Read each channel once and interleave, rather than calling getChannelData
  // per frame — it is a live view, but the call is not free.
  const data: Float32Array[] = [];
  for (let channel = 0; channel < channels; channel++) {
    data.push(buffer.getChannelData(channel));
  }

  let offset = 44;
  for (let frame = 0; frame < frames; frame++) {
    for (let channel = 0; channel < channels; channel++) {
      // Clamp before scaling: a synth summing several voices can exceed ±1, and
      // letting that wrap turns a loud passage into white noise.
      const sample = Math.max(-1, Math.min(1, data[channel]![frame] ?? 0));
      // Asymmetric on purpose — 16-bit PCM runs -32768…32767, so the negative
      // side gets the larger multiplier and full scale is representable.
      view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
      offset += bytesPerSample;
    }
  }
  return out;
}

/**
 * `buffer` narrowed to `[startSeconds, endSeconds)`, or the buffer itself when
 * the range covers all of it.
 *
 * Used to trim a full-score render down to an export range. A note still
 * ringing at `startSeconds` is cut mid-tail rather than re-struck, which is what
 * looping the same range sounds like — the alternative, starting the transport
 * inside the sequence, is not something an offline render can be asked for.
 */
export function sliceBuffer(
  buffer: AudioBuffer,
  startSeconds: number,
  endSeconds: number,
): AudioBuffer {
  const rate = buffer.sampleRate;
  const start = Math.max(0, Math.floor(startSeconds * rate));
  const end = Math.min(buffer.length, Math.ceil(endSeconds * rate));
  if (start === 0 && end === buffer.length) return buffer;
  const frames = Math.max(1, end - start);

  // `OfflineAudioContext` rather than the buffer's own context: an
  // AudioBuffer's context may be closed by now, and creating one costs nothing
  // when nothing is rendered on it.
  const factory = new OfflineAudioContext(buffer.numberOfChannels, frames, rate);
  const sliced = factory.createBuffer(buffer.numberOfChannels, frames, rate);
  for (let channel = 0; channel < buffer.numberOfChannels; channel++) {
    sliced.copyToChannel(buffer.getChannelData(channel).subarray(start, end), channel);
  }
  return sliced;
}
