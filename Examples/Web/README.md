# Browser viewer example

Reads a MuseScore or MusicXML file, engraves it in WebAssembly, draws the result
on a `<canvas>`, and plays it back. Everything runs in the page — no server-side
rendering, no network calls after the initial load.

## Run it

    Scripts/wasm-build-web.sh                       # wasm + PackageToJS glue
    npm --prefix Web/sheet-music-web install
    npm --prefix Web/sheet-music-web run build      # TypeScript -> dist-esm/
    Scripts/web-example-serve.sh                    # http://localhost:8080/Examples/Web/

Then pick a `.mscz`, `.mscx`, `.musicxml`, `.mxl` or `.mid` file.
`Web/sheet-music-web/test/fixtures/sample.mscz` is a small one to start with;
`repeat.mscz` next to it has a repeat, which is more interesting to watch the
cursor follow.

**Open it through the dev server, not as a file.** Playback needs an
AudioWorklet, which needs a secure context: `http://localhost` counts,
double-clicking `index.html` does not. The score still renders that way — only
the sound is missing, which is a confusing way to find out.

## Playback

Choose a General MIDI SoundFont in the second file picker; the Play button stays
disabled until you do, and this repository ships none. GeneralUser GS
(<https://schristiancollins.com/generaluser.php>) is a reasonable one.

Count-in, metronome, playback rate and a measure-range loop are all in the
transport bar. The cursor and the loop highlight are drawn as overlay elements
in document millimetres, positioned per canvas tile.

## What is where

- `index.html` — the whole UI: a file input and a column of canvases.
- `main.js` — boots the engine, installs the Bravura metrics table, loads the
  two fonts, then lays out and draws each page.

## The three assets

The engine needs all of `Web/sheet-music-web/assets/`:

| file | what breaks without it |
|---|---|
| `bravura.smft` | Glyph metrics the engraver measures with. The score still renders, with visibly wrong spacing — nothing errors. |
| `bravura.woff2` | Music glyphs rasterize as tofu boxes, correctly positioned. |
| `edwin-roman.woff2` | Titles and text fall back to a system face. |

The two failure modes look nothing alike, which is useful when something renders
oddly: wrong-looking spacing points at the metrics table, tofu points at the
fonts.
