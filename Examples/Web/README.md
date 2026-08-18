# Browser viewer example

Reads a MuseScore or MusicXML file, engraves it in WebAssembly, and draws the
result on a `<canvas>`. Everything runs in the page — no server-side rendering,
no network calls after the initial load.

## Run it

    Scripts/wasm-build-web.sh                       # wasm + PackageToJS glue
    npm --prefix Web/sheet-music-web install
    npm --prefix Web/sheet-music-web run build      # TypeScript -> dist-esm/
    Scripts/web-example-serve.sh                    # http://localhost:8080/Examples/Web/

Then pick a `.mscz`, `.mscx`, `.musicxml`, `.mxl` or `.mid` file.
`Web/sheet-music-web/test/fixtures/sample.mscz` is a small one to start with.

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
