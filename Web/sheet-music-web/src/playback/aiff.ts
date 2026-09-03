/**
 * Canonical 16-bit AIFF encoding for an `AudioBuffer`.
 *
 * Here for the same reason `wav.ts` is: a host that swaps
 * `createSpessaSynthHost` for its own `SynthHost` still gets an export, and the
 * bytes stay the package's own contract. It is the shape Android's
 * `AiffPcmEncoder` writes — `FORM`/`AIFF`, a fixed 18-byte `COMM`, then `SSND`.
 *
 * AIFF needs no browser capability at all, which is the only reason it is worth
 * carrying: `AudioFileFormat` names wav / aiff / m4a / mp3 on every other
 * platform, and AIFF was missing from the browser out of omission rather than
 * because a browser cannot produce one.
 */

/** Total size of the header this writes, before the first sample. */
const HEADER_BYTES = 54;

/**
 * Write `value` as an 80-bit IEEE 754 extended float, big-endian.
 *
 * AIFF's one genuinely exotic field. The conversion goes through the `double`'s
 * own bits rather than through logarithms so it is exact: every sample rate is
 * a normal double, and its 52-bit mantissa shifts straight into the extended
 * format's 64-bit one. The difference is that an extended float writes its
 * leading 1 explicitly, where a double leaves it implied.
 */
function writeExtendedFloat80(view: DataView, offset: number, value: number): void {
  if (value === 0 || !Number.isFinite(value)) {
    for (let i = 0; i < 10; i++) view.setUint8(offset + i, 0);
    return;
  }
  const scratch = new DataView(new ArrayBuffer(8));
  scratch.setFloat64(0, value);
  const bits = scratch.getBigUint64(0);
  const sign = Number((bits >> 63n) & 1n);
  const exponent = Number((bits >> 52n) & 0x7ffn) - 1023 + 16383;
  const mantissa = (1n << 63n) | ((bits & 0xf_ffff_ffff_ffffn) << 11n);

  view.setUint16(offset, (sign << 15) | exponent);
  view.setBigUint64(offset + 2, mantissa);
}

/** Bytes of an `.aiff` file holding `buffer`'s audio, 16-bit PCM. */
export function encodeAiff(buffer: AudioBuffer): Uint8Array {
  const channels = Math.max(1, buffer.numberOfChannels);
  const frames = buffer.length;
  const bytesPerSample = 2;
  const dataBytes = frames * channels * bytesPerSample;

  const out = new Uint8Array(HEADER_BYTES + dataBytes);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  };

  ascii(0, "FORM");
  view.setUint32(4, HEADER_BYTES - 8 + dataBytes);
  ascii(8, "AIFF");

  ascii(12, "COMM");
  view.setUint32(16, 18); // COMM's contents are a fixed size
  view.setUint16(20, channels);
  view.setUint32(22, frames);
  view.setUint16(26, 8 * bytesPerSample);
  writeExtendedFloat80(view, 28, buffer.sampleRate);

  ascii(38, "SSND");
  view.setUint32(42, 8 + dataBytes); // the two fields below count toward this
  view.setUint32(46, 0); // offset
  view.setUint32(50, 0); // block size

  // Read each channel once and interleave, rather than calling getChannelData
  // per frame — it is a live view, but the call is not free.
  const data: Float32Array[] = [];
  for (let channel = 0; channel < channels; channel++) {
    data.push(buffer.getChannelData(channel));
  }

  let offset = HEADER_BYTES;
  for (let frame = 0; frame < frames; frame++) {
    for (let channel = 0; channel < channels; channel++) {
      // Clamp before scaling, and asymmetrically — the same reasoning as
      // `encodeWav`: a synth summing voices exceeds ±1, and 16-bit PCM runs
      // -32768…32767 so the negative side takes the larger multiplier.
      const sample = Math.max(-1, Math.min(1, data[channel]![frame] ?? 0));
      view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff);
      offset += bytesPerSample;
    }
  }
  return out;
}
