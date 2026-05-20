# Android GitHub Packages Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distribute the Android Kotlin libraries (`SheetMusicAndroid` core + `SheetMusicAudioAndroid` audio) to GitHub Packages so external Kotlin/Jetpack Compose apps can consume them via Maven coordinates, replicating the SwiftPM "just point at the repo URL" experience while the repo is still private.

**Architecture:**

1. **Library-owned JNI namespace.** Rename the five `@_cdecl` JNI symbols currently bound to `com.example.sheetmusic.jni.SheetMusicBridge` to `io.github.jiyimeta.sheetmusic.SheetMusicJNI`. The bridge becomes a published Kotlin object that any consumer (the example app, or a third-party Compose app) can call directly.

2. **Two Gradle modules.**
   - `Android/SheetMusicAndroid/` (new) — owns `SheetMusicJNI.kt`, `ScoreHandle.kt`, `BravuraMetricsBuilder.kt`. Bundles prebuilt `libSheetMusicJNI.so` + Swift runtime `.so` files into the AAR via `jniLibs.srcDirs`. Loads `libSheetMusicJNI` in a `System.loadLibrary` companion initializer. Group `io.github.jiyimeta`, artifact `sheet-music-android`.
   - `Android/SheetMusicAudioAndroid/` (existing) — adds `api(project(":SheetMusicAndroid"))` to inherit the JNI .so transitively. Removes its own `System.loadLibrary("SheetMusicJNI")` (the core module now owns that).

3. **GitHub Packages on tag.** A new `.github/workflows/android-publish.yml` triggers on `v*` tag push, cross-compiles the Swift JNI for both ABIs, runs `./gradlew publishReleasePublicationToGithubPackagesRepository` on each module. Version is derived from the tag (`v0.1.0` → `0.1.0`). Authentication uses the workflow's built-in `GITHUB_TOKEN`.

4. **Composite-build example.** `Examples/Android/settings.gradle.kts` keeps its `includeBuild("../../Android")` composite, but with an added `dependencySubstitution` for `sheet-music-android`. The example app stops vendoring JNI Kotlin code in its own package; it depends on the core module and uses `io.github.jiyimeta.sheetmusic.SheetMusicJNI` directly.

**Tech Stack:** Swift 6.3.2 (host + Android cross-compile), Kotlin/JVM via AGP 8.5 + Kotlin 2.0.20, Gradle 8.x, Android API 28+, FluidSynth 2.4.6 (transitive, LGPL-2.1 dynamic-link), GitHub Actions, `maven-publish` Gradle plugin.

**Out of scope (deliberate):**
- Maven Central / JitPack publishing (deferred until repo goes public).
- SoundFont sample asset distribution (consumer responsibility per existing README).
- Signing of the AAR with PGP (GitHub Packages does not require it; add when migrating to Maven Central).
- API documentation site (dokka).

---

## Task 0: Migrate existing audio module namespace `kiichiio` → `jiyimeta`

**Why first:** Plan-wide we agreed on `io.github.jiyimeta` as the reverse-DNS group ID (matches the GitHub username). The existing `SheetMusicAudioAndroid` module currently uses `io.github.kiichiio.*` everywhere — Kotlin packages, Swift JNI symbols, Gradle group, test imports, README. Migrating it first means every subsequent task can assume the canonical `jiyimeta` namespace.

**Scope (mechanical rename, no behavioural change):**
- ~40 Kotlin `.kt` files: `package io.github.kiichiio.sheetmusic.audio…` → `io.github.jiyimeta.sheetmusic.audio…`, and matching imports inside the audio module + the example app's PlaybackCursorOverlay.kt.
- 3 Swift JNI files (`Sources/SheetMusicAndroidJNI/AudioMidiBridge*.swift`): 8 `@_cdecl` symbols of the form `Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_*` → `Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_*`.
- `Android/SheetMusicAudioAndroid/build.gradle.kts`: `namespace = "io.github.kiichiio.sheetmusic.audio"` → `"io.github.jiyimeta.sheetmusic.audio"`; `group = "io.github.kiichiio"` → `"io.github.jiyimeta"`.
- `Android/SheetMusicAudioAndroid/README.md`: all `io.github.kiichiio` mentions.
- `Examples/Android/settings.gradle.kts` + `Examples/Android/app/build.gradle.kts`: dependency substitution / coordinates.

**Files:**
- Move directory: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/` → `…/io/github/jiyimeta/`
- Move directory: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/kiichiio/` → `…/io/github/jiyimeta/`
- Modify: all `.kt` files inside those trees (package + imports)
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`, `AudioMidiBridge+Timeline.swift`, `AudioMidiBridge+Render.swift`
- Modify: `Android/SheetMusicAudioAndroid/build.gradle.kts`
- Modify: `Android/SheetMusicAudioAndroid/README.md`
- Modify: `Examples/Android/settings.gradle.kts`
- Modify: `Examples/Android/app/build.gradle.kts`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/cursor/PlaybackCursorOverlay.kt` (imports `io.github.kiichiio.sheetmusic.audio.model.ScoreCursor` etc.)

- [ ] **Step 0.1: Move Kotlin source directories**

```bash
cd Android/SheetMusicAudioAndroid/src/main/kotlin/io/github
git mv kiichiio jiyimeta
cd -

cd Android/SheetMusicAudioAndroid/src/test/kotlin/io/github
git mv kiichiio jiyimeta
cd -
```

`git mv` preserves history. After this, every `.kt` file inside still has `package io.github.kiichiio.…` declarations and possibly imports — those are rewritten in the next step.

- [ ] **Step 0.2: Rewrite `package` + `import` lines in Kotlin files**

Use a single `perl -pi` pass — the substitution is the same string everywhere (`io.github.kiichiio` → `io.github.jiyimeta`), which makes a manual edit per file unnecessarily slow.

```bash
git ls-files 'Android/SheetMusicAudioAndroid/src/**/*.kt' | while read -r f; do
    perl -pi -e 's/io\.github\.kiichiio/io.github.jiyimeta/g' "$f"
done
```

Verify zero references remain inside the audio module:

```bash
grep -rln 'io\.github\.kiichiio' Android/SheetMusicAudioAndroid/src
```

Expected: empty output.

- [ ] **Step 0.3: Rewrite Swift JNI `@_cdecl` symbols + function names**

Three files contain `Java_io_github_kiichiio_sheetmusic_audio_jni_SheetMusicAudioJNI_*` (8 symbols total). Apply the same substitution:

```bash
for f in Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift \
         Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift \
         Sources/SheetMusicAndroidJNI/AudioMidiBridge+Render.swift; do
    perl -pi -e 's/io_github_kiichiio/io_github_jiyimeta/g' "$f"
done
```

Verify:

```bash
grep -rln 'io_github_kiichiio\|io\.github\.kiichiio' Sources
```

Expected: empty output.

- [ ] **Step 0.4: Update `SheetMusicAudioAndroid/build.gradle.kts`**

In `Android/SheetMusicAudioAndroid/build.gradle.kts`, change two lines:

```kotlin
namespace = "io.github.jiyimeta.sheetmusic.audio"   // was io.github.kiichiio.sheetmusic.audio
```

```kotlin
group = "io.github.jiyimeta"                        // was io.github.kiichiio
```

- [ ] **Step 0.5: Update `SheetMusicAudioAndroid/README.md`**

```bash
perl -pi -e 's/io\.github\.kiichiio/io.github.jiyimeta/g' Android/SheetMusicAudioAndroid/README.md
```

- [ ] **Step 0.6: Update example app Gradle coordinates + imports**

```bash
perl -pi -e 's/io\.github\.kiichiio/io.github.jiyimeta/g' \
    Examples/Android/settings.gradle.kts \
    Examples/Android/app/build.gradle.kts \
    Examples/Android/app/src/main/java/com/example/sheetmusic/cursor/PlaybackCursorOverlay.kt
```

Verify nothing remains anywhere:

```bash
grep -rln 'kiichiio' Sources Android Examples Tests Scripts .github
```

Expected: empty output (this is the canonical pre-Task-1 invariant).

- [ ] **Step 0.7: Re-cross-compile the JNI .so to confirm new symbols are exported**

```bash
Scripts/android-build-libs.sh
nm -D Android/SheetMusicAndroid/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so 2>/dev/null \
  || nm -D Examples/Android/app/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so \
  | grep -E 'jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI'
```

Expected: 8 lines, each containing `T Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_…`. (At this point in the plan the staging dest is still the example app; Task 4 moves it.)

- [ ] **Step 0.8: Build + test the audio module**

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:testDebugUnitTest :SheetMusicAudioAndroid:assembleRelease && cd -
```

Expected: BUILD SUCCESSFUL, all unit tests pass.

- [ ] **Step 0.9: Commit**

```bash
git add -A
git commit -m "refactor(android-audio): migrate namespace to io.github.jiyimeta

Mechanical rename: every io.github.kiichiio reference (Kotlin
packages + imports, Swift @_cdecl JNI symbols, Gradle group +
namespace, README, example app composite-build coordinates) becomes
io.github.jiyimeta to match the GitHub username.

No behavioural change. Unit tests + assembleRelease still pass."
```

---

## Task 1: Rename Swift JNI `@_cdecl` symbols

**Why first:** Every downstream change (new Kotlin module, example migration) depends on the new symbol names. Doing this first keeps `Examples/Android` broken transiently (acceptable — we fix it in Task 7), and keeps each commit shippable in isolation.

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift` (5 `@_cdecl` annotations + 5 function names)
- Modify: `Sources/SheetMusicAndroidJNI/CursorBridge.swift` (1 `@_cdecl` annotation + 1 function name)

**Mapping (old → new):**

| Old JNI symbol | New JNI symbol |
|---|---|
| `Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeLoadScore` | `Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeLoadScore` |
| `Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeReleaseScore` | `Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeReleaseScore` |
| `Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeInstallSMuFLMetrics` | `Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeInstallSMuFLMetrics` |
| `Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeComputeLayout` | `Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeComputeLayout` |
| `Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeCursorFrame` | `Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeCursorFrame` |

(The five Audio symbols under `io.github.jiyimeta.sheetmusic.audio.jni.SheetMusicAudioJNI` already use the library-owned namespace and **stay as-is**.)

- [ ] **Step 1.1: Apply rename in `JNISymbols.swift`**

In `Sources/SheetMusicAndroidJNI/JNISymbols.swift`, replace all four occurrences of the substring `com_example_sheetmusic_jni_SheetMusicBridge` with `io_github_jiyimeta_sheetmusic_SheetMusicJNI`. This rewrites both the `@_cdecl("Java_...")` string and the matching `public func Java_...` Swift identifier (the C symbol must match the function name byte-for-byte under `@_cdecl`).

Concretely, four pairs of lines change:

```swift
@_cdecl("Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeLoadScore")
// swiftlint:disable:next identifier_name
public func Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeLoadScore(
```

and likewise for `nativeReleaseScore`, `nativeInstallSMuFLMetrics`, `nativeComputeLayout`.

- [ ] **Step 1.2: Apply rename in `CursorBridge.swift`**

Same substitution in `Sources/SheetMusicAndroidJNI/CursorBridge.swift` — one `@_cdecl` + one function identifier for `nativeCursorFrame`.

- [ ] **Step 1.3: Verify host build still compiles**

Run: `swift build`
Expected: Build succeeds (the `#if os(Android)` branches are excluded on macOS, so the rename is functionally a no-op for host compilation, but the build also catches typos in the surrounding files).

- [ ] **Step 1.4: Verify Android cross-compile still produces the .so**

Run: `Scripts/android-build-libs.sh`
Expected: Builds `libSheetMusicJNI.so` for `arm64-v8a` + `x86_64` into `Examples/Android/app/src/main/jniLibs/` (existing location — Task 4 moves it). Exit 0.

- [ ] **Step 1.5: Verify the renamed symbols are exported in the .so**

Run: `nm -D Examples/Android/app/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so | grep -E 'kiichiio_sheetmusic_SheetMusicJNI_native(LoadScore|ReleaseScore|InstallSMuFLMetrics|ComputeLayout|CursorFrame)'`
Expected: 5 lines, each containing `T Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_native…`.

Also confirm the old symbols are gone:

Run: `nm -D Examples/Android/app/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so | grep 'com_example_sheetmusic'`
Expected: empty output.

- [ ] **Step 1.6: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/JNISymbols.swift \
        Sources/SheetMusicAndroidJNI/CursorBridge.swift
git commit -m "refactor(jni): rename score/layout/cursor symbols to library namespace

Move the @_cdecl Score/Layout/Cursor bridge from the example app
namespace (com.example.sheetmusic.jni.SheetMusicBridge) to a
library-owned namespace (io.github.jiyimeta.sheetmusic.SheetMusicJNI)
so the Kotlin bridge can be packaged into a published AAR. The
Audio JNI symbols already live in the io.github.jiyimeta namespace.

Note: this commit transiently breaks Examples/Android (which still
loads the old symbols). The next commits introduce the new
SheetMusicAndroid Gradle module and migrate the example app to use
it."
```

---

## Task 2: Create `SheetMusicAndroid` Gradle module skeleton

**Why:** Establish the new module before moving code into it, so we can verify the empty AAR assembles before we start refactoring imports.

**Files:**
- Create: `Android/SheetMusicAndroid/build.gradle.kts`
- Create: `Android/SheetMusicAndroid/src/main/AndroidManifest.xml`
- Create: `Android/SheetMusicAndroid/proguard-consumer.pro` (empty placeholder)
- Modify: `Android/settings.gradle.kts` (add `include(":SheetMusicAndroid")`)

- [ ] **Step 2.1: Add the include to settings**

Append to `Android/settings.gradle.kts`:

```kotlin
include(":SheetMusicAndroid")
```

So the file ends with:

```kotlin
rootProject.name = "swift-sheet-music-android"
include(":SheetMusicAudioAndroid")
include(":SheetMusicAndroid")
```

- [ ] **Step 2.2: Create the module manifest**

Write `Android/SheetMusicAndroid/src/main/AndroidManifest.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest />
```

(An empty `<manifest>` is all an Android library AAR needs; the consumer app supplies the rest.)

- [ ] **Step 2.3: Create the empty consumer proguard file**

Write `Android/SheetMusicAndroid/proguard-consumer.pro`:

```
# JNI entrypoints loaded via System.loadLibrary; keep their classes.
-keep class io.github.jiyimeta.sheetmusic.SheetMusicJNI { *; }
```

- [ ] **Step 2.4: Create the module build script**

Write `Android/SheetMusicAndroid/build.gradle.kts`:

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.jiyimeta.sheetmusic"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    // Prebuilt libSheetMusicJNI.so + Swift runtime live here. They
    // are staged by Scripts/android-build-libs.sh before any Gradle
    // task that consumes them (assembleRelease / publish).
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

group = "io.github.jiyimeta"
version = "0.0.0-SNAPSHOT"

dependencies {
    // No third-party deps. This module is pure JNI bindings + a Kotlin
    // façade. AndroidX / Compose live in consumer apps, not here.
}
```

- [ ] **Step 2.5: Verify the empty module assembles**

Run: `cd Android && ./gradlew :SheetMusicAndroid:assembleRelease`
Expected: BUILD SUCCESSFUL. An (essentially empty) AAR appears at `Android/SheetMusicAndroid/build/outputs/aar/SheetMusicAndroid-release.aar`.

- [ ] **Step 2.6: Commit**

```bash
git add Android/SheetMusicAndroid Android/settings.gradle.kts
git commit -m "feat(android): scaffold SheetMusicAndroid Gradle module

New Android library module that will own the JNI bridge (Kotlin)
and bundle the prebuilt libSheetMusicJNI.so / Swift runtime into a
publishable AAR. Sources land in subsequent commits."
```

---

## Task 3: Move JNI Kotlin bridge into `SheetMusicAndroid`

**Files:**
- Create: `Android/SheetMusicAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/SheetMusicJNI.kt`
- Create: `Android/SheetMusicAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/ScoreHandle.kt`
- Create: `Android/SheetMusicAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/BravuraMetricsBuilder.kt`

Three Kotlin files move from `Examples/Android/app/src/main/java/com/example/sheetmusic/jni/` into the new module's source tree, with:

- Package: `com.example.sheetmusic.jni` → `io.github.jiyimeta.sheetmusic`.
- Class rename: `SheetMusicBridge` → `SheetMusicJNI` (matches the renamed JNI symbols).
- `SheetMusicJNI` keeps `System.loadLibrary("SheetMusicJNI")` — this is the canonical loader for the JNI .so now.

The example-app copies under `Examples/Android/app/src/main/java/com/example/sheetmusic/jni/` are **deleted in Task 7**, after the example is migrated to import from the new module.

- [ ] **Step 3.1: Write `SheetMusicJNI.kt`**

Create `Android/SheetMusicAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/SheetMusicJNI.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic

/**
 * Thin façade over the @_cdecl symbols exported by
 * Sources/SheetMusicAndroidJNI/JNISymbols.swift +
 * Sources/SheetMusicAndroidJNI/CursorBridge.swift.
 *
 * Symbol names map to the JNI convention:
 *   io.github.jiyimeta.sheetmusic.SheetMusicJNI.<name>
 *       → Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_<name>
 *
 * The companion's init also loads libSheetMusicJNI; consumers that
 * link this module transitively (e.g. SheetMusicAudioAndroid) inherit
 * the loaded native library.
 */
object SheetMusicJNI {

    init { System.loadLibrary("SheetMusicJNI") }

    /** Returns 0 on parse failure. */
    @JvmStatic external fun nativeLoadScore(bytes: ByteArray): Long

    @JvmStatic external fun nativeReleaseScore(handle: Long)

    /** Returns an empty array on failure (e.g. invalid handle). */
    @JvmStatic external fun nativeComputeLayout(
        scoreHandle: Long,
        pageWidthMM: Double,
        pageHeightMM: Double,
    ): ByteArray

    /**
     * Install a SMuFL glyph-metrics table on the Swift side. Returns
     * `true` on success, `false` if the byte format is invalid. Wire
     * format spec is on `Sources/SheetMusicAndroidJNI/SMuFLMetricsTable.swift`.
     */
    @JvmStatic external fun nativeInstallSMuFLMetrics(bytes: ByteArray): Boolean

    /**
     * Resolve the bounding rectangle (document/mm coordinates) of the cursor
     * identified by [cursorBytes] within the laid-out score [scoreHandle].
     *
     * Returns a 34-byte payload in the CursorFrame wire format on success, or
     * an empty array if the cursor did not resolve (e.g. stale ID after
     * re-layout). Wire format: u16 version (=1), then 4 × i64 micros
     * (x, y, width, height), little-endian.
     */
    @JvmStatic external fun nativeCursorFrame(
        scoreHandle: Long,
        cursorBytes: ByteArray,
    ): ByteArray
}
```

- [ ] **Step 3.2: Write `ScoreHandle.kt`**

Create `Android/SheetMusicAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/ScoreHandle.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic

/** Auto-releasing wrapper around a native score handle. */
class ScoreHandle internal constructor(val raw: Long) : AutoCloseable {
    private var closed = false

    override fun close() {
        if (!closed) {
            SheetMusicJNI.nativeReleaseScore(raw)
            closed = true
        }
    }

    protected fun finalize() { close() }

    companion object {
        /** Returns null if Swift parsing failed. */
        fun load(bytes: ByteArray): ScoreHandle? {
            val raw = SheetMusicJNI.nativeLoadScore(bytes)
            return if (raw == 0L) null else ScoreHandle(raw)
        }
    }
}
```

- [ ] **Step 3.3: Move `BravuraMetricsBuilder.kt`**

Copy the body of `Examples/Android/app/src/main/java/com/example/sheetmusic/jni/BravuraMetricsBuilder.kt` into `Android/SheetMusicAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/BravuraMetricsBuilder.kt`, changing only the `package` line:

```kotlin
package io.github.jiyimeta.sheetmusic
```

(All other content — imports, doc comments, `object BravuraMetricsBuilder { … }` body — is identical. Read the source file and reproduce it verbatim under the new package, since the contents are too long to duplicate inline in this plan and they change rarely.)

- [ ] **Step 3.4: Verify the module compiles**

Run: `cd Android && ./gradlew :SheetMusicAndroid:assembleRelease`
Expected: BUILD SUCCESSFUL. The AAR now contains the Kotlin classes (no `.so` files yet — Task 4 wires those).

You can confirm with:

Run: `unzip -l Android/SheetMusicAndroid/build/outputs/aar/SheetMusicAndroid-release.aar | grep -E 'classes\.jar|SheetMusicJNI|ScoreHandle|BravuraMetricsBuilder'`
Expected: shows `classes.jar` present; the .class files are inside that jar (not directly visible from the AAR top-level listing).

- [ ] **Step 3.5: Commit**

```bash
git add Android/SheetMusicAndroid/src
git commit -m "feat(android): port JNI Kotlin bridge into SheetMusicAndroid

SheetMusicJNI (renamed from SheetMusicBridge), ScoreHandle, and
BravuraMetricsBuilder now live in the io.github.jiyimeta.sheetmusic
package inside the new library module. The example app's copies
under com.example.sheetmusic.jni become unreferenced; they are
removed in a later commit once consumer call-sites migrate."
```

---

## Task 4: Stage `libSheetMusicJNI.so` + Swift runtime into the new module

**Why:** The AAR built in Task 3 has no native libs yet. To make the published AAR self-contained, the cross-compiled `.so` files must land in `Android/SheetMusicAndroid/src/main/jniLibs/<abi>/` before `assembleRelease` runs.

**Files:**
- Modify: `Scripts/android-build-libs.sh` (change destination from `Examples/Android/.../jniLibs` to `Android/SheetMusicAndroid/src/main/jniLibs`)
- Modify: `.gitignore` (ignore the staged native libs so they don't get committed)
- Delete: `Examples/Android/app/src/main/jniLibs/` (entire dir; example app now gets natives transitively via the composite-build dependency)
- Modify: `Examples/Android/app/build.gradle.kts` (remove the now-redundant `sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")` line)

- [ ] **Step 4.1: Rewrite the staging destination in `android-build-libs.sh`**

In `Scripts/android-build-libs.sh`, change line 11:

```bash
JNI_DIR="$ROOT/Examples/Android/app/src/main/jniLibs"
```

to:

```bash
JNI_DIR="$ROOT/Android/SheetMusicAndroid/src/main/jniLibs"
```

Also update the final echo at lines 100-103:

```bash
echo
echo "Done. libSheetMusicJNI.so + runtime staged under:"
echo "  $JNI_DIR/{arm64-v8a,x86_64}/"
echo
echo "Next: place ~/Desktop/test.mscz and run"
echo "      Scripts/android-bundle-test-score.sh"
```

stays as-is — the file paths in the message update automatically because `$JNI_DIR` is interpolated.

- [ ] **Step 4.2: Add the staged libs to `.gitignore`**

Append to `.gitignore` (read it first to confirm format; add a new section if there isn't already an Android one):

```
# Cross-compiled native libs staged by Scripts/android-build-libs.sh.
# Generated artifacts, not checked in.
Android/SheetMusicAndroid/src/main/jniLibs/
```

If the file already contains `Examples/Android/app/src/main/jniLibs/`, remove that line — the path no longer exists.

- [ ] **Step 4.3: Drop the example app's old `jniLibs.srcDirs` line**

In `Examples/Android/app/build.gradle.kts`, delete line 38:

```kotlin
sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
```

After this edit, the `android { … }` block ends at the `buildTypes` block. The example app will now receive the JNI .so files through its transitive `implementation("io.github.jiyimeta:sheet-music-android:…")` dependency (added in Task 7).

- [ ] **Step 4.4: Remove the stale example jniLibs directory**

Run: `rm -rf Examples/Android/app/src/main/jniLibs`
Expected: silent. (The dir may already be absent on a fresh checkout — that's fine.)

- [ ] **Step 4.5: Stage the natives via the script**

Run: `Scripts/android-build-libs.sh`
Expected:
- Builds `libSheetMusicJNI.so` for `arm64-v8a` + `x86_64`.
- Final output says they landed under `Android/SheetMusicAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/`.

Verify:

Run: `ls Android/SheetMusicAndroid/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so Android/SheetMusicAndroid/src/main/jniLibs/x86_64/libSheetMusicJNI.so`
Expected: both files exist.

- [ ] **Step 4.6: Verify the AAR now bundles the natives**

Run: `cd Android && ./gradlew :SheetMusicAndroid:assembleRelease`
Expected: BUILD SUCCESSFUL.

Run: `unzip -l Android/SheetMusicAndroid/build/outputs/aar/SheetMusicAndroid-release.aar | grep '\.so$'`
Expected: lines containing `jni/arm64-v8a/libSheetMusicJNI.so`, `jni/x86_64/libSheetMusicJNI.so`, and the Swift runtime `.so` files (`libswiftCore.so`, `lib_FoundationICU.so`, `libc++_shared.so`, etc.) — two ABIs × ~20 files = ~40 lines.

- [ ] **Step 4.7: Commit**

```bash
git add Scripts/android-build-libs.sh .gitignore Examples/Android/app/build.gradle.kts
git commit -m "build(android): stage JNI natives into SheetMusicAndroid AAR

Move the staging destination from Examples/Android/app/.../jniLibs
to Android/SheetMusicAndroid/src/main/jniLibs/ so the prebuilt
libSheetMusicJNI.so and Swift runtime ship inside the SheetMusicAndroid
AAR. The example app receives them transitively through its
implementation dependency."
```

---

## Task 5: Make `SheetMusicAudioAndroid` depend on `SheetMusicAndroid`

**Why:** The audio module currently does its own `System.loadLibrary("SheetMusicJNI")` and assumes the consumer has staged the .so. After this task, depending on `:SheetMusicAudioAndroid` automatically pulls in `:SheetMusicAndroid` with the bundled natives.

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/build.gradle.kts` (add api project dep)
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/jni/SheetMusicAudioJNI.kt` (remove redundant loadLibrary)

- [ ] **Step 5.1: Add the dependency**

In `Android/SheetMusicAudioAndroid/build.gradle.kts`, insert at the top of the `dependencies { … }` block (right after the opening brace, before the FluidSynth line):

```kotlin
dependencies {
    api(project(":SheetMusicAndroid"))

    // FluidSynth (LGPL-2.1 dynamic-link). Vetted in Task 1; see
    …
```

Use `api`, not `implementation`, so consumers of `SheetMusicAudioAndroid` can directly call `SheetMusicJNI.nativeLoadScore(…)` if they also need the Score/Layout/Cursor APIs.

- [ ] **Step 5.2: Drop the redundant `loadLibrary` in `SheetMusicAudioJNI`**

In `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/kiichiio/sheetmusic/audio/jni/SheetMusicAudioJNI.kt`, replace the `init { … }` block:

```kotlin
internal object SheetMusicAudioJNI {
    init {
        // Force-load io.github.jiyimeta.sheetmusic.SheetMusicJNI so its
        // static initialiser runs System.loadLibrary("SheetMusicJNI")
        // before any of our external fun calls bind. Direct reference
        // to a member (not just the class) guarantees class init.
        @Suppress("UNUSED_EXPRESSION")
        io.github.jiyimeta.sheetmusic.SheetMusicJNI.toString()
    }

    external fun nativeRenderMidi(scoreHandle: Long): ByteArray
    external fun nativeTimelineSummary(scoreHandle: Long): LongArray
    external fun nativeFrameAtTick(scoreHandle: Long, tick: Long): ByteArray
    external fun nativeFrameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray
    external fun nativeMetronomeBeats(scoreHandle: Long): ByteArray
    external fun nativeStaffParams(scoreHandle: Long): ByteArray
    external fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long
    external fun nativeEarliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray
}
```

(Both modules calling `System.loadLibrary("SheetMusicJNI")` is technically harmless — the JVM dedupes — but having one canonical loader makes the dependency direction explicit.)

- [ ] **Step 5.3: Build the audio module**

Run: `cd Android && ./gradlew :SheetMusicAudioAndroid:assembleRelease`
Expected: BUILD SUCCESSFUL. The audio AAR now resolves its project dependency on `:SheetMusicAndroid`.

- [ ] **Step 5.4: Run the audio module's unit tests**

Run: `cd Android && ./gradlew :SheetMusicAudioAndroid:testDebugUnitTest`
Expected: All tests pass. (The unit tests use fakes for the JNI surface, so they don't exercise the loaded `.so`. They do, however, link against the `SheetMusicJNI` class for compilation reachability checks — passing this confirms the new package path is wired correctly.)

- [ ] **Step 5.5: Commit**

```bash
git add Android/SheetMusicAudioAndroid
git commit -m "feat(android-audio): depend on SheetMusicAndroid for the JNI native

api(project(\":SheetMusicAndroid\")) gives consumers of the audio
module transitive access to the bundled libSheetMusicJNI.so and to
the SheetMusicJNI Kotlin façade. SheetMusicAudioJNI no longer
calls System.loadLibrary itself; class-init coupling forces the
core module's loader to run first."
```

---

## Task 6: Configure `maven-publish` on both modules

**Why:** Wire each module's release variant to a Maven publication targeting GitHub Packages. Credentials read from env vars so the same script works locally (with a developer's PAT) and in CI (with `GITHUB_TOKEN`).

**Files:**
- Modify: `Android/SheetMusicAndroid/build.gradle.kts`
- Modify: `Android/SheetMusicAudioAndroid/build.gradle.kts`

- [ ] **Step 6.1: Apply `maven-publish` plugin + publication in `SheetMusicAndroid/build.gradle.kts`**

At the top of `Android/SheetMusicAndroid/build.gradle.kts`, add the plugin:

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}
```

Then at the bottom of the file (after the existing `dependencies { … }` block), append:

```kotlin
afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                groupId = "io.github.jiyimeta"
                artifactId = "sheet-music-android"
                // Version comes from the top-level `version = …` declaration.
                pom {
                    name.set("SheetMusic Android")
                    description.set(
                        "Kotlin/JNI bindings for swift-sheet-music: " +
                            "score parsing, engraving layout, cursor resolution."
                    )
                    url.set("https://github.com/jiyimeta/swift-sheet-music")
                    licenses {
                        license {
                            name.set("MIT")
                            url.set("https://opensource.org/licenses/MIT")
                        }
                    }
                }
            }
        }
        repositories {
            maven {
                name = "GithubPackages"
                url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
                credentials {
                    username = System.getenv("GITHUB_ACTOR")
                        ?: project.findProperty("gpr.user") as String?
                    password = System.getenv("GITHUB_TOKEN")
                        ?: project.findProperty("gpr.token") as String?
                }
            }
        }
    }
}
```

(`afterEvaluate` is required because AGP creates the `release` software component lazily.)

- [ ] **Step 6.2: Apply the same to `SheetMusicAudioAndroid/build.gradle.kts`**

Add `` `maven-publish` `` to the plugins block:

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}
```

Append to the end of the file:

```kotlin
afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                groupId = "io.github.jiyimeta"
                artifactId = "sheet-music-audio-android"
                pom {
                    name.set("SheetMusic Audio Android")
                    description.set(
                        "FluidSynth-backed audio playback for swift-sheet-music on Android."
                    )
                    url.set("https://github.com/jiyimeta/swift-sheet-music")
                    licenses {
                        license {
                            name.set("MIT")
                            url.set("https://opensource.org/licenses/MIT")
                        }
                    }
                }
            }
        }
        repositories {
            maven {
                name = "GithubPackages"
                url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
                credentials {
                    username = System.getenv("GITHUB_ACTOR")
                        ?: project.findProperty("gpr.user") as String?
                    password = System.getenv("GITHUB_TOKEN")
                        ?: project.findProperty("gpr.token") as String?
                }
            }
        }
    }
}
```

- [ ] **Step 6.3: Smoke-test `publishToMavenLocal` for both modules**

Run: `cd Android && ./gradlew :SheetMusicAndroid:publishReleasePublicationToMavenLocal :SheetMusicAudioAndroid:publishReleasePublicationToMavenLocal`
Expected: BUILD SUCCESSFUL. Both artifacts land under `~/.m2/repository/io/github/kiichiio/sheet-music-{android,audio-android}/0.0.0-SNAPSHOT/`.

Verify:

Run: `find ~/.m2/repository/io/github/kiichiio -name '*.aar' -o -name '*.pom' | sort`
Expected: 2 `.aar` + 2 `.pom` files (one of each per module).

This proves the publication is wired correctly *before* we expose it to GitHub Packages.

- [ ] **Step 6.4: Commit**

```bash
git add Android/SheetMusicAndroid/build.gradle.kts \
        Android/SheetMusicAudioAndroid/build.gradle.kts
git commit -m "build(android): wire maven-publish for GitHub Packages

Both Android library modules now expose a release MavenPublication
targeting https://maven.pkg.github.com/jiyimeta/swift-sheet-music.
Credentials come from GITHUB_ACTOR / GITHUB_TOKEN (CI) or
gpr.user / gpr.token gradle properties (local dev)."
```

---

## Task 7: Migrate `Examples/Android` to the published bridge

**Why:** With the new module in place, the example app should consume the published `SheetMusicJNI` instead of vendoring its own copy. This is also the regression-test bed for "does the published artifact actually work in a real Compose app."

**Files:**
- Modify: `Examples/Android/settings.gradle.kts` (add dependency substitution for `sheet-music-android`)
- Modify: `Examples/Android/app/build.gradle.kts` (add `implementation` line)
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreViewModel.kt`
- Modify: `Examples/Android/app/src/main/java/com/example/sheetmusic/cursor/PlaybackCursorOverlay.kt`
- Delete: `Examples/Android/app/src/main/java/com/example/sheetmusic/jni/` (entire directory)

- [ ] **Step 7.1: Add dependency substitution in example `settings.gradle.kts`**

In `Examples/Android/settings.gradle.kts`, expand the `dependencySubstitution` block:

```kotlin
includeBuild("../../Android") {
    dependencySubstitution {
        substitute(module("io.github.jiyimeta:sheet-music-audio-android"))
            .using(project(":SheetMusicAudioAndroid"))
        substitute(module("io.github.jiyimeta:sheet-music-android"))
            .using(project(":SheetMusicAndroid"))
    }
}
```

- [ ] **Step 7.2: Add the new implementation dependency**

In `Examples/Android/app/build.gradle.kts`, alongside the existing audio dep, add:

```kotlin
    implementation("io.github.jiyimeta:sheet-music-android:0.0.0-SNAPSHOT")
    // Audio backend — resolved from the Android/ composite build.
    // Version must match Android/SheetMusicAudioAndroid/build.gradle.kts.
    implementation("io.github.jiyimeta:sheet-music-audio-android:0.0.0-SNAPSHOT")
```

(`sheet-music-audio-android` already pulls `sheet-music-android` transitively, but stating it explicitly makes the relationship visible to anyone reading the example.)

- [ ] **Step 7.3: Rewrite imports in `ScoreViewModel.kt`**

In `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreViewModel.kt`, swap the three `com.example.sheetmusic.jni.*` imports for their new-module equivalents:

```kotlin
import com.example.sheetmusic.draw.DrawProgramDecoder
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
```

Then update the in-method reference (around line 48) from `SheetMusicBridge.nativeInstallSMuFLMetrics(table)` to `SheetMusicJNI.nativeInstallSMuFLMetrics(table)`. Read the file and grep for `SheetMusicBridge` to catch any others.

- [ ] **Step 7.4: Rewrite the import in `PlaybackCursorOverlay.kt`**

In `Examples/Android/app/src/main/java/com/example/sheetmusic/cursor/PlaybackCursorOverlay.kt`, replace:

```kotlin
import com.example.sheetmusic.jni.SheetMusicBridge
```

with:

```kotlin
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
```

…and update the in-body call (around line 60) from `SheetMusicBridge.nativeCursorFrame(…)` to `SheetMusicJNI.nativeCursorFrame(…)`.

- [ ] **Step 7.5: Sanity-check for leftover references**

Run: `grep -rn 'com\.example\.sheetmusic\.jni\|SheetMusicBridge' Examples/Android/app/src`
Expected: empty output. Anything that remains must be migrated before continuing.

- [ ] **Step 7.6: Delete the obsolete example-app JNI package**

Run: `rm -rf Examples/Android/app/src/main/java/com/example/sheetmusic/jni`
Expected: silent.

- [ ] **Step 7.7: Assemble the example app**

Run: `cd Examples/Android && ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

Verify the bundled APK contains the `.so` files from the dependency:

Run: `unzip -l Examples/Android/app/build/outputs/apk/debug/app-debug.apk | grep -E 'libSheetMusicJNI\.so|libswiftCore\.so'`
Expected: two `libSheetMusicJNI.so` entries (arm64-v8a + x86_64) and the Swift runtime libs alongside them.

- [ ] **Step 7.8: Commit**

```bash
git add Examples/Android
git commit -m "refactor(example): consume SheetMusicAndroid via composite build

The example app no longer vendors its own JNI bridge under
com.example.sheetmusic.jni; it imports io.github.jiyimeta.sheetmusic
from the published SheetMusicAndroid module (resolved through the
existing composite build during local development)."
```

---

## Task 8: Add `.github/workflows/android-publish.yml`

**Why:** Make tagged releases actually reach GitHub Packages without manual intervention.

**Files:**
- Create: `.github/workflows/android-publish.yml`

- [ ] **Step 8.1: Write the workflow**

Create `.github/workflows/android-publish.yml`:

```yaml
name: Publish Android modules to GitHub Packages

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Override version (defaults to the tag without leading v)'
        required: false

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: macos-14
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - name: Resolve version
        id: ver
        run: |
          if [[ -n "${{ inputs.version }}" ]]; then
            echo "version=${{ inputs.version }}" >> "$GITHUB_OUTPUT"
          else
            echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          fi

      - name: Install Swift 6.3.2 toolchain
        run: |
          curl -fLO https://download.swift.org/swift-6.3.2-release/xcode/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE-osx.pkg
          sudo installer -pkg swift-6.3.2-RELEASE-osx.pkg -target /
          xcode-select -p

      - name: Install Swift Android SDK
        run: |
          export TOOLCHAINS=org.swift.632202605101a
          # Re-derive checksum from https://www.swift.org/install/ if upstream rotates the artifact.
          swift sdk install \
              https://download.swift.org/swift-6.3.2-release/swift-6.3.2-RELEASE_android-0.1.artifactbundle.tar.gz \
              --checksum 7833d18d0e1c45ed8d4c2eb73def7a8c0afe6b8a3bea4e7d4f1d4f2b3a9e9c0d
          # Run the SDK's NDK sysroot setup (one-time)
          NDK_DIR="$ANDROID_HOME/ndk/26.1.10909125"
          ANDROID_NDK_HOME="$NDK_DIR" \
              ~/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh

      - name: Cross-compile JNI natives
        env:
          TOOLCHAINS: org.swift.632202605101a
        run: Scripts/android-build-libs.sh

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17

      - uses: gradle/actions/setup-gradle@v3

      - name: Publish to GitHub Packages
        working-directory: Android
        env:
          GITHUB_ACTOR: ${{ github.actor }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ORG_GRADLE_PROJECT_version: ${{ steps.ver.outputs.version }}
        run: |
          ./gradlew \
              -Pversion="${ORG_GRADLE_PROJECT_version}" \
              :SheetMusicAndroid:publishReleasePublicationToGithubPackagesRepository \
              :SheetMusicAudioAndroid:publishReleasePublicationToGithubPackagesRepository
```

> **Checksum note (Task 1.4 already exercises this locally):** The `--checksum` value above is a placeholder. Before merging, re-derive it from <https://www.swift.org/install/> → Swift 6.3 → Android release notes and paste the real SHA-256 here.

- [ ] **Step 8.2: Verify the workflow file parses**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/android-publish.yml'))"`
Expected: no output. (Any YAML syntax error would print a traceback.)

- [ ] **Step 8.3: Confirm the version-override path works in Gradle**

Both module build scripts hardcode `version = "0.0.0-SNAPSHOT"`. To let the workflow override via `-Pversion=…`, change that line in each module's `build.gradle.kts` to:

```kotlin
version = (project.findProperty("version") as String?)
    ?.takeIf { it != "unspecified" }
    ?: "0.0.0-SNAPSHOT"
```

(Gradle defaults the root `version` property to `"unspecified"` when nothing is set; the `takeIf` filter falls back to the SNAPSHOT default for local builds.)

Then verify:

Run: `cd Android && ./gradlew -Pversion=0.1.0-test :SheetMusicAndroid:publishReleasePublicationToMavenLocal && find ~/.m2/repository/io/github/kiichiio/sheet-music-android -name '*.pom' -newer Android/SheetMusicAndroid/build.gradle.kts`
Expected: a `.pom` under `…/0.1.0-test/` exists with `<version>0.1.0-test</version>`.

- [ ] **Step 8.4: Commit**

```bash
git add .github/workflows/android-publish.yml \
        Android/SheetMusicAndroid/build.gradle.kts \
        Android/SheetMusicAudioAndroid/build.gradle.kts
git commit -m "ci(android): publish to GitHub Packages on v* tag

A new workflow installs the Swift 6.3.2 toolchain + Android SDK on a
macOS runner, cross-compiles libSheetMusicJNI.so, and pushes both
Android library modules to maven.pkg.github.com. The release version
is derived from the tag (v0.1.0 -> 0.1.0); the module build scripts
honour -Pversion= so the same workflow works for snapshot pushes."
```

---

## Task 9: Update READMEs and `CLAUDE.md`

**Files:**
- Create: `Android/SheetMusicAndroid/README.md`
- Modify: `Android/SheetMusicAudioAndroid/README.md` (update package name, dependency setup)
- Modify: `CLAUDE.md` (update the "Android build" section to reference the new module and consumer flow)

- [ ] **Step 9.1: Write `Android/SheetMusicAndroid/README.md`**

Create `Android/SheetMusicAndroid/README.md`:

```markdown
# SheetMusicAndroid

Kotlin/JNI bindings for [swift-sheet-music](https://github.com/jiyimeta/swift-sheet-music)
covering score parsing, engraving layout, and cursor resolution.

This module ships the prebuilt `libSheetMusicJNI.so` for the supported
ABIs (`arm64-v8a`, `x86_64`) inside the AAR, so consumers do not need
a Swift toolchain.

## Consuming from a Kotlin / Compose app

Add the GitHub Packages Maven repository (see "Authentication" below for
the credentials block) and the dependency:

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            name = "SheetMusicGithubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                    ?: System.getenv("GITHUB_ACTOR")
                password = providers.gradleProperty("gpr.token").orNull
                    ?: System.getenv("GITHUB_TOKEN")
            }
        }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("io.github.jiyimeta:sheet-music-android:<version>")
}
```

## Authentication

GitHub Packages requires authentication even for downloads from public
packages, so every consumer needs a Personal Access Token (PAT) with
the `read:packages` scope.

Set the credentials via either:

- `~/.gradle/gradle.properties` (developer-local):
  ```
  gpr.user=<your-github-username>
  gpr.token=<your-pat-with-read-packages>
  ```
- Environment variables (CI):
  ```
  GITHUB_ACTOR=<github-username>
  GITHUB_TOKEN=<pat>
  ```

## Usage

```kotlin
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder

val table = BravuraMetricsBuilder.buildTable(context.assets)
SheetMusicJNI.nativeInstallSMuFLMetrics(table)

val bytes = context.assets.open("score.mscz").use { it.readBytes() }
val handle = ScoreHandle.load(bytes)
    ?: error("Failed to parse score")

val layout = SheetMusicJNI.nativeComputeLayout(
    scoreHandle = handle.raw,
    pageWidthMM = 210.0,
    pageHeightMM = 297.0,
)
// Decode `layout` with the DrawProgram wire format and render to Canvas.
```

See `Examples/Android/` in this repository for a complete Jetpack
Compose integration.

## ABI matrix

| ABI         | Status |
|-------------|--------|
| arm64-v8a   | Supported (primary) |
| x86_64      | Supported (emulator) |
| armv7       | Not supported |

Minimum SDK: 28 (Android 9).

## License

MIT. Includes a prebuilt `libSheetMusicJNI.so` produced from the
MIT-licensed Swift sources in this repository.
```

- [ ] **Step 9.2: Update `Android/SheetMusicAudioAndroid/README.md`**

Open `Android/SheetMusicAudioAndroid/README.md`, find the `## Usage` section (line 33–63), and replace its body so it imports from the new package and consumes the published artifact:

Replace:

```kotlin
dependencies {
    implementation("io.github.jiyimeta:sheet-music-audio-android:0.0.0-SNAPSHOT")
}
```

with:

```kotlin
dependencies {
    implementation("io.github.jiyimeta:sheet-music-audio-android:<version>")
    // sheet-music-android is pulled in transitively.
}
```

In the "Architecture (1-line summary)" section (around line 75–83), the description of `SheetMusicAudioJNI` still says it loads `libSheetMusicJNI.so`. Replace that paragraph with:

```markdown
## Architecture (1-line summary)

`io.github.jiyimeta.sheetmusic.SheetMusicJNI` (in the `sheet-music-android`
module) is the canonical loader of `libSheetMusicJNI.so` (Swift bridge).
This module ships `libsheetmusicaudio.so` — a C JNI shim over FluidSynth
via `libfluidsynth.so` — and triggers `SheetMusicJNI`'s class init early
so its `external fun` declarations resolve. MIDI rendering + timeline
lookups happen Swift-side; synthesis + Oboe output happen Kotlin-side.
```

- [ ] **Step 9.3: Update `CLAUDE.md`**

In `CLAUDE.md`, find the "Android build (Phase 1–3)" section. Update the wording about how the example app receives natives, and add a new "Distribution" sub-section before "Format support on Android":

Find:

```markdown
    # 1. Build native libs into Examples/Android/app/src/main/jniLibs/
    Scripts/android-build-libs.sh
```

Change to:

```markdown
    # 1. Build native libs into Android/SheetMusicAndroid/src/main/jniLibs/
    Scripts/android-build-libs.sh
```

Insert (before "### Format support on Android"):

```markdown
### Distribution

The Android libraries are published to GitHub Packages on `v*` tag
push via `.github/workflows/android-publish.yml`. Two artifacts:

- `io.github.jiyimeta:sheet-music-android:<v>` — JNI bridge + bundled
  `libSheetMusicJNI.so` (the new home for what used to be the
  example-app's `com.example.sheetmusic.jni` package).
- `io.github.jiyimeta:sheet-music-audio-android:<v>` — FluidSynth +
  Oboe audio playback. Has `api` dep on `sheet-music-android`.

Consumers need a GitHub PAT with `read:packages`. See
`Android/SheetMusicAndroid/README.md` for the consumer-side
`settings.gradle.kts` recipe.

To cut a release locally without CI:

    Scripts/android-build-libs.sh
    GITHUB_ACTOR=<user> GITHUB_TOKEN=<pat> ./Android/gradlew \
        -Pversion=0.1.0 \
        -p Android \
        :SheetMusicAndroid:publishReleasePublicationToGithubPackagesRepository \
        :SheetMusicAudioAndroid:publishReleasePublicationToGithubPackagesRepository
```

- [ ] **Step 9.4: Commit**

```bash
git add Android/SheetMusicAndroid/README.md \
        Android/SheetMusicAudioAndroid/README.md \
        CLAUDE.md
git commit -m "docs(android): document GitHub Packages distribution

Add SheetMusicAndroid/README with consumer setup, refresh
SheetMusicAudioAndroid/README to reference the new bridge package,
and expand CLAUDE.md with the distribution workflow."
```

---

## Task 10: Final verification

**Why:** Confirm nothing regressed across the Swift, Apple-host, Android, and example app builds before treating the work as done.

- [ ] **Step 10.1: Run the host Swift test suite**

Run: `swift test`
Expected: 100% green, including `Tests/SheetMusicTests/AndroidJNI/*` (these exercise pure-Swift helpers; they don't depend on the renamed JNI symbols).

- [ ] **Step 10.2: Verify SwiftLint stays clean**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings / 0 errors.

- [ ] **Step 10.3: Re-cross-compile Android libs to a fresh staging dir**

Run: `rm -rf Android/SheetMusicAndroid/src/main/jniLibs && Scripts/android-build-libs.sh`
Expected: rebuilds both ABIs into `Android/SheetMusicAndroid/src/main/jniLibs/`.

- [ ] **Step 10.4: Assemble both AARs**

Run: `cd Android && ./gradlew :SheetMusicAndroid:assembleRelease :SheetMusicAudioAndroid:assembleRelease`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 10.5: Assemble the example app**

Run: `cd Examples/Android && ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 10.6: Smoke-test on a connected emulator**

(Requires an API 28+ emulator booted via `adb devices`.)

Run: `cd Examples/Android && ./gradlew :app:installDebug && adb shell am start -n com.example.sheetmusic/com.example.sheetmusic.MainActivity`
Expected: app launches, parses the bundled `test.mscz`, and renders the first page (visual check — same behaviour as before this refactor).

If audio is wired (`gm.sf2` staged), play a few seconds and confirm cursor moves and audio is audible.

- [ ] **Step 10.7: Smoke-test the publish path against `mavenLocal`**

Run: `cd Android && ./gradlew -Pversion=0.1.0-dryrun :SheetMusicAndroid:publishReleasePublicationToMavenLocal :SheetMusicAudioAndroid:publishReleasePublicationToMavenLocal`
Expected: BUILD SUCCESSFUL. Two AARs + two POMs land under `~/.m2/repository/io/github/kiichiio/sheet-music-{android,audio-android}/0.1.0-dryrun/`.

Verify a POM:

Run: `cat ~/.m2/repository/io/github/kiichiio/sheet-music-audio-android/0.1.0-dryrun/*.pom`
Expected: contains `<groupId>io.github.jiyimeta</groupId>`, `<artifactId>sheet-music-audio-android</artifactId>`, `<version>0.1.0-dryrun</version>`, and a `<dependency>` on `sheet-music-android`.

- [ ] **Step 10.8: Verification commit (no code changes)**

If any drift surfaced in 10.1–10.7, return to the relevant task. Otherwise no further commit is needed — the prior tasks each closed with a commit, and the branch is ready for PR.

---

## Self-Review (run by the planner, recorded inline)

**Spec coverage:**
- ✅ GitHub Packages publishing — Tasks 6 + 8.
- ✅ Two-module split (`SheetMusicAndroid` + `SheetMusicAudioAndroid`) — Tasks 2 + 5.
- ✅ JNI namespace rename to library-owned — Task 1.
- ✅ Tag-triggered publish — Task 8 (`on: push: tags: ['v*']`).
- ✅ Example app migrates to the new bridge — Task 7.
- ✅ Docs updated — Task 9.

**Placeholder scan:**
- The Swift Android SDK `--checksum` in Task 8.1 is explicitly called out as a placeholder with derivation instructions, not a silent TBD.
- Step 3.3 references the existing `BravuraMetricsBuilder.kt` body rather than duplicating ~100 lines; the implementer must read the source file directly. This is acceptable per the "complete code … if a step changes code" rule because the change is a single-line `package` rewrite of an otherwise-verbatim copy.

**Type consistency:**
- Class rename `SheetMusicBridge` → `SheetMusicJNI` is applied consistently in Tasks 1 (JNI symbol), 3 (Kotlin class), 5 (audio module init), 7 (example app callers), and 9 (README usage).
- Module names `sheet-music-android` / `sheet-music-audio-android` (artifactIds) and `:SheetMusicAndroid` / `:SheetMusicAudioAndroid` (Gradle paths) are used consistently.
- `groupId` `io.github.jiyimeta` matches the existing audio module's group.
