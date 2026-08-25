# WebAssembly development

This document covers the Swift WebAssembly build, browser bridge, tests, and
download-size constraints.

## Parity with the Android surface

The two bridges are close but not identical, and the differences are of three
kinds.

**Structurally absent.** The PDF entry points (`nativeLoadScoreFromPDF`,
`nativePdfHitTest`, `nativePdfCursorRect`, `nativePdfPageSizes`,
`nativeReleasePdfGeometry`, `nativeLoadScoreWithGeometryFromPDF`) have no wasm
equivalent because `SheetMusicPDF` is not in the portable graph.

**Deliberately collapsed.** Android polls FluidSynth's unrolled ticks, so it
carries `nativeFrameAtTick`, `nativeSecondsAtTick`, `nativeUnrolledTickForNotated`,
`nativeCursorFrame`, `nativeNearestCursor` and `nativeFrameForCursor`. A Web
Audio sequencer reports seconds, so this surface speaks seconds and folds those
into `cursorRectAtPlayerSeconds` and `playerSecondsAtPoint`. Likewise
`nativeTimelineSummary` is `playbackSummary`, `nativeGMInstrumentList` is
`gmInstrumentNames` + `gmInstrumentFamilies`, and `nativeCountIn` is
`countInSeconds` + `renderCountInMetronomeMidi`.

**Present only on one side.** wasm has the thirteen scalar edit-intent entry
points, `editSessionState`, and the mixer surface, none of which Android needs —
its host authors intents in a second Swift image and reads its own session
directly. Android still has `nativeAnchorReferencePoint` / `nativeResolveAnchor`
(freehand-ink anchoring for a specific integration), the tick-space introspection
`nativeEarliestOf` / `nativeItemEndTick` / `nativePitchAndStaffOfNote`, the synth
configuration `nativeInstrumentParams` / `nativeStaffParams`, and the keyboard
navigation `nativeStepMeasureCursor` / `nativeCursorAdvancedByBeats`.

## Supported surface

The portable graph includes Foundation, Core, XMLTools, Zip, MIDI, Layout,
MSCX, MusicXML, AudioCore, EditWire, and BridgeCore. Apple UI, PDF,
LayoutApple, and AudioApple targets are excluded.

`SheetMusicBridgeCore` owns the platform-neutral bridge implementation.
`SheetMusicWasmBridge` exposes `@JS` entrypoints, while the small
`SheetMusicWasmEntry` executable exists so PackageToJS can package a product and
link the bridge library.

## Toolchain and dependencies

The swift.org toolchain and wasm SDK versions must match exactly. Xcode's Swift
does not provide the required WebAssembly backend.

```bash
swift sdk install \
    https://download.swift.org/swift-6.3.3-release/wasm-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_wasm.artifactbundle.tar.gz \
    --checksum cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7

export PATH="$(Scripts/swift-org-toolchain.sh):$PATH"
swift build --swift-sdk swift-6.3.3-RELEASE_wasm --target SheetMusicLayout
```

The browser package also needs Homebrew's `brotli` and `binaryen`; `woff2` is
needed only when replacing the bundled font.

## Portable import boundary

Portable targets import `SheetMusicFoundation`, not the `Foundation` umbrella.
On WASI and other portable platforms it re-exports `FoundationEssentials` plus
the platform C library. The umbrella pulls ICU into the wasm and can add roughly
10 MB to the compressed artifact.

Use the compatibility APIs in `SheetMusicFoundation`:

- `SerialLock` instead of relying on `DispatchQueue` on WASI.
- Its whitespace trimming helpers instead of `CharacterSet` APIs.
- `FormatG` and `ISODate` instead of umbrella-only formatting APIs.
- Platform geometry stubs or a `canImport(CoreGraphics)`-guarded overload for
  `CGFloat`, `CGRect`, and `CGPoint`.

The SwiftLint `no_foundation_umbrella` rule is the fast source-level gate. A
genuinely platform-scoped exception needs a local disable and an explanation.

## Browser bridge constraints

- `Int` is 32 bits on wasm32. Carry full-width identifiers such as version
  stamps and fingerprints as decimal strings when JavaScript/JSON parity must
  remain exact.
- A `@JS struct` needs an explicit `public init`; the memberwise initializer is
  internal.
- BridgeJS generates a thunk only for the target to which it is attached. Keep
  exported entrypoints physically in `SheetMusicWasmBridge`.
- Byte blobs cross as `JSUint8Array`, not `[UInt8]`. A `[UInt8]` parameter is
  lowered one wasm import call per byte, and a `[UInt8]` return is lifted into a
  boxed JavaScript `Array`; `JSUint8Array` is a single object id with one bulk
  copy each way, and the generated TypeScript says `Uint8Array`. The `[Double]`
  faces stay boxed on purpose — their payloads are hundreds of bytes crossed
  once per user action, where an object id's lifetime costs more than it saves.
- `JSUint8Array` is a `JSObject` subclass, so `==` on two of them compares
  object identity, not bytes. Two calls returning identical blobs are not equal.
  Compare `.bridgedData`. This fails quietly in the worst way: a test written as
  `#expect(a == b)` compiles, reads correctly, and asserts the wrong thing.
- `WasmParityProbe` must not depend on JavaScriptKit because it runs directly in
  wasmtime, where JavaScript-host imports cannot be resolved.
- `SheetMusicZip` uses the vendored raw-DEFLATE implementation under
  `Sources/zlib` only when `SWIFT_SHEET_MUSIC_WASM=1`. Use
  `Scripts/vendor-zlib.sh` when updating it.

The browser host owns the synthesizer. Swift exports rendered MIDI, playback
timeline data, and geometry; the JavaScript package owns transport and audio.
Every playback position crossing that boundary is in unrolled player seconds,
not notated ticks.

Rendered MIDI intentionally omits mixer-managed program changes and CC 7.
Browser playback must reassert instrument and volume state from the mixer after
loads and seeks.

## Playback failure modes

Each of these ships green. They are recorded because a passing test suite is
what let every one of them through once.

**Missing instrument state sounds like a working build.** Rendered MIDI omits
the mixer-managed program change and CC 7, so a host that does not reassert them
plays the score in time, with a correct cursor, entirely in Acoustic Grand
Piano. Percussion hides it: channel 9 selects the drum bank whatever the program
says, so the drums are right and the failure reads as one odd instrument rather
than as nothing being applied.

**A fixture whose parts are all piano cannot catch that.** Program 0 is both
what such a score asks for and what an unasserted General MIDI channel falls
back to, so "applied" and "not applied" are the same observation. Playback
fixtures need at least two melodic parts on different non-zero patches, and
distinct volumes; `mixer.mscz` exists for this.

**A fixture without a repeat cannot test the playback clock.** `UnrolledTimeMap`
is the identity on a score with no repeat plan, so notated and player seconds
coincide and every conversion is a no-op. An implementation that dropped the
projection entirely would still match. `repeat.mscz` separates the two clocks.

**`unrolledSeconds(fromNotated:)` answers with the FIRST occurrence.** That is
correct for a seek, a play-from and a loop wrap, and wrong for "where on the
player's clock does this measure-play sit" — asking it that question puts every
beat of a repeat's second pass back on the first pass's time.

**An offline render fails as correct-length silence.** `startOfflineRender`
takes its whole configuration up front, because Chromium drops worklet messages
aimed at an `OfflineAudioContext`. A misconfigured render therefore produces a
buffer of exactly the expected size, empty. Assert a peak level, not a byte
count.

**A sequencer's position is stale for a buffer or two after a seek.** Setting it
is a message to the worklet, so reading it straight back gives the old value.
Anything drawn from that reading shows where playback was: invisible while
playing, because the next frame corrects it, and permanent while paused — which
is exactly when a click-to-seek happens. Draw from the position that was seeked
to.

**Adding a sound bank does not prioritize it.** A click bank layered onto the
metronome loads and stays inaudible until it is moved to the front of the
priority order, because the General MIDI bank underneath keeps answering the
click notes.

## Editing

Android's edit surface is a relay: the host keeps the authoritative score in a
second Swift image, encodes an intent there, and Kotlin couriers the bytes. A
browser has no second Swift image, so JavaScript authors the edit. Each of the
thirteen leaf `EditIntent` cases has its own entry point taking lowered scalars,
and Swift builds the intent. `.composite` is the exception — it has nowhere to go
in a flat argument list — and rides `applyEditIntentBytes`, which is Android's
relay contract verbatim.

A session is keyed by the score handle the caller already holds; no second handle
is minted. `beginEditSession` is idempotent and drops the undo stack when
re-opened. Ending a session is not a revert.

**Every accepted edit must invalidate the layout cache AND the playback clock
cache.** Android only needs the first because it rebuilds its timeline per query.
Leave `PlaybackClockCache` in place here and `cursorRectAtPlayerSeconds`,
`playerSecondsForMeasure` and `playbackSummary` keep answering from the timeline
of a score that no longer exists — no exception, just a cursor that stops
agreeing with the notation.

**The host order is: accepted, then `layout()`, then geometry.** Publishing drops
the cached document, so `editingCaretRect`, `editingHitTest`, `pageBreaks` and
the cursor calls all answer nil or empty between an accepted edit and the next
`computeLayout`. That is the contract, not a bug.

**An edit during playback desynchronizes silently.** The wasm caches are dropped
correctly, but a `PlaybackEngine` built earlier still holds the SMF it rendered,
the summary it read and the mixer map it seeded. The sequencer then performs the
old score while the cursor tracks the new one. `Score.editGeneration` counts
accepted edits and the engine refuses `play` / `seekToMeasure` / `seekToPoint` /
`exportWav` once it has moved — a loud error in place of a slow divergence.

**A stored position in seconds does not survive an edit.** This surface speaks
player seconds rather than ticks, which is right for playback — the sequencer
reports seconds, the cursor wants a continuous value, and a click resolves
through a `ScoreCursor` so the geometry never passes through seconds. But
seconds depend on the tempo map and on note durations, and an edit changes both.
A tick keeps its musical meaning across an edit; a second does not. `play` and
`seek` are protected by `editGeneration`, so this cannot bite during playback —
but a host that persists a seconds bookmark, edits, and restores it lands
somewhere else musically, with nothing to signal it. Store a measure index, or
re-derive the seconds after the edit.

Measure boundaries themselves round-trip safely: `measureIndex(atPlayerSeconds:)`
converts back to a tick and compares against integer measure starts, so the
float only participates in one conversion rather than in the comparison. Two
hundred and five boundaries were checked across the committed fixtures with no
mismatch — all at 120 BPM, so a tempo whose boundaries are not exact binary
fractions remains unverified.

**A hit test is not a nearest match.** `editingHitTest` answers nil on empty
paper so a tap can deselect; `playerSecondsAtPoint` next door always resolves,
because a seek has to go somewhere. Unifying them would break deselection.

No lock guards whole operations. Android holds one because JNI entry points
arrive on arbitrary threads; wasm32-wasip1 is single-threaded and an exported
function runs to completion on the JavaScript main thread. The session table's
`SerialLock` is there for Swift 6's global-mutable-state checking, not for
protection. A Worker rendering path must keep this true by giving each Worker its
own wasm instance rather than adopting shared-memory threads.

## Testing the browser package

Three layers, each answering something the others cannot:

- Swift Testing on the wasm SDK covers the bridge entrypoints.
- Node parity tests pin rendered MIDI and draw-program bytes against the Apple
  build. Byte equality here is what stands behind "the browser engraves and
  renders what the app does".
- The edit replay does the same for editing, in fingerprints rather than bytes:
  `EditReplayScript.standard`'s fourteen steps run on an Apple host, on an
  Android device, and through the browser facade, all pinned to the same fifteen
  fingerprints in `assets/editReplay/goldens.txt`. There are no wire bytes on the
  browser path to compare — it authors intents from scalars — so fingerprint
  equality is the claim. Assert each step was accepted as well as its
  fingerprint: a step that silently refused leaves the previous step's value in
  place, and a golden recorded from the same broken run matches it.
- Playwright covers what only a real browser can answer: that the AudioWorklet
  instantiates, that the synth accepts the rendered sequence, and that its clock
  advances. Audio itself is not asserted; the cursor stands in, since it moves
  only if the transport does.

**Compare the canvas backing store, not an element screenshot.** An element
screenshot is rasterized at the element's position on the page, so any change to
the surrounding chrome shifts it by a fraction of a device pixel and
re-antialiases every glyph. The comparison then fails without a drawing command
having changed, and the response is to re-bless the baseline — which is how a
rendering guard stops guarding. `canvas.toDataURL()` does not care where the
canvas sits.

## Tiles and bands

They are different units and they compose:

- A **tile** is a canvas allocation unit. `planPageTiles` divides a page into
  equal, contiguous, non-overlapping slices, because a canvas taller than 65,535
  px silently draws nothing in Chromium and a seam that repeats or drops a row of
  pixels is visible on a staff line.
- A **band** is a command-culling unit. `splitIntoBands` walks the command stream
  once and cuts at the first boundary past 80 mm of painted height where cutting
  is safe — no path mid-construction, no rotation open. Bands have variable
  height, follow the ink rather than a grid, and may overlap.

`drawTile` selects the bands whose painted extent reaches a tile and walks only
those. `drawPage` still walks everything and lets the canvas clip; that is the
right choice for a page that fits one canvas.

Two things to keep in mind when touching this:

- **A band restates its paint state.** It opens with the colour and dash in force
  where it starts, so it can be replayed alone. The commands walked for a tile
  are therefore the page's plus up to two per band drawn — never assume the sum
  over bands equals the page's command count.
- **Glyph bounds are deliberately generous** (`y − 2·size … y + size`, from the
  Kotlin), because measuring would need a typeface and a split has to stay a pure
  function. Over-reporting costs a little culling efficiency; under-reporting
  would clip real ink. `stretchedGlyph` is exact.

`bands.ts` is a port of `Android/SheetMusicComposeAndroid/.../ScoreBands.kt` and
divergence from it is a bug, the same contract `canvas.ts` holds against
`ScoreCanvas.kt`. Android does not need `drawTile`: it gives each band its own
Compose layer and the framework rejects the off-screen ones. Canvas2D has no
display list, so the selection is explicit here.

## Virtualized rendering

A viewer keeps canvases only for the tiles near the viewport. Before that, the
example rasterized every tile of every page at load: measured in Chromium, 80.4
MB of canvas for the 1,757 mm test fixture and 151.8 MB for a 149-part score,
linear in the score's length with nothing bounding it. After, both sit between
18 and 37 MB whatever the score's length.

`planViewportTiles` cuts to a target height rather than only at the canvas
dimension limit, so there is something to mount granularly; `reconcileMounts`
decides what to mount and drop. Both are pure, which is what lets the gate assert
in vitest that two documents of different lengths mount the same number of tiles.

**Scroll must not redraw.** Tiles are DOM canvases and the compositor pans them
on the GPU with no JavaScript involved. Scroll events drive mounting and nothing
else. Redrawing per frame would replace a free pan with work — that is Compose's
situation, not a browser's.

**Mount and unmount thresholds differ on purpose.** Mount reaches one viewport
beyond the visible range, unmount only past two. With one threshold, a tile edge
landing on it thrashes: mounting the tile does not move the scroll position, so
the next scroll event re-tests the same boundary.

**Zoom re-rasterizes; `staffSize` re-engraves.** The draw program is in document
millimetres and resolution-independent, so magnification only changes `pxPerMM`
and never crosses the bridge. They are separate controls, and folding them
together makes every zoom step pay for a layout it does not need.

**Zoom has to restore its anchor.** Record the document millimetre at the top of
the viewport, change the scale, then put it back. Without it the view lands
wherever the new scroll height happens to put it — measured at 813 mm of drift
on a mid-document zoom, and nothing errors.

**Overlays are positioned in document space, not against a tile.** A tile can
unmount while a caret sits over it. One overlay layer the size of the spacer,
everything absolutely positioned inside it.

**A click's document position comes from the spacer's bounding rect on both
axes.** That rect is already in viewport coordinates and already shifted by the
scroll. Composing the vertical half out of `scrollTop`, the container's rect and
`offsetTop` double-counts the scroll container's padding, and a few millimetres
is enough for a tap to miss the staff it was aimed at.

There is no Worker, and the reason is a measurement rather than a preference: a
viewport-sized redraw costs 0–0.1 ms (1.4 ms worst) and decode plus band split
costs 3.3 ms, so a renderer Worker would have nothing to protect. The only real
stall is `computeLayout` at 10–22 ms, which lives in the bridge and happens on
load and on edits rather than per frame. Moving that would mean moving the whole
bridge, which turns every cursor, hit-test and caret query into a postMessage
round trip and breaks the synchronous facade the editing surface is built on.

## Build and test

Build the browser package with:

```bash
Scripts/wasm-build-web.sh
npm --prefix Web/sheet-music-web install
npm --prefix Web/sheet-music-web run build
```

Run the portable Swift tests through PackageToJS:

```bash
SWIFT_SHEET_MUSIC_WASM=1 swift package --disable-sandbox \
    --swift-sdk swift-6.3.3-RELEASE_wasm js test --environment node \
    --prelude Scripts/package-to-js-test-prelude.mjs
```

`--disable-sandbox` is required because the command plugin installs the WASI
JavaScript shim used by the test host.
The prelude populates PackageToJS's in-memory WASI filesystem from SwiftPM's
generated `SheetMusicTests` resource bundle under `.build/wasm32-unknown-wasip1`;
it does not copy fixtures from `Tests/SheetMusicTests/Resources`.
Swift tests should read fixtures through `Tests/SheetMusicTests/Helpers/TestResources.swift`:
native platforms still use `Bundle.module`, while WASI reads the preopened
bundle path. This keeps the GPL fixtures confined to the SwiftPM test target;
do not make the prelude copy from the source fixture tree.

As of the wasm test-suite migration, the collected surface is:

- Apple: 2908 tests.
- wasm: 1571 tests.
- Net gap: 1337 tests, with 62 wasm-only bridge tests offsetting 1399 Apple
  tests absent from wasm.

The absent Apple tests break down by cause:

- 875 tests: whole-file `SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT` guards
  for Apple frameworks/products or Apple font/audio/PDF test support.
- 9 tests: scoped `SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT` guards.
- 239 tests: `SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT` guards for JNI/Wirelet
  bridge tests that currently run only in the Apple-host test shape.
- 242 tests: legacy platform guards not yet migrated to named predicates.
- 10 tests: scoped legacy platform guards.
- 13 tests: whole `SheetMusicAudioAppleTests` target, absent from the wasm
  manifest shape.
- 10 tests: individually predicated host capabilities or reference-oracle checks
  unavailable in the current wasm test host.

The XML reference-oracle boundary is intentional:

- The differential oracle is Apple's Foundation `XMLParser`, the historical
  implementation that `XMLTreeParser` replaced and that the byte-identical MSCX
  corpus gates encode. swift-corelibs-foundation's WASI `XMLParser` is a
  different implementation, not that reference: it drops CDATA text and accepts
  multiple roots. The comparison therefore stays confined to the manifest shape
  where `SHEET_MUSIC_HAS_FOUNDATION_XML_REFERENCE_ORACLE` is defined, instead
  of changing the production parser to match the WASI implementation. The
  adversarial XML corpus now carries checked-in `XMLTreeNode` expectations
  asserted on every platform, so the wasm side is no longer assertion-free.

Run the direct zlib parity probe with:

```bash
SWIFT_SHEET_MUSIC_WASM=1 swift run WasmParityProbe <file.mscz>
wasmtime --dir . .build/wasm32-unknown-wasip1/debug/WasmParityProbe.wasm <file.mscz>
```

## Size gates

Two complementary gates protect the browser download:

1. SwiftLint's `no_foundation_umbrella` rule identifies the source import that
   would pull in ICU.
2. `Scripts/wasm-size.sh` measures the entire portable dependency graph and
   catches growth arriving through dependencies or APIs.

```bash
Scripts/wasm-size.sh
Scripts/wasm-size.sh --report
```

The wider brotli measurement has a 4 MB ceiling. The script also reports the
optimized artifact that a browser downloads; these numbers are intentionally
different and are not interchangeable.

When a dependency changes, measure from a clean wasm build. Incremental output
can retain an older dependency artifact and report a size that does not respond
to the source change. Any new wasm surface must also be reachable from
`WasmSizeProbe`, or dead-code elimination makes the measurement meaningless.

`Package.resolved` is manifest-shape dependent. Declare lightweight wasm-only
dependencies unconditionally when practical so running different manifest
shapes does not churn its origin hash.

For byte-for-byte parity, both sides must use the same `FontMetricsProvider`.
The generated SMuFL table stores rescaled `Float` values and does not produce
identical low bits to CoreText. Install the table in parity fixtures rather than
comparing one provider with the other.
