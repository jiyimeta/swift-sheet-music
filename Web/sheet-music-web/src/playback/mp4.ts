/**
 * An ISOBMFF (`.m4a`) container around raw AAC frames.
 *
 * Written here rather than delegated to `MediaRecorder`, which is the only
 * browser API that will mux MP4 for you: `MediaRecorder` records a
 * `MediaStream` in REAL TIME, so a five-minute score would take five minutes to
 * export. The whole point of `renderOffline` is that it does not. An
 * `OfflineAudioContext` has no `createMediaStreamDestination` either, so there
 * is nothing to record from in the first place.
 *
 * This function is pure: frames in, bytes out. `AudioEncoder` — which Node does
 * not have — stays behind `aac.ts`, so the part that is easy to get subtly
 * wrong is the part that can be tested without a browser.
 *
 * Layout is `ftyp` / `moov` / `mdat`, with the sample table pointing into
 * `mdat` by absolute file offset. Every sample is a sync sample, so there is no
 * `stss`; every sample sits in one chunk, so `stsc` and `stco` have one entry
 * each. `stco` is 32-bit, which caps a file at 4 GB — over five hours at
 * 192 kbps, and a score that long has other problems.
 */

/**
 * Units per second in the movie header and the edit list.
 *
 * 1000 rather than the sample rate because `mvhd`, `tkhd` and `elst`'s
 * `segment_duration` are all in movie units while `mdhd` and `elst`'s
 * `media_time` are in media units. Keeping the two visibly different is what
 * stops them being conflated — writing a media value into a movie field
 * produces a file that declares a duration 44 times too long.
 */
export const MOVIE_TIMESCALE = 1000;

export interface Mp4MuxOptions {
  /** Raw AAC access units, in decode order. */
  readonly samples: readonly Uint8Array[];
  /**
   * The AudioSpecificConfig an `AudioEncoder` hands over as
   * `decoderConfig.description` — two bytes for AAC-LC. Goes into `esds`
   * verbatim; a decoder cannot start without it.
   */
  readonly description: Uint8Array;
  readonly sampleRate: number;
  readonly channels: number;
  /** Frames one access unit decodes to. 1024 for AAC-LC. */
  readonly framesPerSample: number;
  /**
   * Frames of encoder analysis delay before the signal starts. Hidden by the
   * edit list rather than trimmed, because the samples are opaque here.
   */
  readonly primingFrames: number;
  /** Frames of real audio the file should present, priming excluded. */
  readonly durationFrames: number;
  readonly bitRate: number;
}

function fourCC(text: string): number[] {
  return [...text].map((character) => character.charCodeAt(0));
}

/** A box: big-endian size, four-character type, then `body`. */
function box(type: string, ...body: (number[] | Uint8Array)[]): Uint8Array {
  const parts = body.map((part) => (part instanceof Uint8Array ? part : Uint8Array.from(part)));
  const length = parts.reduce((total, part) => total + part.length, 8);
  const out = new Uint8Array(length);
  new DataView(out.buffer).setUint32(0, length);
  out.set(fourCC(type), 4);
  let offset = 8;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/** A box whose first four body bytes are a version and 24 flag bits. */
function fullBox(
  type: string,
  version: number,
  flags: number,
  ...body: (number[] | Uint8Array)[]
): Uint8Array {
  return box(type, [version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff], ...body);
}

const u32 = (value: number): number[] => [
  (value >>> 24) & 0xff,
  (value >>> 16) & 0xff,
  (value >>> 8) & 0xff,
  value & 0xff,
];

const u16 = (value: number): number[] => [(value >>> 8) & 0xff, value & 0xff];

/**
 * An MPEG-4 descriptor: tag, length, payload.
 *
 * Lengths here use the one-byte form. Every descriptor this writes is far under
 * 128 bytes — an AAC-LC AudioSpecificConfig is two — and the multi-byte form
 * exists for descriptors that carry media, which these do not.
 */
function descriptor(tag: number, ...body: (number[] | Uint8Array)[]): Uint8Array {
  const parts = body.map((part) => (part instanceof Uint8Array ? part : Uint8Array.from(part)));
  const payload = parts.reduce((total, part) => total + part.length, 0);
  if (payload > 0x7f) {
    throw new Error(`MP4 descriptor 0x${tag.toString(16)} is too long to mux`);
  }
  const out = new Uint8Array(2 + payload);
  out[0] = tag;
  out[1] = payload;
  let offset = 2;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function esdsBox(description: Uint8Array, bitRate: number): Uint8Array {
  const decoderSpecificInfo = descriptor(0x05, description);
  const decoderConfig = descriptor(
    0x04,
    [
      0x40, // objectTypeIndication: MPEG-4 audio
      0x15, // streamType 0x05 (audio) << 2, upstream 0, reserved 1
      0x00, 0x00, 0x00, // bufferSizeDB — decoders size their own buffers
    ],
    u32(bitRate), // maxBitrate
    u32(bitRate), // avgBitrate
    decoderSpecificInfo,
  );
  const elementaryStream = descriptor(
    0x03,
    u16(1), // ES_ID
    [0x00], // no stream dependency, no URL, no OCR, priority 0
    decoderConfig,
    // SLConfigDescriptor: 0x02 means "MP4 defaults", which is what a file uses.
    descriptor(0x06, [0x02]),
  );
  return fullBox("esds", 0, 0, elementaryStream);
}

function mp4aBox(options: Mp4MuxOptions): Uint8Array {
  return box(
    "mp4a",
    [0, 0, 0, 0, 0, 0], // reserved
    u16(1), // data_reference_index
    [0, 0, 0, 0, 0, 0, 0, 0], // reserved (version, revision, vendor)
    u16(options.channels),
    u16(16), // sample size in bits
    u16(0), // pre_defined
    u16(0), // reserved
    // 16.16 fixed point. Rates above 65535 cannot be written here; every rate a
    // browser will render at is far below that.
    u16(options.sampleRate),
    u16(0),
    esdsBox(options.description, options.bitRate),
  );
}

function sampleTable(options: Mp4MuxOptions, mdatPayloadOffset: number): Uint8Array {
  const { samples } = options;
  const sizes = samples.flatMap((sample) => u32(sample.length));
  return box(
    "stbl",
    fullBox("stsd", 0, 0, u32(1), mp4aBox(options)),
    // One run: every AAC access unit decodes to the same number of frames.
    fullBox("stts", 0, 0, u32(1), u32(samples.length), u32(options.framesPerSample)),
    // One chunk holding every sample: first_chunk, samples_per_chunk, description.
    fullBox("stsc", 0, 0, u32(1), u32(1), u32(samples.length), u32(1)),
    // A zero default size means the per-sample list below is authoritative.
    fullBox("stsz", 0, 0, u32(0), u32(samples.length), sizes),
    fullBox("stco", 0, 0, u32(1), u32(mdatPayloadOffset)),
  );
}

/** Identity matrix in 16.16 / 2.30 fixed point, as `tkhd` and `mvhd` want it. */
const UNITY_MATRIX = [
  ...u32(0x0001_0000), ...u32(0), ...u32(0),
  ...u32(0), ...u32(0x0001_0000), ...u32(0),
  ...u32(0), ...u32(0), ...u32(0x4000_0000),
];

function movieBox(
  options: Mp4MuxOptions,
  movieDuration: number,
  mediaDuration: number,
  mdatPayloadOffset: number,
): Uint8Array {
  const mvhd = fullBox(
    "mvhd", 0, 0,
    u32(0), // creation time — left at zero rather than stamped, so the same
    u32(0), // render always produces the same bytes
    u32(MOVIE_TIMESCALE),
    u32(movieDuration),
    u32(0x0001_0000), // rate 1.0
    u16(0x0100), // volume 1.0
    u16(0), // reserved
    u32(0), u32(0), // reserved
    UNITY_MATRIX,
    u32(0), u32(0), u32(0), u32(0), u32(0), u32(0), // pre_defined
    u32(2), // next_track_ID
  );

  const tkhd = fullBox(
    "tkhd", 0, 0x7, // enabled, in movie, in preview
    u32(0), u32(0), // creation / modification time
    u32(1), // track_ID
    u32(0), // reserved
    u32(movieDuration),
    u32(0), u32(0), // reserved
    u16(0), // layer
    u16(1), // alternate_group — one audio track, so any nonzero group is fine
    u16(0x0100), // volume 1.0
    u16(0), // reserved
    UNITY_MATRIX,
    u32(0), u32(0), // width / height: zero for audio
  );

  // The edit list is what makes the file line up with the WAV from the same
  // render: it starts the presentation at `media_time`, skipping the encoder's
  // priming, and runs for exactly the intended duration.
  const elst = fullBox(
    "elst", 0, 0,
    u32(1),
    u32(movieDuration),
    u32(options.primingFrames),
    u32(0x0001_0000), // media_rate 1.0
  );

  const mdhd = fullBox(
    "mdhd", 0, 0,
    u32(0), u32(0), // creation / modification time
    u32(options.sampleRate),
    u32(mediaDuration),
    u16(0x55c4), // language: "und", packed five bits per letter
    u16(0), // pre_defined
  );

  const minf = box(
    "minf",
    fullBox("smhd", 0, 0, u16(0), u16(0)), // balance 0, reserved
    // The data is in this file, which is what a `dref` entry of `url ` with the
    // self-contained flag says.
    box("dinf", fullBox("dref", 0, 0, u32(1), fullBox("url ", 0, 1))),
    sampleTable(options, mdatPayloadOffset),
  );

  return box(
    "moov",
    mvhd,
    box(
      "trak",
      tkhd,
      box("edts", elst),
      box(
        "mdia",
        mdhd,
        fullBox("hdlr", 0, 0, u32(0), fourCC("soun"), u32(0), u32(0), u32(0), [0]),
        minf,
      ),
    ),
  );
}

/** An `.m4a` file wrapping `samples`. */
export function muxAacIntoMp4(options: Mp4MuxOptions): Uint8Array {
  if (options.description.length === 0) {
    throw new Error("cannot mux AAC without an AudioSpecificConfig");
  }

  const mediaDuration = options.samples.length * options.framesPerSample;
  // The priming is inside the media, so what is left to present is whatever the
  // encoder emitted past it — never more, however long a range asked for.
  const playableFrames = Math.max(
    0,
    Math.min(options.durationFrames, mediaDuration - options.primingFrames),
  );
  const movieDuration = Math.round((playableFrames / options.sampleRate) * MOVIE_TIMESCALE);

  const ftyp = box("ftyp", fourCC("M4A "), u32(0x200), fourCC("M4A "), fourCC("mp42"), fourCC("isom"));

  // `moov` names an absolute offset into `mdat`, and `moov`'s own size depends
  // on nothing but the sample count — so it can be built once against the
  // offset it will end up producing.
  const provisional = movieBox(options, movieDuration, mediaDuration, 0);
  const mdatPayloadOffset = ftyp.length + provisional.length + 8;
  const moov = movieBox(options, movieDuration, mediaDuration, mdatPayloadOffset);

  const audioBytes = options.samples.reduce((total, sample) => total + sample.length, 0);
  const mdat = new Uint8Array(8 + audioBytes);
  new DataView(mdat.buffer).setUint32(0, mdat.length);
  mdat.set(fourCC("mdat"), 4);
  let offset = 8;
  for (const sample of options.samples) {
    mdat.set(sample, offset);
    offset += sample.length;
  }

  const file = new Uint8Array(ftyp.length + moov.length + mdat.length);
  file.set(ftyp, 0);
  file.set(moov, ftyp.length);
  file.set(mdat, ftyp.length + moov.length);
  return file;
}
