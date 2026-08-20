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
