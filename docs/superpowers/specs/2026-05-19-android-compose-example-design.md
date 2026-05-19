# Android Compose example app — `Examples/Android/` (Android port Phase 4, audio-deferred subset)

**Date:** 2026-05-19
**Roadmap:** Phase 4 of 4 — see memory `project_android_port_roadmap`
**Predecessors:** Phase 1 (toolchain), Phase 1.6 (`SheetMusicZip`), Phase 2
(`FontMetricsProvider`). Runs in parallel with Phase 3 (Audio backend DI);
audio is intentionally not wired in this phase and is restored in a
follow-up task after Phase 3 merges.

## Goals

End-to-end demonstration that `swift-sheet-music` is usable from an Android
Kotlin Compose app. The example app parses an `.mscz`, computes layout via
the cross-compiled Swift library, and renders pages onto a Compose `Canvas`.

This phase establishes the JNI bridge, the cross-compile + jniLibs build
pipeline, and the Gradle project structure. It deliberately stops short of
audio playback so it can ship in parallel with Phase 3.

## Non-goals

- **Audio playback.** The Play button is shown disabled. Wiring up
  `SheetMusicAudioCore` through the JNI bridge happens after Phase 3 merges
  to `main`, as a Phase 4 follow-up task. The example never depends on
  Apple-only Audio code paths.
- **Editing UI.** Note input, selection, clef change, etc. are out of scope.
  The app is read-only.
- **PDF export.** `SheetMusicPDF` stays Apple-only.
- **Android-native font metrics.** The `StubFontMetricsProvider` from
  Phase 2 (rectangle approximations) is the only renderer on Android in
  this phase. A real Android `FontMetricsProvider` (FreeType / Android
  Typeface) is a separate future phase.
- **`armv7` ABI.** Initial ABI support is `arm64-v8a` and `x86_64` only.
  `armv7-unknown-linux-android28` is in the Swift Android SDK bundle but
  requires its own physical-device verification path; defer until requested.
- **Distribution / Play Store polish.** Release signing, ProGuard tuning
  beyond the bare minimum, Crashlytics, etc. are out of scope.
- **Bundled GPL or third-party fixtures.** The example loads a developer-
  supplied `test.mscz` that is git-ignored. No fixture is checked in.

## Architecture

```
Apple host                                         Android device / emulator
─────────────                                       ──────────────────────
Sources/SheetMusicAndroidJNI/   (NEW Swift target, Android-only via
  ├ SheetMusicJNI.swift          Package.swift SWIFT_SHEET_MUSIC_ANDROID
  ├ Bridges/                     guard)
  │  ├ ScoreBridge.swift           depends on:
  │  ├ LayoutBridge.swift            SheetMusicCore + MSCX + MusicXML +
  │  └ HandleTable.swift             Layout
  └ Serialization/
     └ LayoutDocument+JNI.swift                ┌──────────────────────────┐
                                               │  Examples/Android/       │
Scripts/                                       │   app/src/main/          │
  android-build-libs.sh                        │     jniLibs/             │
    foreach triple in {arm64,x86_64}:    ───►  │       arm64-v8a/         │
      swift build --swift-sdk <triple>         │         libSheetMusicJNI │
      cp .so + Swift runtime stubs    ────────►│         libswiftCore     │
                                               │         …                │
  android-bundle-test-score.sh                 │       x86_64/            │
    cp ~/Desktop/test.mscz ────────────────►   │     assets/              │
                                               │       test.mscz          │
                                               │   app/src/main/java/     │
                                               │     com/example/         │
                                               │       sheetmusic/        │
                                               │         MainActivity     │
                                               │         ScoreViewModel   │
                                               │         ScoreView        │
                                               │         jni/             │
                                               │           SheetMusicBridge│
                                               └──────────────────────────┘
```

### Swift target — `SheetMusicAndroidJNI`

New Android-only target appended to `Package.swift` inside the existing
`#if SWIFT_SHEET_MUSIC_ANDROID` branch.

```swift
package.targets.append(
    .target(
        name: "SheetMusicAndroidJNI",
        dependencies: ["SheetMusicCore", "SheetMusicMSCX",
                       "SheetMusicMusicXML", "SheetMusicLayout"],
        path: "Sources/SheetMusicAndroidJNI"
    )
)
package.products.append(
    .library(name: "SheetMusicJNI",
             type: .dynamic,
             targets: ["SheetMusicAndroidJNI"])
)
```

`.dynamic` library so SwiftPM emits a `.so` directly. Apple hosts skip the
entire block (the env var is unset there), so existing iOS/Mac builds are
untouched. Per memory `project_android_port_roadmap` recurring pitfall,
the plan runs `swift package describe` with and without
`SWIFT_SHEET_MUSIC_ANDROID` set to confirm both shapes resolve.

### JNI surface

Minimal C-ABI surface, hand-written `@_cdecl`. The high-level
`Swift Java JNI Core` library that ships with the Swift Android SDK is
not used in this phase — its documentation is still thin (Phase 1 spec
flagged this) and the manual surface here is small enough that a thicker
wrapper would add risk without saving code.

```swift
// SheetMusicJNI.swift — entry points

@_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeLoadScore")
public func nativeLoadScore(
    _ env: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ bytes: jbyteArray
) -> jlong

@_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeReleaseScore")
public func nativeReleaseScore(
    _ env: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ handle: jlong
)

@_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeComputeLayout")
public func nativeComputeLayout(
    _ env: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ scoreHandle: jlong,
    _ pageWidthMM: jdouble,
    _ pageHeightMM: jdouble
) -> jbyteArray   // flat draw-program (see below); zero-length on error
```

`HandleTable.swift` keeps a thread-safe `[jlong: Score]` map (Swift `actor`,
or a `DispatchQueue`-guarded dictionary — pick in the plan). Handles are
opaque to Kotlin; `dispose` is invoked from Kotlin's `DisposableEffect` /
ViewModel `onCleared`.

Error handling: Swift code catches `throws`, encodes errors into the
returned byte array (status byte + UTF-8 message), and Kotlin decodes /
surfaces them in `ScoreState.ParseError`. `nativeLoadScore` returns `0`
on failure (legitimate handles start at `1`).

### Layout transport — flat draw-program

`LayoutDocument` is not reconstructed on the Kotlin side. The JNI returns
a self-describing little-endian byte array — a sequence of draw commands
the Compose Canvas replays in `DrawScope`. This avoids JSON serialization
overhead and dozens of mirror DTOs in Kotlin.

```
[u32 magic = "SMDP"][u32 version = 1]
[u32 pageCount]
  for each page:
    [f64 widthMM][f64 heightMM]
    [u32 commandCount]
      for each command:
        [u8 opcode]
        [opcode-specific payload]
```

Opcodes (initial set; extend in plan as Layout output is enumerated):

- `0x01 MOVE_TO  (f64 x, f64 y)`
- `0x02 LINE_TO  (f64 x, f64 y)`
- `0x03 STROKE   (f64 width)`
- `0x04 FILL_RECT (f64 x, f64 y, f64 w, f64 h)`
- `0x05 GLYPH    (u32 codepoint, f64 x, f64 y, f64 size, u8 fontId)`
- `0x06 TEXT     (u16 len, utf8 bytes, f64 x, f64 y, f64 size, u8 fontId)`

Versioning is fail-fast: Kotlin decoder rejects unknown magic / version.
When Layout output changes shape, encoder and decoder are updated in the
same commit.

### Kotlin app

```
com.example.sheetmusic
├── MainActivity                  // setContent { SheetMusicApp() }
├── SheetMusicApp                 // @Composable; observes ScoreViewModel
├── ScoreViewModel                // loads test.mscz, calls bridge, holds state
├── ScoreState (sealed)
│      ├── Loading
│      ├── MissingFixture
│      ├── ParseError(message)
│      └── Ready(layout, currentPage, pageCount)
├── ScoreView                     // Canvas + pan/zoom + page controls
├── DrawProgramDecoder            // byte[] → list of draw commands per page
└── jni
    ├── SheetMusicBridge          // external fun + System.loadLibrary
    └── ScoreHandle               // AutoCloseable wrapper around jlong
```

The Compose entry point loads the score on first composition:

```kotlin
class ScoreViewModel(app: Application) : AndroidViewModel(app) {
    val state: StateFlow<ScoreState> = flow {
        emit(ScoreState.Loading)
        val bytes = try {
            app.assets.open("test.mscz").use { it.readBytes() }
        } catch (_: FileNotFoundException) {
            emit(ScoreState.MissingFixture); return@flow
        }
        val handle = SheetMusicBridge.loadScore(bytes)
            ?: run { emit(ScoreState.ParseError("failed to parse test.mscz"));
                     return@flow }
        // page size — A4 in mm; future: derive from LayoutDocument settings
        val layout = SheetMusicBridge.computeLayout(handle, 210.0, 297.0)
        emit(ScoreState.Ready(layout, currentPage = 0,
                              pageCount = layout.pageCount))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ScoreState.Loading)
}
```

Pan/zoom uses `Modifier.pointerInput { detectTransformGestures }`; page
navigation is prev/next buttons over the `Canvas`. The `Play` icon button
is rendered with `enabled = false` and a `contentDescription` mentioning
"available after Phase 3 — SheetMusicAudioCore".

### `test.mscz` handling

The example needs a real MuseScore file to demonstrate parsing + layout,
but the file cannot be redistributed (copyright, including the GPL-3.0
fixtures already in `Tests/SheetMusicTests/Resources/`).

Resolution:

1. `Examples/Android/.gitignore` excludes
   `app/src/main/assets/test.mscz`.
2. `Scripts/android-bundle-test-score.sh` copies `~/Desktop/test.mscz`
   into the assets directory. The script fails loudly if the source is
   missing.
3. Gradle build always succeeds; a missing asset is a legitimate state for
   fresh clones / CI.
4. At runtime, `assets.open("test.mscz")` raising `FileNotFoundException`
   maps to `ScoreState.MissingFixture`, which the UI renders as:

       test.mscz is not bundled.

       Place a MuseScore file at:
         ~/Desktop/test.mscz

       Then run:
         Scripts/android-bundle-test-score.sh

       and rebuild the app.

`CLAUDE.md` "Things not to do" gets a new bullet forbidding commit of
`Examples/Android/app/src/main/assets/test.mscz`.

### Build scripts

`Scripts/android-build-libs.sh` (new) — compiles `SheetMusicJNI` for
each enabled ABI, stages `.so` files into `Examples/Android/app/src/main/jniLibs/<abi>/`:

- Triples: `aarch64-unknown-linux-android28`, `x86_64-unknown-linux-android28`
- ABI dir map: `aarch64 → arm64-v8a`, `x86_64 → x86_64`
- Stages `libSheetMusicJNI.so` plus Swift runtime stubs
  (`libswiftCore.so`, `libswift_Concurrency.so`, `libFoundation.so`,
  `libdispatch.so`, …) from
  `$SWIFT_ANDROID_SDK/usr/lib/swift-android/<arch>/`.
- Exports `TOOLCHAINS=org.swift.632202605101a` if unset (matches
  `Scripts/android-test.sh` convention).
- On success, prints next-step hint pointing at
  `Scripts/android-bundle-test-score.sh`.

`Scripts/android-bundle-test-score.sh` (new) — already specified above.

Both scripts live alongside the existing `Scripts/android-test.sh` /
`Scripts/gate-android-tests.sh` and follow the same env-var conventions.

### Gradle / Android Studio project

`Examples/Android/` is a self-contained Gradle project, opened directly
in Android Studio (not nested under any iOS Xcode project). Notable
choices:

- `compileSdk = 36`, `minSdk = 28` (lowest the Swift Android SDK supports).
- `ndkVersion` pinned via `gradle.properties` to whatever Phase 1 setup
  has staged under `~/Library/Android/sdk/ndk/`.
- `abiFilters "arm64-v8a", "x86_64"` so the APK only carries the two
  ABIs we actually build.
- Kotlin 2.0+ with Compose Multiplatform compiler plugin. JDK 17.
- `proguard-rules.pro` keeps the JNI package:
  `-keep class com.example.sheetmusic.jni.** { *; }`.
- Gradle wrapper checked in (`gradle/wrapper/`, `gradlew`, `gradlew.bat`).
- `Examples/Android/.gitignore` ignores `app/build/`, `.gradle/`,
  `local.properties`, `app/src/main/jniLibs/`,
  `app/src/main/assets/test.mscz`.

## Implementation strategy / risks

- **JNI surface stability.** `@_cdecl` symbol names must exactly match
  Kotlin's `external fun` JNI mangling. The plan adds a small bridge-
  generation step (or hand-checks the mangling) before any first run.
- **Swift runtime co-location.** The Swift Android SDK does not ship
  prebuilt `libswiftCore.so` etc. relocatable into arbitrary apps with
  zero work; Phase 1 already confirmed the runtime is staged under
  `usr/lib/swift-android/<arch>/`. The build script copies these
  alongside `libSheetMusicJNI.so` into `jniLibs/<abi>/`. SDK upgrades
  will need the build script's paths re-derived (treat as known
  follow-up).
- **`Package.swift` evaluation paths.** Per recurring pitfall in
  `CLAUDE.md`, `Package.swift` is re-evaluated each `swift build`. The
  plan runs `swift package describe` both with and without the
  Android env var to confirm both shapes parse.
- **Phase 3 merge order.** Both phases edit `CLAUDE.md` "Android
  build" section. The plan assumes Phase 3 lands first (it has both
  spec and plan committed in `.claude/worktrees/audio-backend-di`) and
  writes Phase 4 patches against the post-Phase-3 wording. If the
  order swaps (Phase 4 merges first), the plan's
  CLAUDE.md hunks need a small rework — flagged in the plan, not a
  blocker.
- **Worktree parallelism.** `Package.swift` itself is touched by
  Phase 4 (new target). Phase 3 also restructures `SheetMusicAudio`,
  which is unrelated to the new JNI target, so a merge conflict is
  limited to the `#if SWIFT_SHEET_MUSIC_ANDROID` block if Phase 3
  touches it (it shouldn't — Phase 3 stays Apple-side). The plan
  schedules a final rebase against `main` to catch any drift.
- **flat draw-program drift.** Encoder (Swift) and decoder (Kotlin)
  must stay in lockstep. The `version` field in the header fails fast
  on mismatch. Adding a new opcode is a two-file commit.

## Open questions (resolved in plan, not spec)

- Page-size source: hard-code A4 vs. read from `LayoutDocument.pageLayout`
  (preferred — but requires confirming the API surface from Layout).
- SMuFL glyph rendering: bundle Edwin / Bravura as Android `assets/` and
  pass `fontId` through the draw-program, or fall back to system font for
  glyph codepoints in this phase. The latter is faster to ship and
  acceptable for "the score is recognizable" verification; the former
  matches Apple-side fidelity.
- Whether `HandleTable` uses `actor` or `DispatchQueue` — Swift Concurrency
  on Android works (Phase 1 verified `swift_Concurrency.so`) but JNI
  callbacks run on arbitrary Java threads; `actor` may force unwanted
  hops. Pick after a quick measurement in the plan.

## Verification

The Phase 4 plan must verify:

1. `swift build` (Apple host, no env var) — package still resolves, all
   existing tests pass.
2. `SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a
   swift build --swift-sdk aarch64-unknown-linux-android28` — `SheetMusicJNI`
   target compiles.
3. Same with `--swift-sdk x86_64-unknown-linux-android28`.
4. `Scripts/android-build-libs.sh` emits `.so` files into both jniLibs
   subdirs.
5. `Examples/Android/` opens in Android Studio, syncs Gradle, builds
   `assembleDebug` for both ABIs.
6. App installed on an arm64 device / emulator at API ≥ 28 starts,
   shows `MissingFixture` screen when assets is empty.
7. After running `Scripts/android-bundle-test-score.sh`, app loads
   `test.mscz` and renders at least page 1 onto the Canvas; pan/zoom
   works; page next/prev cycles through `pageCount`.
8. `swift package describe` with and without `SWIFT_SHEET_MUSIC_ANDROID`
   both succeed (recurring-pitfall guard).
9. Existing `Scripts/android-test.sh` still green (Foundation-only
   library targets unaffected).
10. Mac + iOS example xcodebuild schemes still build (per memory
    `feedback_example_app_outside_swiftpm`).

Visual verification: render at least one fixture (the developer's
`test.mscz`) on a device or emulator and confirm the rendered output
matches a Mac-side preview of the same file. The Mac preview is the
ground truth; Android matches modulo `StubFontMetricsProvider`
rectangle-glyph differences (which are expected).

## Docs / memory updates

- `CLAUDE.md`:
  - "Library layout" gains no new public products (the JNI target is not
    a product on Apple).
  - "Android build" section adds an "Android example app" subsection with
    the quickstart (build-libs, bundle-test-score, open Android Studio).
  - "Things not to do" gains a bullet forbidding commit of
    `Examples/Android/app/src/main/assets/test.mscz`.
- `Examples/Android/README.md` (new) — quickstart + troubleshooting,
  matching the spec's outline.
- memory `project_android_port_roadmap` — Phase 4 (audio-deferred
  subset) marked done; remaining Phase 4 follow-ups list audio wiring
  (post-Phase-3), armv7 ABI, Android-native font metrics.
- memory `project_android_compose_example.md` (new) — JNI bridge
  location, flat draw-program rationale, `test.mscz` Desktop-copy
  workflow, Phase 3 audio wiring procedure.

## Worktree

Implementation lives in
`.claude/worktrees/android-compose-example` (branch
`worktree-android-compose-example`), branched from local `main` HEAD per
memory `feedback_worktree_layout`. Phase 4 runs in parallel with the
Phase 3 worktree (`.claude/worktrees/audio-backend-di`); see "Phase 3
merge order" risk above for the shared-files plan.
