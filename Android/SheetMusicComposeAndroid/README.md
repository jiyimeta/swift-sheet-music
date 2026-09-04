# SheetMusicComposeAndroid

Jetpack Compose rendering for [swift-sheet-music](https://github.com/jiyimeta/swift-sheet-music):
it decodes the draw program `SheetMusicAndroid` produces, paints it on a
Compose `Canvas`, overlays the playback cursor and loop highlight, and
exports the same pages to PDF.

This module owns no engraving of its own. Everything it draws is decided
by the Swift layout engine and arrives as a **draw program** — a flat list
of painter commands in document millimetres. That is deliberate: the same
program drives the Apple renderer's geometry and the browser's, so a
notation bug is fixed once rather than three times.

It also bundles the two OFL fonts the renderer needs
(`Bravura.otf`, `Edwin-Roman.otf`) so a consumer does not have to source
them, and `SheetMusicAndroid`'s `FontMetricsBuilder` measures those same
assets.

## What you need to consume it

Identical to the other two modules, and for the same reasons — a
`read:packages` PAT plus a one-time `swiftkit-core` publish to Maven
local. Follow
[`../SheetMusicAndroid/README.md`](../SheetMusicAndroid/README.md)'s
"What you need to consume it" section, then add:

```kotlin
dependencies {
    // Brings :sheet-music-audio-android and :sheet-music-android with it.
    implementation("io.github.jiyimeta:sheet-music-compose-android:<version>")
}
```

The dependency is transitive (`api`), so naming this module alone is
enough for a host that renders *and* plays.

## Usage

### Render a page

```kotlin
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.compose.render.ScoreCanvas
import io.github.jiyimeta.sheetmusic.compose.render.ScoreTransform
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider

// `layoutBytes` is what SheetMusicJNI.nativeComputeLayout returned.
val program = DrawProgramReader.decode(layoutBytes)
val fonts = bundledFontProvider(context)

var transform by remember { mutableStateOf(ScoreTransform()) }
var pxPerMM by remember { mutableFloatStateOf(0f) }

ScoreCanvas(
    page = program.pages[0],
    fontProvider = fonts,
    transform = transform,
    onTransformChange = { transform = it },
    onPxPerMMChange = { pxPerMM = it },
)
```

`ScoreCanvas` owns pinch-zoom and pan. If the score lives inside a native
scroll container that already owns scrolling, use `ScorePage` instead: it
installs no pointer input and takes `pxPerMM` directly, so baking zoom
into that value re-rasterizes glyphs at the target resolution rather than
scaling a bitmap.

### Long scores: bands

A continuous (non-paginated) layout is one page whose command list covers
the whole document — tens of thousands of commands for a long score.
Handing that to one canvas puts every command in a single display list,
and a scrolling host then walks the entire list every frame.

```kotlin
val bands = program.pages[0].splitIntoBands()   // default 80 mm
```

Each `ScoreBand` is self-contained: it opens by restating the paint state
in force where it starts (colour, dash, text style), so it draws correctly
without replaying what came before it. Give each band its own layer and an
off-screen band is rejected once, by its bounds.

### Continuous view: the sticky header

A reader who has scrolled past bar 1 of a horizontal layout cannot see what key
and metre they are in. `StickyHeaderPane` is MuseScore's answer — the current
clef, key signature, time signature and instrument name, frozen at the
viewport's left edge and drawn at half opacity to say they are a restatement:

```kotlin
Box {
    ScorePage(page = program.pages[0], fontProvider = fonts, pxPerMM = pxPerMM)
    StickyHeaderPane(
        scoreHandle = handle.raw,
        documentScrollXMm = scrollOffsetPx / pxPerMM,
        pxPerMM = pxPerMM,
        fontProvider = fonts,
        modifier = Modifier.align(Alignment.TopStart),
    )
}
```

The pane is engraved by the Swift layout engine and arrives as an ordinary
one-page draw program, so it is painted by the same renderer the score is. It
re-engraves only when the scroll position crosses into another millimetre, so a
smooth scroll costs one JNI round trip per bar rather than one per frame.

Lay the score out in horizontal mode (`layoutMode = 1`) — the pane exists for
that mode, and in page mode the header is already on screen.

### Break indicators

`BreakIndicatorOverlay` marks the measures that carry an explicit
`<LayoutBreak>`, so an author can see where the file forces a system or page to
end. Ask for them when computing the layout —
`LayoutOptionsWire.breakIndicatorVisibilityRaw` is `0` none (the default), `1`
page breaks only, `2` all — then overlay:

```kotlin
BreakIndicatorOverlay(
    scoreHandle = handle.raw,
    pxPerMM = pxPerMM,
    transform = transform,
)
```

The bridge applies the break *policy* before the visibility, so a badge never
appears for a break the current layout is ignoring. The badge itself is a fixed
16×12 px and does **not** scale with the staff: it is an authoring hint about the
file, not notation, and one that shrinks with the music becomes unreadable
exactly when the score is zoomed out to look at its breaks.

### Playback overlays

`PlaybackCursorOverlay` and `LoopHighlightOverlay` take the same
`ScoreTransform` and `pxPerMM` the canvas reports, so they stay registered
with the score through zoom and pan. Draw the loop highlight first — the
cursor is meant to sit on top of the amber fill.

### Export to PDF

```kotlin
import io.github.jiyimeta.sheetmusic.compose.export.writePdf

contentResolver.openOutputStream(destination)?.use { out ->
    program.writePdf(out, fonts)
}
```

One PDF page per `EncodablePage`, at exactly the page size the layout
produced — so the paper is chosen by laying the score out in `.page` mode
with the size you want to print. Glyphs stay vector: `Canvas.drawText` on
a PDF canvas becomes a PDF text operator with the typeface embedded.

A continuous program exports as one very long page. That is legal PDF and
almost never what a reader wants; paginate first.

## Fonts

`bundledFontProvider(context)` returns the two typefaces from this
module's own assets. Pass your own `FontProvider` to override either.

The metrics table is separate and must be installed before laying
anything out — see `FontMetricsBuilder` in
[`../SheetMusicAndroid/README.md`](../SheetMusicAndroid/README.md).
Without it the layout falls back to rectangle approximations that are
sane but not correct.

## ABI matrix

This module is pure Kotlin and carries no native code of its own, so its
ABI support is whatever `sheet-music-android` supports:

| ABI         | Status |
|-------------|--------|
| arm64-v8a   | Supported (primary) |
| x86_64      | Supported (emulator) |
| armeabi-v7a | Buildable, opt-in — see [`../SheetMusicAndroid/README.md`](../SheetMusicAndroid/README.md#abi-matrix) |

Minimum SDK: 28 (Android 9).

## License

MIT. Bundles Bravura and Edwin under the SIL Open Font License 1.1; see
`src/main/assets/fonts/Bravura.LICENSE.txt` and `Edwin.LICENSE.txt`.
