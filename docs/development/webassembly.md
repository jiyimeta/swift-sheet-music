# WebAssembly development

This document covers the Swift WebAssembly build, browser bridge, tests, and
download-size constraints.

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

## Testing the browser package

Three layers, each answering something the others cannot:

- Swift Testing on the wasm SDK covers the bridge entrypoints.
- Node parity tests pin rendered MIDI and draw-program bytes against the Apple
  build. Byte equality here is what stands behind "the browser engraves and
  renders what the app does".
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
    --swift-sdk swift-6.3.3-RELEASE_wasm js test --environment node
```

`--disable-sandbox` is required because the command plugin installs the WASI
JavaScript shim used by the test host.

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
