# Android development

This document covers building and testing the Android-compatible Swift targets,
the JNI bridge, Wirelet-generated codecs, and the Kotlin modules in this
repository. Consumer setup for the published AAR lives in the individual
Android module READMEs.

## Supported surface

The Foundation-only Swift targets cross-compile with the official Swift Android
SDK: Core, MIDI, MSCX, MusicXML, XMLTools, Zip, Layout, AudioCore, EditWire, and
BridgeCore. `SheetMusicAndroidJNI` exposes the JNI entrypoints.

`SheetMusicUI`, `SheetMusicPDF`, `SheetMusicLayoutApple`, and
`SheetMusicAudioApple` remain Apple-only. Android playback is implemented in
Kotlin under `Android/SheetMusicAudioAndroid/` using FluidSynth and Oboe.

Supported ABIs are `arm64-v8a` and `x86_64`; the minimum Android API level is
28.

`armeabi-v7a` is a third, opt-in ABI rather than an unsupported one. It builds —
the Swift Android SDK carries the `armv7-unknown-linux-android28` triple and a
`swift-armv7` runtime, the NDK has the matching sysroot at
`arm-linux-androideabi`, and both native dependencies of the audio module
(FluidSynth's `.aar` and Oboe) ship the ABI. It stays out of the default because
a third full cross-compile costs roughly a third more wall clock on every local
build and every CI run, for an ABI whose share of API-28-and-later devices is
small and shrinking:

```bash
SHEET_MUSIC_ANDROID_ABIS=arm64-v8a,x86_64,armeabi-v7a Scripts/android-build-libs.sh
```

The published AAR carries the two defaults, so a consumer who needs 32-bit ARM
builds the natives themselves.

## Prerequisites

Use the open-source swift.org Swift toolchain matching the installed Android
SDK exactly. Do not use Xcode's Swift fork for cross-compilation: it rejects the
SDK's prebuilt Foundation module as compiler-incompatible.

For the current repository configuration:

1. Install the Swift 6.3.3 release toolchain from
   <https://www.swift.org/install/macos/>.
2. Put it first on `PATH` for ad-hoc commands:

   ```bash
   export PATH="$(Scripts/swift-org-toolchain.sh):$PATH"
   swift --version
   ```

   The banner must contain `swift-6.3.3-RELEASE`. The repository scripts resolve
   and prepend this path automatically.
3. Install the matching Android SDK:

   ```bash
   swift sdk install \
       https://download.swift.org/swift-6.3.3-release/android-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz \
       --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5
   ```

4. Install Android NDK r27d (`27.3.13750724`) or later and run the SDK's
   one-time sysroot setup:

   ```bash
   ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/27.3.13750724 \
       ~/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
   ```

   A missing sysroot commonly fails with `'semaphore.h' file not found` or
   `could not build C module 'SwiftOverlayShims'`.
5. Put `adb` on `PATH` and provide a device or emulator on API 28 or later.
6. Configure GitHub Packages credentials for Wirelet in
   `~/.gradle/gradle.properties`:

   ```properties
   gpr.user=<github-user>
   gpr.key=<pat-with-read-packages>
   ```

   `GITHUB_ACTOR` and `GITHUB_TOKEN` are also supported.

Re-derive download URLs and checksums from swift.org when the pinned toolchain
version changes.

## Build and test

Prefer the repository scripts:

```bash
Scripts/android-build-libs.sh
Scripts/android-test.sh aarch64 [device-serial]
Scripts/preflight.sh --android
```

For an ad-hoc library-only cross-build:

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk aarch64-unknown-linux-android28
```

Use `--build-tests` to compile the test targets. The SDK bundle form
`swift-6.3.3-RELEASE_android` also works, but the repository uses explicit
triples to control architecture and API level.

Tests importing Apple frameworks or Apple-only sub-libraries must be guarded
from manifest shapes that do not link Apple-platform test support.
`Scripts/gate-test-support-guards.sh` can add guards to new test files, but
review its diff because its heuristic can over-wrap portable tests.

After editing `Package.swift`, verify both manifest shapes resolve: ordinary
SwiftPM and a build with `SWIFT_SHEET_MUSIC_ANDROID=1`.

### The font-metrics table needs a device

`FontMetricsBuilder` measures Bravura and Edwin out of the caller's assets at
runtime, so nothing on the host exercises it and a wrong measurement does not
fail anything — it engraves, slightly wrongly, on Android alone.
`FontMetricsBuilderTest` is an instrumented test that builds the table on a
device and pins it against the one `Tools/GenFontMetrics` writes from CoreText:

```bash
Android/gradlew -p Android :SheetMusicAndroid:connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.class=io.github.jiyimeta.sheetmusic.FontMetricsBuilderTest
```

It needs the two OFL fonts in the test APK; the module's `androidTest` asset
source set borrows `SheetMusicComposeAndroid`'s copies rather than committing a
third set. On an `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, uninstall the stale
package first: `adb uninstall io.github.jiyimeta.sheetmusic.test`.

**Do not reach for `Paint.hasGlyph` to ask what a face covers.** It consults the
system fallback chain even for a `Typeface.createFromAsset` face — measured on a
Pixel 8a it reports that Edwin has CJK, kana and emoji — and `getTextWidths` and
`getTextPath` substitute the same way. The builder parses each font's own `cmap`
for that reason, and the instrumented test pins the resulting glyph counts.

## Wirelet bootstrap and schema rules

Gradle invokes `io.github.jiyimeta.wirelet` against SwiftPM's pinned checkout.
Populate it after cloning:

```bash
swift package resolve
```

For local Wirelet development, use SwiftPM's package override:

```bash
swift package edit Wirelet --path /path/to/swift-wirelet
swift package unedit Wirelet
```

Each Wirelet `schemaPaths` registration scans exactly one directory. A
`@WireFormat` type outside a registered directory produces no codec and no
warning. Before moving a schema, search every Gradle scanner across both
`Android/` and `Examples/`:

```bash
rg "Sources/SheetMusic" Android Examples -g '*.kts'
```

Important consequences:

- A second scan root needs a second named registration.
- Only a source set named `main` is wired into Android variants automatically;
  other names need their generated output and task dependency added manually.
- Apple builds do not validate generated Kotlin codecs. Run the Android gate.
- Moving the same files between parent directories may leave the generation
  task `UP-TO-DATE`. Remove the affected module's
  `build/generated/wirelet/` output, regenerate, and compare the result.

`Scripts/android-build-libs.sh` stages jextract output from SwiftPM. SwiftPM may
leave deleted declarations in its plugin output directory, so after removing or
moving public JNI declarations, clean that plugin output before trusting the
staged `java-generated/` tree.

## Example app

The Compose example lives in `Examples/Android/`. From the repository root:

```bash
Scripts/android-build-libs.sh
cp /path/to/score.mscz ~/Desktop/test.mscz
cp /path/to/GeneralUserGS.sf2 ~/Desktop/gm.sf2
Scripts/android-bundle-test-score.sh
```

Then open `Examples/Android/` in Android Studio. The score and SoundFont staged
under the app's assets are local, gitignored inputs; never commit them.

## Distribution

The `v*` tag workflow publishes these GitHub Packages artifacts together:

- `io.github.jiyimeta:sheet-music-android`
- `io.github.jiyimeta:sheet-music-audio-android`
- `io.github.jiyimeta:sheet-music-compose-android`

Consumers need a PAT with `read:packages`. See
`Android/SheetMusicAndroid/README.md` for repository and packaging setup.

## Troubleshooting checklist

- Compiler-module mismatch: confirm `swift --version` is the swift.org release,
  not Xcode's fork or an unresolved `swiftly` shim.
- Missing `semaphore.h`: rerun the NDK sysroot setup.
- Missing JNI library: run `Scripts/android-build-libs.sh` and verify both ABI
  directories.
- Missing generated Kotlin codec: verify every `schemaPaths` registration,
  clean generated Wirelet output, and run the Android preflight.
- Stale generated Java after a Swift API move: clean the jextract plugin output
  before rebuilding.
