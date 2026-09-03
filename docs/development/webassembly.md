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

**Equivalent with a different boundary shape.** Android's tick-space
introspection (`nativeEarliestOf` / `nativeItemEndTick` /
`nativePitchAndStaffOfNote`) and keyboard navigation
(`nativeStepMeasureCursor` / `nativeCursorAdvancedByBeats`) carry path and cursor
codecs because Kotlin can author those payloads through a second Swift image.
The wasm equivalents lower the same identities and positions to scalars instead;
the browser has no second Swift image and must not author codec blobs.
`itemEndTick` and `earliestOf` accept only notes and rests because those are the
only item kinds the playback timeline records. Measure-step direction is also
deliberately stricter at the untyped JavaScript boundary: wasm accepts only `0`
or `1`, while Android treats any nonzero value as forward. This prevents a
coerced `undefined` from silently becoming a valid forward command.

**Deliberately not ported.** Android's `nativeInstrumentParams` /
`nativeStaffParams` configure its synthesizer. Their synth content is already on
wasm's `MixerStrip`, at the deduped part-by-instrument granularity used by
`renderMidi`'s channel assignment. The genuinely missing per-staff metadata —
track name, instrument long name, and staff group — is instead carried by
`StaffDescriptor`.

**Present only on one side.** wasm has the thirteen scalar edit-intent entry
points, `editSessionState`, and the mixer surface, none of which Android needs —
its host authors intents in a second Swift image and reads its own session
directly. Android still has `nativeAnchorReferencePoint` / `nativeResolveAnchor`
for freehand-ink anchoring in a specific integration.

## Glyph centring, and why a green parity run could not see it

Until SMFT v3, Android and the browser placed ascent/descent-centred Bravura glyphs —
articulations, fermatas, breath marks — about **1.2 staff spaces (~3 mm) below where
Apple places them**. `FontMetricsTableProvider` served Bravura glyph boxes from the
`sheet-music.smft` table, but the v2 wire format had no ascent or descent fields, so
`ascent` and `descent` fell back to `StubFontMetricsProvider` for **every** face,
Bravura included:

```
stub      ascent = 0.85 × pointSize,  descent = 0.25 × pointSize
          (ascent − descent) / 2  =  0.30 × pointSize
          at the pointSize 4 "Bravura em" where 1 sp = 1 unit  →  1.2 sp

Bravura   ascender 2012, descender −2012 at 1000 upm — hhea, OS/2 typo and win
          metrics all agree, and CoreText reports the same symmetric pair
          (ascent − descent) / 2  =  0
```

`(ascent − descent) / 2` is exactly what `ArticulationGlyphMetrics`,
`FermataGlyphMetrics`, `BreathGlyphMetrics`, `ChordLineGeometry` and
`LayoutElementShape` use to put a glyph's ink on a reference Y. Those call sites took
the *bounding box* from the table and the *ascent/descent* from the stub, so one
formula was fed by two different providers.

v3 put the face's ascent and descent in the table, at the reference size like every
other value (v4 moved them from the header into a per-face record — see below). Three
things write or read them and move together: `FontMetricsTable.decode`,
`Tools/GenFontMetrics` (the browser's table, generated from CoreText and committed to
`Web/sheet-music-web/assets/sheet-music.smft` with a copy under
`Tests/SheetMusicTests/Resources/` for WASI), and `FontMetricsBuilder.kt` (Android's,
measured from `Paint.fontMetrics` at runtime). An older table is refused with
`unsupportedVersion`, so a stale asset fails `installSMuFLMetrics` rather than
engraving 1.2 sp off.

**Nothing in the parity run catches this class of bug, and the reason is
structural.** `Tools/GenWebFixtures` deliberately pins BOTH sides of the
wasm-versus-Apple comparison to the table provider, so that byte equality means "the
engines agree" rather than "the font stacks agree" — a sound goal whose side effect is
that provider-induced differences cancel out by construction. A green parity run says
nothing about whether the table provider agrees with CoreText. What does:
`ShippedMetricsTableTests` pins the committed table, both faces' vertical metrics
included, against the CoreText provider it was generated from;
`FontMetricsInstallTests` pins the installed
provider's Bravura ascent and descent to 8.048 at the pointSize-4 em on every non-Apple
shape; `FontMetricsTableTests` pins the wire layout from hand-assembled bytes; and
`LayoutElementShapeTests` / `SkylineAutoplaceTests`, whose exact-Y assertions on
centred glyphs are the ones that would have failed, run on WebAssembly through
`installFontMetrics` instead of staying behind the Apple-only guard.

## The text face, and why v4 measures it too

Through v3 the table measured Bravura and nothing else, so every text face answered
from `StubFontMetricsProvider`. That was worse than the glyph-centring bug in one
respect and better in another. Vertically it was the same shape of error, one order
smaller: 0.85 / 0.25 em against Edwin's measured 0.737 / 0.263, plus a `leading` of 0
against Edwin's 0.2 em, which put a lyric row about 1.4 pt off and a tempo mark's
Edwin half about 0.7 pt off at the sizes those suites use, and stacked every
multi-line annotation one line gap tight. Horizontally it was worse than a
mis-measurement: `StubFontMetricsProvider.advanceEm` is a *bucket estimate*, not a
table — digits 0.5, uppercase 0.65, lowercase 0.5, punctuation 0.3, CJK 1.0 em — so
every rehearsal-mark frame, harmony width and lyric width on Android and in the
browser was sized off five averages.

SMFT v4 therefore carries more than one face. The vertical metrics moved out of the
header into a per-face record, `leading` joined them, and the face's name precedes
them as length-prefixed UTF-8; `FontMetricsTable.face(named:)` matches
`LayoutFont.face` case-insensitively, because a score's `<font face="…">` is
author-supplied text. The shipped table carries Bravura over the SMuFL PUA and Edwin
over its whole BMP coverage (869 codepoints), and the asset is named
`sheet-music.smft` rather than `bravura.smft` to match.

Two limits are deliberate. A face the table does not carry still falls through to the
stub — a score naming Times New Roman gets bucket averages, as before. And a codepoint
a carried face lacks falls through *per scalar*, which matters because Edwin has no
CJK at all: a Japanese lyric is still measured at the stub's 1 em per ideograph rather
than at a flat per-glyph guess.

Two platform differences survive, both measured rather than assumed. **Widths are not
identical**: `AppleFontMetricsProvider` goes through `CTLine`, which kerns, while the table sums
per-glyph advances, which cannot — up to 0.1 em on Edwin (`P.` 99 units at the 1000 pt reference,
`AV` 96, and −28 the other way for `rit.`; digits do not kern). **Android's table carries four
fewer text codepoints than the browser's**, 865 against 869: Edwin's `cmap` maps 866 at or above
U+0020, CoreText additionally resolves U+2010, U+2011 and U+A789 to glyphs the font does not
contain, and U+00AD measures as inked under CoreText and blank under Skia. Both differences are
smaller than the bucket estimate they replaced, and both are pinned by tests rather than left to
be rediscovered.

Because the CoreText provider and the table now answer the same numbers for text, the
two assertions that used to pin an Edwin-derived Y behind
`SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT` run on every shape, at a tolerance tight
enough (0.05 pt) to fail if one platform's text metrics drift from another's. That
required one change on the Apple side: `TestSupport.installApple` registers the repo's
`Edwin-Roman.otf`, because `CTFontCreateWithName` answers an unregistered family with
the system font and the suite was otherwise measuring Helvetica while calling it
Edwin.

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

**`#if !os(Android)` does not mean "Apple only" — it is true on WASI.** An
Apple-only test file guarded that way compiles on WebAssembly and fails with
`no such module`, because the wasm test target builds against the portable graph
and has no `SheetMusicPDF`, `SheetMusicUI`, `CoreGraphics`, `PDFKit` or the rest.
There are now three non-Apple shapes, not two, and a guard written when there
were two silently stops covering. Use `#if !os(Android) && !os(WASI)`, or
`#if os(macOS)` where the file is genuinely macOS-bound.

Nothing outside the wasm CI job catches this: `swift build` does not build test
targets, and the Apple and Android jobs both compile the file successfully. It is
worth a grep — `git grep -ln '^#if !os(Android)$' -- Tests/` — after landing a
feature whose tests reach for Apple frameworks.

## The shadow stack is the smallest resource here

wasm-ld gives the shadow stack **128 KiB** by default and the Swift wasm SDK's toolset sets nothing, which is
two orders of magnitude below what a thread gets on Apple or Android. Worse, the default layout is
`[data][stack][heap]` with the stack growing *down*, so an overflow does not trap — it writes over `.bss`,
including the allocator's own state, and the process dies much later inside an unrelated `malloc` with
`RuntimeError: memory access out of bounds` and a backtrace naming none of the code responsible.

Every wasm target here therefore links with `-z stack-size=1048576` and `--stack-first` (`Package.swift`, the
`isWasm` branch). `--stack-first` puts the stack below all data so the next overflow runs off address 0 and
traps at the offending function; wasm-ld requires `--global-base` to be at least the stack size alongside it.

Two things follow for anyone writing portable code:

- **Recursive decoders need a bound on the parse, not on what the parse produced.** A limit applied after the
  tree is built cannot stop the recursion that builds it. `EditIntentCodec` shipped exactly that inversion; the
  fix is `NestedEditIntentWire`, and its doc comment is the case study.
- **Watch single frames, too.** A debug wasm build of this package has functions with 38 KiB and 31 KiB shadow
  frames on their own. Frame size is readable statically: a function that needs one opens with
  `global.get 0 ; i32.const N ; i32.sub`, and `N` is its frame.

Put linker flags on the **targets**, never on `swift package -Xlinker`: a global `-Xlinker` also reaches the
macOS host plugin tools (SwiftSyntax / BridgeJS / Wirelet macros), whose `ld` rejects wasm-ld options outright.

When something does trap inside `malloc`, relink with `--stack-first` and rerun with
`NODE_OPTIONS=--stack-trace-limit=600` before suspecting the allocator; the default 10-frame trace hides
recursion.

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

**An M4A without an edit list is 46 ms late, and every other measurement of it
looks right.** An AAC-LC encoder emits 2,048 frames of analysis delay before the
signal; the `elst` box in `trak/edts` is what hides them. Drop it and the file
still decodes, still holds the right audio, and still reports a plausible
duration — it just starts later than the WAV from the same render. Measure the
leading silence, not only the length and the peak. `elst`'s `segment_duration`
is in MOVIE units while its `media_time` is in MEDIA units; writing both in the
sample rate declares a segment 44 times too long.

## Audio export

The browser writes WAV, AIFF and M4A. Every encoder is in this package —
`src/playback/{wav,aiff,mp4}.ts` — so a host that replaces `SynthHost` still
gets an export and the bytes stay this package's contract rather than a
dependency's.

M4A goes through WebCodecs' `AudioEncoder` (`mp4a.40.2`) and an ISOBMFF muxer
written here. `MediaRecorder` will also produce `audio/mp4`, and is not used:
it records a `MediaStream` in real time, so a five-minute score would take five
minutes to export, and an `OfflineAudioContext` has no
`createMediaStreamDestination` to record from in the first place. The split
between `aac.ts` and `mp4.ts` is deliberate — `AudioEncoder` does not exist in
Node, so everything that can be tested without a browser lives on the far side
of a pure function taking frames and returning bytes.

**MP3 cannot be written in a browser.** WebCodecs has no `mp3` encoder codec and
`MediaRecorder` refuses `audio/mpeg` (measured on Chromium 151, both the
Playwright build and system Chrome). Shipping a wasm LAME would put an LGPL
dependency in an MIT package whose only runtime dependency today is the WASI
shim — for a format a host can reach by running the exported WAV through an
encoder of its own. `exportAudio({ format: "mp3" })` throws, the same state
Android reaches when a device's MediaCodec has no MP3 encoder and Apple reaches
below iOS 17 / macOS 14.

**Bit depth and channel count are not exposed**, unlike `PCMOptions` on Apple
and Android. The offline render is stereo, and 16-bit is what every consumer of
a rendered score accepts; float32 WAVE doubles the file for headroom nothing
here uses.

**Chromium writes AIFF and cannot read it back.** `decodeAudioData` takes WAV,
MP3, AAC/MP4, Ogg and FLAC; handed an AIFF it rejects with a null error. The
file is fine — CoreAudio's `afinfo` reads the same bytes as a 2-channel
44.1 kHz big-endian PCM of exactly the expected duration. So AIFF cannot be
verified by round-tripping it through the browser the way WAV and M4A are;
`Web/sheet-music-web/test/aiff.test.ts` pins it field by field in Node instead,
and the browser test only checks that it reaches the picker and downloads.

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
somewhere else musically, with nothing to signal it.

**So store a position, not a time.** `positionAtPlayerSeconds` and
`playerSecondsForPosition` convert between the player clock and a
`{measureIndex, tickInMeasure}` address, which is what everything else in the
editing surface already holds — the selection is a `ScoreItemID`, the loop is a
measure range, rehearsal marks are recomputed. `PlaybackEngine` parks its
transport on an address for the same reason. Seconds are derived at the point of
use.

Ticks would not have solved it: a notated tick changes meaning under
`SetTimeSignature`, and an unrolled tick dies with any change to the repeat
plan. The stable thing is the musical address.

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

The fixtures under `Web/sheet-music-web/test/fixtures` are generated by the
Apple build — the browser suite compares against them rather than against
numbers a test author typed. `GenWebFixtures` checks them by default and exits
non-zero on drift; both `Scripts/preflight.sh` and CI run it:

```bash
swift run GenWebFixtures \
    Web/sheet-music-web/test/fixtures \
    Web/sheet-music-web/assets/sheet-music.smft
```

When an engraving or playback change moves them on purpose, re-record and
commit the result:

```bash
SM_WEB_FIXTURE_RECORD=1 swift run GenWebFixtures \
    Web/sheet-music-web/test/fixtures \
    Web/sheet-music-web/assets/sheet-music.smft
```

Never re-record to make a red browser test go green without first establishing
that the engine change behind it was intended — that is what the fixtures exist
to detect.

The metrics table itself is committed too, and only changes when one of the two
bundled faces does. Regenerate it — and the WASI copy, which
`ShippedMetricsTableTests` checks is byte-identical — with:

```bash
swift run GenFontMetrics Web/sheet-music-web/assets/sheet-music.smft
cp Web/sheet-music-web/assets/sheet-music.smft \
    Tests/SheetMusicTests/Resources/sheet-music.smft
```

It is macOS-only and refuses to write a table measured off a face that failed to
register, since CoreText answers an unregistered family with the system font
rather than an error.

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
