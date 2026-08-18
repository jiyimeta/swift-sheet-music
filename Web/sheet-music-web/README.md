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

The generated glue imports its WASI shim by bare specifier. A bundler resolves
that for you; a page loading the ESM directly needs an import map, as
`Examples/Web/index.html` shows.

## Supported input

`.mscz`, `.mscx`, `.musicxml`, `.mxl`, `.mid` — the format is sniffed from the
leading bytes.

## Not here yet

Playback and editing. The Swift engine supports both; these bindings expose
display only so far.

[repo]: https://github.com/jiyimeta/swift-sheet-music
