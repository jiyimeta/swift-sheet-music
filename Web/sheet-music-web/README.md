# @jiyimeta/sheet-music-web

Browser bindings for [swift-sheet-music][repo]: parse MuseScore and MusicXML
files, engrave them, and draw the result on a `<canvas>`. The engraver is the
same Swift code the iOS and Android libraries run, compiled to WebAssembly —
given the same font metrics it produces byte-identical output to the native
build.

Unofficial. Not affiliated with MuseScore Limited / Muse Group, nor with Apple's
MusicKit.

## Install

    npm install @jiyimeta/sheet-music-web

## Use

```js
import {
  drawPage,
  loadScoreFonts,
  loadSheetMusic,
} from "@jiyimeta/sheet-music-web";

const sheetMusic = await loadSheetMusic({ bundleURL: "/sheet-music/" });

// Glyph metrics the engraver measures with. Not an optimization: without them
// the spacing is visibly wrong, and nothing errors.
const metrics = await fetch("/sheet-music/bravura.smft");
sheetMusic.installSMuFLMetrics(new Uint8Array(await metrics.arrayBuffer()));

const fonts = await loadScoreFonts({
  bravura: "/sheet-music/bravura.woff2",
  edwinRoman: "/sheet-music/edwin-roman.woff2",
});

const score = sheetMusic.loadScore(new Uint8Array(await file.arrayBuffer()));
try {
  const pxPerMM = (96 / 25.4) * 2;
  for (const page of score.layout({ pageWidthMM: 210, pageHeightMM: 297 })) {
    const canvas = document.createElement("canvas");
    canvas.width = page.widthMM * pxPerMM;
    canvas.height = page.heightMM * pxPerMM;
    canvas.style.width = `${page.widthMM * (96 / 25.4)}px`;
    drawPage(canvas.getContext("2d"), page, pxPerMM, fonts);
    document.body.append(canvas);
  }
} finally {
  score.release();
}
```

`score.release()` is not optional. The handle owns a parsed score and its cached
layout inside wasm memory, and nothing collects it for you.

Rasterize at a multiple of `96 / 25.4` and scale back down in CSS, as above.
Drawing at a zoomed `pxPerMM` re-rasterizes glyphs at the target resolution;
scaling the bitmap instead blurs them.

## Playback

Playback lives behind a second entry point so a viewer never downloads a synth.
The engine is yours to install:

    npm install spessasynth_lib

```js
import {
  createPlaybackEngine,
  createSpessaSynthHost,
} from "@jiyimeta/sheet-music-web/playback";

// Inside a click handler: an AudioContext cannot start without a user gesture,
// and the AudioWorklet needs a secure context (https, or http://localhost).
const host = await createSpessaSynthHost({
  context: new AudioContext(),
  soundFont: await (await fetch("/gm.sf2")).arrayBuffer(),
  processorURL: "/spessasynth_processor.min.js",
});

const engine = await createPlaybackEngine({
  score,
  host,
  onCursor: (rect) => drawCursorOverlay(rect),
});

await engine.play({ countIn: true });
engine.setLoop({ fromMeasureIndex: 0, toMeasureExclusive: 4 });
engine.setRate(0.75);
engine.setMetronomeMuted(false);
```

Supply the SoundFont yourself — this package ships no audio samples, the same
contract the iOS and Android libraries have. Copy spessasynth's
`spessasynth_processor.min.js` somewhere your page can fetch it; an AudioWorklet
module has to be a real URL, not something a bundler inlines.

`onCursor` hands back a rectangle in document millimetres — the same unit the
draw program uses, so one `pxPerMM` scales both. It is `null` when the position
has no cursor, and it stays `null` until `score.layout(...)` has run: the cached
document is what turns a position into geometry.

Every position is on the **player** clock — the unrolled sequence the synth
plays, which is longer than the score on anything with repeats.
`score.playbackSummary()` reports both lengths.

Loop, metronome and count-in are all optional; `createPlaybackEngine` alone gives
you play, pause, stop, seek and the cursor.

The metronome's click is General MIDI's wood blocks unless you replace it:

```js
const sf2 = sheetMusic.buildClickSoundFont(strongWav, weakWav); // 16-bit PCM WAVs
await engine.setMetronomeClickSoundFont(sf2.slice().buffer);
```

That bank is layered ahead of the score's on the metronome synth only, so
nothing else changes sound.

### Mixer

```js
for (const channel of engine.mixerChannels()) {
  console.log(channel.strip.displayName, channel.program, channel.volume);
}
engine.setStripProgram(channel, 48); // GM patch; ignored on a drum strip
engine.setStripVolume(channel, 100); // CC 7, 0–127
engine.setStripMuted(channel, true);
engine.setStripSoloed(channel, true); // others go silent; their mutes survive
engine.setMasterTuning(-13); // cents from A4=440, on every channel

// The 128 GM patches for a picker, grouped by family. A constant — cache it.
for (const { program, name, family } of sheetMusic.gmInstruments()) {
  console.log(program, name, family); // 33 "Electric Bass (finger)" "Bass"
}
```

`PlaybackEngine` asserts every strip's patch and level itself — at load and
after every transport move — so you get the score's own instruments without
touching the mixer at all. That is not a nicety: the sequence `renderMidi`
returns deliberately carries neither, so that a backward seek cannot replay them
over one of your overrides. A host driving a synth directly, without the engine,
has to send them itself or hear everything as Acoustic Grand Piano.

To drive a different synth, implement `SynthHost` instead of calling
`createSpessaSynthHost`. The engine never names spessasynth.

### Export

```js
if (engine.canExport) {
  const wav = await engine.exportWav({ range: loopRange }); // omit for the whole score
  const url = URL.createObjectURL(new Blob([wav], { type: "audio/wav" }));
}
```

16-bit PCM, rendered offline and faster than real time, carrying the mixer
exactly as it stands — the file is what you are hearing. The metronome is not
included, matching the iOS and Android exports.

`canExport` is `false` when the host has no offline path; implementing
`renderOffline` on a custom `SynthHost` is what turns it on. `encodeWav` is
exported separately if you want the `AudioBuffer` step yourself.

Not here yet: compressed formats. Writing M4A or MP3 in a browser needs WebCodecs
or `MediaRecorder`; WAV needs neither, so it went first.

## Assets

Three files ship in `assets/` and must be served alongside the bundle. Their
failure modes look nothing alike, which is useful when something renders oddly:

| file | what breaks without it |
|---|---|
| `bravura.smft` | Glyph metrics. The score renders with visibly wrong spacing; nothing errors. |
| `bravura.woff2` | Music glyphs become tofu boxes, correctly positioned. |
| `edwin-roman.woff2` | Titles and text fall back to a system face. |

Both fonts are SIL OFL 1.1 — see `assets/Bravura.LICENSE.txt` and
`assets/Edwin.LICENSE.txt`.

## Bundling

The generated glue imports its WASI shim by bare specifier, and spessasynth's
core imports `stb-vorbis` the same way. A bundler resolves both for you; a page
loading the ESM directly needs an import map, as `Examples/Web/index.html`
shows.

## Supported input

`.mscz`, `.mscx`, `.musicxml`, `.mxl`, `.mid` — the format is sniffed from the
leading bytes.

## Not here yet

Editing. The Swift engine supports it; these bindings expose display and
playback so far.

[repo]: https://github.com/jiyimeta/swift-sheet-music
