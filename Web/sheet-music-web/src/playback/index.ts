/**
 * Playback for `@jiyimeta/sheet-music-web`.
 *
 * A separate entry point so a host that only views scores never pulls a
 * SoundFont engine into its bundle. Import it as
 * `@jiyimeta/sheet-music-web/playback`.
 *
 * The default synth is spessasynth, declared as an OPTIONAL peer dependency:
 * install it yourself, pick your own version, and copy its
 * `spessasynth_processor.min.js` somewhere your page can fetch it. A different
 * synth can be dropped in by implementing `SynthHost` instead of calling
 * `createSpessaSynthHost`.
 */
export { createPlaybackEngine, PlaybackEngine } from "./engine.js";
export type {
  FrameScheduler,
  MixerChannelState,
  PlaybackEngineOptions,
  PlaybackState,
} from "./engine.js";
export { createSpessaSynthHost } from "./synth.js";
export type { SpessaSynthHostOptions } from "./synth.js";
export type { SynthHost, SynthTransport } from "./types.js";
export type {
  CursorRect,
  GMInstrument,
  MeasureRange,
  MixerStrip,
  PlaybackSummary,
} from "../index.js";
