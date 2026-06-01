# Custom Metronome Click — Phase 3 (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a host-supplied click on Android — both in `AndroidPlaybackEngine` live playback (parity with Apple) **and** in offline export (which currently plays no metronome at all). Reuse the Phase 1 Core (`WavPcmReader` + `ClickSoundFontBuilder`) through a new JNI entry point; expose a Kotlin `MetronomeClickProvider` seam mirroring Apple's.

**Architecture:** A Swift JNI entry `nativeBuildClickSoundFont(strongWav:weakWav:) -> Data` (in `SheetMusicAndroidJNI`) turns two click WAVs into SF2 bytes via the existing Core. Kotlin gets a `MetronomeClickSource`/`MetronomeClickProvider` seam and an `AndroidMetronomeClickResolver` that returns a Uri-free `Resolution` (generated SF2 bytes / existing Uri / GM fallback) — JVM-testable. `AndroidPlaybackEngine` resolves once and loads the click SF2 into the live `MetronomeMixer`'s synth; for export, the resolution is captured in `ExportEngineSnapshot` and `AudioExporter` grows a metronome synth + `MetronomeMixer` mixed into the render loop (fixing the pre-existing "no metronome in Android export" gap). No provider ⇒ legacy GM behavior. FluidSynth auto-selects the SF2's bank-128 percussion preset on channel 9, where the metronome already plays notes 76/77.

**Tech Stack:** Swift (Foundation-only Core + swift-java JNI), Kotlin, FluidSynth, Gradle (JUnit JVM unit tests).

**Spec:** `docs/superpowers/specs/2026-06-01-custom-metronome-click-design.md` (section "5. Android integration").
**Depends on:** Phase 1 (merged to main): `WavPcmReader.read(_ Data:)`, `ClickSoundFontBuilder.build(...)` in `SheetMusicAudioCore`. Phase 2 is Apple-only and not required here.

**Working directory:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click-android` (branch `worktree-custom-metronome-click-android`). Run all commands from there. Do NOT `cd` to the main worktree.

## Verification environment (read before executing)

- **Swift Android cross-compile available:** SDK `swift-6.3.2-RELEASE_android` + toolchain `org.swift.632202605101a` installed. Export `TOOLCHAINS=org.swift.632202605101a` before any Android `swift build`. First, run `swift package resolve` in the worktree (populates `.build/checkouts/swift-wirelet/`, the wirelet bootstrap).
- **Kotlin JVM unit tests available:** `~/.gradle/gradle.properties` has the GitHub Packages PAT (`gpr.user`/`gpr.key`), so `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest` can run. JVM unit tests use `unitTests.isReturnDefaultValues = true` (no Robolectric) — `android.net.Uri` is NOT constructible in tests (returns defaults), so keep Uris OUT of unit-tested code paths (see the `Resolution`/`ByteArray` design below).
- **No device/emulator connected** (`adb devices` empty). Real FluidSynth click audio CANNOT be verified here — that is a manual on-device follow-up (Task 7 documents it). Do NOT block the plan on it.
- The JNI bridge is faked in unit tests (`FakeJniBridge`), so Kotlin unit tests do NOT require the native `.so` build. Only the Swift cross-compile (Task 1) builds the Swift side.

---

## File Structure

Swift (cross-compiles to Android):
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift` — add the `nativeBuildClickSoundFont` entry point (alongside `nativeGMInstrumentList`).

Kotlin (`SheetMusicAudioAndroid`):
- Create: `.../audio/MetronomeClickSource.kt` — sealed `MetronomeClickSource` + `MetronomeClickProvider` interface.
- Create: `.../audio/synth/AndroidMetronomeClickResolver.kt` — provider → `Resolution` dispatch (JVM-testable) + `MetronomeSf2Loader` (Uri/file glue).
- Modify: `.../audio/jni/SheetMusicAudioJNI.kt` — Kotlin wrapper for the new JNI call.
- Modify: `.../audio/AndroidPlaybackEngine.kt` — `JniBridge.buildClickSoundFont`, constructor `metronomeClickProvider`, resolve + load in `prepare`, capture `Resolution` in the export snapshot.
- Modify: `.../audio/export/ExportEngineSnapshot.kt` — add `metronomeResolution`.
- Modify: `.../audio/export/AudioExporter.kt` — build a metronome synth + `MetronomeMixer`, mix into the render loop.

Kotlin tests:
- Create: `.../audio/synth/AndroidMetronomeClickResolverTest.kt`
- Modify: `.../audio/fakes/FakeJniBridge.kt` — add `buildClickSoundFont` stub.
- Create / extend: `.../audio/export/AudioExporterMetronomeTest.kt` — export now mixes the metronome.

---

## Task 1: Swift JNI entry `nativeBuildClickSoundFont`

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift`

- [ ] **Step 1: Add the entry point**

In `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift`, find the existing `nativeGMInstrumentList` entry point:

```swift
/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeGMInstrumentList()` call site.
public func nativeGMInstrumentList() -> Data {
    GMInstrumentCodec.encodeAll()
}
```

Add immediately after it:

```swift
/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeBuildClickSoundFont(...)` call site. Reuses
/// the Phase 1 Core (`WavPcmReader` + `ClickSoundFontBuilder`) to turn two
/// click WAVs into a bank-128 SF2 mapping strong→note 76 / weak→note 77.
/// Returns empty `Data` on any read failure so the Kotlin caller can fall
/// back to the GM drum-kit.
public func nativeBuildClickSoundFont(strongWav: Data, weakWav: Data) -> Data {
    guard let strong = try? WavPcmReader.read(strongWav),
          let weak = try? WavPcmReader.read(weakWav)
    else { return Data() }
    return ClickSoundFontBuilder.build(
        strong: strong.samples, strongRate: strong.sampleRate,
        weak: weak.samples, weakRate: weak.sampleRate,
    )
}
```

`SheetMusicAndroidJNI` already depends on `SheetMusicAudioCore` (Package.swift), so `WavPcmReader` / `ClickSoundFontBuilder` are in scope. Confirm the file already has `import SheetMusicAudioCore`; if not, add it.

- [ ] **Step 2: Verify the Swift side cross-compiles for Android**

Run (from the worktree):

```bash
swift package resolve
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28
```

Expected: builds successfully (this compiles `SheetMusicAndroidJNI` + `SheetMusicAudioCore` for Android, exercising the new entry point and confirming `WavPcmReader`/`ClickSoundFontBuilder` are Android-compatible). If `swift build` fails with `'semaphore.h' file not found` / SwiftOverlayShims, the NDK sysroot symlink is missing — see CLAUDE.md "One-time NDK sysroot setup"; report BLOCKED with that diagnosis rather than guessing.

- [ ] **Step 3: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click-android add Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click-android commit -m "feat(android-jni): add nativeBuildClickSoundFont (WAV->SF2 via Core)"
```

---

## Task 2: Kotlin click seam (`MetronomeClickSource` + `MetronomeClickProvider`)

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/MetronomeClickSource.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/MetronomeClickSourceTest.kt`

- [ ] **Step 1: Write the failing test**

Create `.../src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/MetronomeClickSourceTest.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class MetronomeClickSourceTest {
    @Test
    fun clickSamplesHoldsBothByteArrays() {
        val strong = byteArrayOf(1, 2, 3)
        val weak = byteArrayOf(4, 5)
        val source = MetronomeClickSource.ClickSamples(strong, weak)
        assertEquals(strong, source.strongWav)
        assertEquals(weak, source.weakWav)
    }

    @Test
    fun defaultGmIsSingleton() {
        assertEquals(MetronomeClickSource.DefaultGm, MetronomeClickSource.DefaultGm)
        assertNotEquals<MetronomeClickSource>(
            MetronomeClickSource.DefaultGm,
            MetronomeClickSource.ClickSamples(byteArrayOf(), byteArrayOf()),
        )
    }

    @Test
    fun providerReturnsConfiguredSource() {
        val provider = MetronomeClickProvider { MetronomeClickSource.DefaultGm }
        assertEquals(MetronomeClickSource.DefaultGm, provider.metronomeClickSource())
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*MetronomeClickSourceTest"`
Expected: FAIL — unresolved reference `MetronomeClickSource` / `MetronomeClickProvider`.

- [ ] **Step 3: Implement**

Create `.../src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/MetronomeClickSource.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio

import android.net.Uri

/**
 * Where the metronome's click sound comes from. Supplied by the host through
 * a [MetronomeClickProvider]. Mirrors the Swift `MetronomeClickSource` seam.
 *
 * Click samples are passed as raw WAV bytes (clicks are tiny — tens of KB —
 * and the host typically loads them from `assets`), so the click path stays
 * free of [Uri] and is unit-testable on the JVM. A full host SoundFont is
 * referenced by [Uri] instead, since it can be large.
 */
sealed interface MetronomeClickSource {
    /** Two PCM WAV blobs (strong downbeat / weak beat). */
    data class ClickSamples(val strongWav: ByteArray, val weakWav: ByteArray) : MetronomeClickSource {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ClickSamples) return false
            return strongWav.contentEquals(other.strongWav) && weakWav.contentEquals(other.weakWav)
        }
        override fun hashCode(): Int = 31 * strongWav.contentHashCode() + weakWav.contentHashCode()
    }

    /** A host-supplied SoundFont, used verbatim. */
    data class SoundFont(val uri: Uri) : MetronomeClickSource

    /** Keep the current behavior: reuse the score's GM drum-kit SoundFont. */
    object DefaultGm : MetronomeClickSource
}

/**
 * Implemented by the host to choose the metronome's click sound. Returning
 * [MetronomeClickSource.DefaultGm] (or supplying no provider) preserves the
 * legacy GM drum-kit click.
 */
fun interface MetronomeClickProvider {
    fun metronomeClickSource(): MetronomeClickSource
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*MetronomeClickSourceTest"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/MetronomeClickSource.kt Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/MetronomeClickSourceTest.kt
git -C <worktree> commit -m "feat(android-audio): add metronome click source/provider seam"
```

(Use the absolute worktree path for `<worktree>` as in Task 1.)

---

## Task 3: JNI bridge method + Kotlin wrapper + FakeJniBridge

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt`
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` (the `JniBridge` interface + `defaultBridge` only)
- Modify: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/fakes/FakeJniBridge.kt`

- [ ] **Step 1: Add the Kotlin JNI wrapper**

In `SheetMusicAudioJNI.kt`, add (mirroring `nativePitchAndStaffOfNote`, which passes a `Data` arg):

```kotlin
    fun nativeBuildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeBuildClickSoundFont(
            SwiftData.fromByteArray(strongWav, arena),
            SwiftData.fromByteArray(weakWav, arena),
            arena,
        ).toByteArray()
    }
```

- [ ] **Step 2: Add to the `JniBridge` interface + `defaultBridge`**

In `AndroidPlaybackEngine.kt`, inside `interface JniBridge`, add:

```kotlin
        /** Builds a click SF2 from two WAV blobs; empty array on failure. */
        fun buildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray): ByteArray
```

In the `companion object`'s `defaultBridge`, add the override:

```kotlin
            override fun buildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray) =
                SheetMusicAudioJNI.nativeBuildClickSoundFont(strongWav, weakWav)
```

- [ ] **Step 3: Add the FakeJniBridge stub**

In `FakeJniBridge.kt`, add a configurable field + override:

```kotlin
    var buildClickSoundFontResult: ByteArray = byteArrayOf()
    val buildClickSoundFontCalls = mutableListOf<Pair<ByteArray, ByteArray>>()
    override fun buildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray): ByteArray {
        buildClickSoundFontCalls += strongWav to weakWav
        return buildClickSoundFontResult
    }
```

(Add `buildClickSoundFontResult` as a constructor `var` parameter alongside the others if you prefer; a plain property is fine since defaults cover most tests.)

- [ ] **Step 4: Verify the module still compiles + existing tests pass**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest`
Expected: PASS (existing suite unchanged; the new bridge method is covered next task). The `SwiftJavaJNI.nativeBuildClickSoundFont` symbol referenced in `defaultBridge` is generated by the Swift build; for JVM unit tests `defaultBridge` is not exercised (tests inject `FakeJniBridge`), so compilation of the wrapper depends on the generated `SheetMusicAndroidJNI` Java class being on the classpath via the composite build. If the JVM test compile fails to resolve `SwiftJavaJNI.nativeBuildClickSoundFont`, the generated bindings need a refresh — run the Swift Android build (Task 1 Step 2) which regenerates them, then re-run. If it still can't resolve, report BLOCKED (codegen wiring issue), do not stub the symbol.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/fakes/FakeJniBridge.kt
git -C <worktree> commit -m "feat(android-audio): wire buildClickSoundFont through the JNI bridge"
```

---

## Task 4: `AndroidMetronomeClickResolver` (+ `MetronomeSf2Loader`)

**Files:**
- Create: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/AndroidMetronomeClickResolver.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/AndroidMetronomeClickResolverTest.kt`

- [ ] **Step 1: Write the failing test**

Create `.../src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/AndroidMetronomeClickResolverTest.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.synth

import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeJniBridge
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidMetronomeClickResolverTest {
    @Test
    fun clickSamplesBuildsViaBridgeAndReturnsGeneratedBytes() {
        val sf2 = byteArrayOf(10, 20, 30)
        val bridge = FakeJniBridge().apply { buildClickSoundFontResult = sf2 }
        val strong = byteArrayOf(1)
        val weak = byteArrayOf(2)
        val resolver = AndroidMetronomeClickResolver(
            provider = { MetronomeClickSource.ClickSamples(strong, weak) },
            jniBridge = bridge,
        )
        val resolution = resolver.resolve()
        assertTrue(resolution is AndroidMetronomeClickResolver.Resolution.GeneratedSf2)
        assertArrayEquals(sf2, (resolution as AndroidMetronomeClickResolver.Resolution.GeneratedSf2).bytes)
        assertEquals(1, bridge.buildClickSoundFontCalls.size)
        assertArrayEquals(strong, bridge.buildClickSoundFontCalls[0].first)
        assertArrayEquals(weak, bridge.buildClickSoundFontCalls[0].second)
    }

    @Test
    fun clickSamplesFallsBackToGmWhenBridgeReturnsEmpty() {
        val bridge = FakeJniBridge().apply { buildClickSoundFontResult = byteArrayOf() }
        val resolver = AndroidMetronomeClickResolver(
            provider = { MetronomeClickSource.ClickSamples(byteArrayOf(1), byteArrayOf(2)) },
            jniBridge = bridge,
        )
        assertEquals(AndroidMetronomeClickResolver.Resolution.DefaultGm, resolver.resolve())
    }

    @Test
    fun noProviderResolvesToDefaultGm() {
        val resolver = AndroidMetronomeClickResolver(provider = null, jniBridge = FakeJniBridge())
        assertEquals(AndroidMetronomeClickResolver.Resolution.DefaultGm, resolver.resolve())
    }

    @Test
    fun defaultGmSourceResolvesToDefaultGm() {
        val resolver = AndroidMetronomeClickResolver(
            provider = { MetronomeClickSource.DefaultGm },
            jniBridge = FakeJniBridge(),
        )
        assertEquals(AndroidMetronomeClickResolver.Resolution.DefaultGm, resolver.resolve())
    }
}
```

(Note: `SoundFont(Uri)` passthrough is intentionally NOT unit-tested — `Uri` is not constructible under `isReturnDefaultValues`. It is covered by the on-device follow-up in Task 7.)

- [ ] **Step 2: Run to verify it fails**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*AndroidMetronomeClickResolverTest"`
Expected: FAIL — unresolved `AndroidMetronomeClickResolver`.

- [ ] **Step 3: Implement**

Create `.../src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/AndroidMetronomeClickResolver.kt`:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Decides where the metronome's click sound comes from, mirroring Apple's
 * `MetronomeClickResolver`. The decision is returned as a Uri-free
 * [Resolution] so the dispatch logic is unit-testable on the JVM; turning a
 * [Resolution] into a loaded SoundFont (which needs [Context]/[Uri]) is the
 * separate [MetronomeSf2Loader] glue.
 */
internal class AndroidMetronomeClickResolver(
    private val provider: MetronomeClickProvider?,
    private val jniBridge: AndroidPlaybackEngine.JniBridge,
) {
    sealed interface Resolution {
        /** SF2 bytes built from the host's click WAVs. */
        data class GeneratedSf2(val bytes: ByteArray) : Resolution {
            override fun equals(other: Any?): Boolean =
                this === other || (other is GeneratedSf2 && bytes.contentEquals(other.bytes))
            override fun hashCode(): Int = bytes.contentHashCode()
        }
        /** A host-supplied SoundFont Uri, used verbatim. */
        data class ExistingUri(val uri: Uri) : Resolution
        /** Fall back to the score's GM drum-kit lookup. */
        object DefaultGm : Resolution
    }

    fun resolve(): Resolution =
        when (val source = provider?.metronomeClickSource() ?: MetronomeClickSource.DefaultGm) {
            is MetronomeClickSource.ClickSamples -> {
                val sf2 = jniBridge.buildClickSoundFont(source.strongWav, source.weakWav)
                if (sf2.isEmpty()) Resolution.DefaultGm else Resolution.GeneratedSf2(sf2)
            }
            is MetronomeClickSource.SoundFont -> Resolution.ExistingUri(source.uri)
            MetronomeClickSource.DefaultGm -> Resolution.DefaultGm
        }
}

/**
 * Loads a resolved metronome SoundFont onto a [SynthDriver]. Separated from
 * the resolver because it touches [Context] / [Uri] / the filesystem (not
 * JVM-unit-testable). Verified on-device.
 */
internal object MetronomeSf2Loader {
    fun load(
        synth: SynthDriver,
        resolution: AndroidMetronomeClickResolver.Resolution,
        soundfontResolver: SoundfontResolver,
        context: Context?,
    ) {
        when (resolution) {
            is AndroidMetronomeClickResolver.Resolution.GeneratedSf2 -> {
                val uri = writeToCache(resolution.bytes, context) ?: return
                synth.loadSoundFont(uri, context)
            }
            is AndroidMetronomeClickResolver.Resolution.ExistingUri ->
                synth.loadSoundFont(resolution.uri, context)
            AndroidMetronomeClickResolver.Resolution.DefaultGm -> {
                val uri = soundfontResolver.soundfontUriFor(0, 0, isDrums = true)
                    ?: soundfontResolver.defaultGmSoundfontUri
                uri?.let { synth.loadSoundFont(it, context) }
            }
        }
    }

    /** Content-addressed cache file so identical clicks reuse one file. */
    private fun writeToCache(bytes: ByteArray, context: Context?): Uri? {
        val ctx = context ?: return null
        return try {
            val dir = File(ctx.cacheDir, "metronome-clicks").apply { mkdirs() }
            val file = File(dir, "click-${bytes.contentHashCode().toUInt().toString(16)}.sf2")
            if (!file.exists() || file.length() == 0L) {
                file.outputStream().use { it.write(bytes) }
            }
            Uri.fromFile(file)
        } catch (e: Exception) {
            null
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*AndroidMetronomeClickResolverTest"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/AndroidMetronomeClickResolver.kt Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/AndroidMetronomeClickResolverTest.kt
git -C <worktree> commit -m "feat(android-audio): add click resolver (provider -> Resolution) + SF2 loader"
```

---

## Task 5: Wire into `AndroidPlaybackEngine` live playback

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt` (extend)

- [ ] **Step 1: Add the provider to both constructors + build a resolver**

In the internal primary constructor parameter list, add (after `soundfontResolver`):

```kotlin
    private val metronomeClickProvider: MetronomeClickProvider? = null,
```

In the public production constructor, add the parameter and forward it:

```kotlin
    constructor(
        context: Context,
        soundfontResolver: SoundfontResolver,
        metronomeClickProvider: MetronomeClickProvider? = null,
    ) : this(
        context = context,
        soundfontResolver = soundfontResolver,
        metronomeClickProvider = metronomeClickProvider,
        jniBridge = defaultBridge,
        synthFactory = { sr -> FluidSynthDriver.create(sr) },
        playerFactory = { synthHandle -> PlayerDriver(synthHandle) },
        oboeFactory = { OboeStream() },
        pollDispatcher = Dispatchers.Default,
    )
```

Add a lazily-built resolver field near the other internal state (e.g. after `private var metronomeMixer`):

```kotlin
    private val clickResolver by lazy {
        AndroidMetronomeClickResolver(metronomeClickProvider, jniBridge)
    }
```

Add the import: `import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver` and `import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeSf2Loader` and `import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider` (adjust to the file's existing import grouping).

- [ ] **Step 2: Use the resolver in `prepare`**

In `prepare(scoreHandle)`, find the metronome-synth block:

```kotlin
            // Dedicated metronome synth on a separate fluid_synth_t.
            val metronomeSynth = synthFactory(48_000)
            val metronomeUri = soundfontResolver.soundfontUriFor(bank = 0, program = 0, isDrums = true)
                ?: soundfontResolver.defaultGmSoundfontUri
            metronomeUri?.let { uri -> metronomeSynth.loadSoundFont(uri, context) }
            metronomeMixer = MetronomeMixer(metronomeSynth, beats)
```

Replace with:

```kotlin
            // Dedicated metronome synth on a separate fluid_synth_t. The
            // click sound comes from the provider: .clickSamples builds an
            // SF2 from the host's WAVs (via JNI), .soundFont uses a host SF2,
            // .defaultGM / no provider falls back to the GM drum-kit.
            val metronomeSynth = synthFactory(48_000)
            MetronomeSf2Loader.load(
                metronomeSynth, clickResolver.resolve(), soundfontResolver, context,
            )
            metronomeMixer = MetronomeMixer(metronomeSynth, beats)
```

- [ ] **Step 3: Extend the engine test (backward compat + resolver is consulted)**

In `AndroidPlaybackEngineTest.kt`, add a test that prepares with a click provider and asserts the bridge's `buildClickSoundFont` was called (proving the provider path is wired), plus that no-provider still prepares. Use the existing fake-driven `AndroidPlaybackEngine` construction pattern already in that file (fakes for jniBridge / synthFactory / etc.). Concretely, add:

```kotlin
    @Test
    fun prepareWithClickProviderConsultsBridge() = runTest(/* existing dispatcher pattern */) {
        val bridge = FakeJniBridge().apply {
            // minimal valid timeline + one staff + one beat so prepare() proceeds
            staffParamsResult = /* reuse the helper this test file already uses to encode one StaffParams */
            metronomeBeatsResult = /* reuse the helper to encode one MetronomeBeat */
            renderMidiResult = /* reuse the existing non-empty SMF stub */
            buildClickSoundFontResult = byteArrayOf(1, 2, 3)
        }
        val engine = /* construct AndroidPlaybackEngine with bridge + fakes +
                        metronomeClickProvider = MetronomeClickProvider {
                            MetronomeClickSource.ClickSamples(byteArrayOf(9), byteArrayOf(8))
                        } */
        engine.prepare(scoreHandle = 1L)
        assertEquals(1, bridge.buildClickSoundFontCalls.size)
        engine.teardown()
    }
```

IMPORTANT: do not invent encoding helpers — reuse exactly the ones the existing `AndroidPlaybackEngineTest` already uses to build `staffParamsResult` / `metronomeBeatsResult` / `renderMidiResult` for its existing `prepare` tests (read the file and copy the established setup). If the existing tests construct these via real codecs (`StaffParamsCodec` / `MetronomeBeatCodec`), use those. The new assertion is only that `buildClickSoundFont` was called once.

Also confirm an existing no-provider `prepare` test still passes unchanged (backward compatibility).

- [ ] **Step 4: Run tests**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*AndroidPlaybackEngineTest"`
Expected: PASS (existing + the new provider test).

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt
git -C <worktree> commit -m "feat(android-audio): play custom metronome click in live playback"
```

---

## Task 6: Metronome in offline export (the gap) + custom click

The Android exporter currently builds ONE synth for the score and never plays the metronome. Add a metronome synth + `MetronomeMixer` mixed into the render loop, loading the resolved click SF2 captured in the snapshot.

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/ExportEngineSnapshot.kt`
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` (snapshot construction)
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporter.kt`
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporterMetronomeTest.kt`

- [ ] **Step 1: Add the resolution to the snapshot**

In `ExportEngineSnapshot.kt`, add a field + import:

```kotlin
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver
```
```kotlin
internal data class ExportEngineSnapshot(
    val mixerChannels: List<MixerChannel>,
    val metronomeEnabled: Boolean,
    val metronomeVolume: Float,
    val metronomeBeats: List<MetronomeBeat>,
    val rate: Float,
    /** Resolved metronome click (GeneratedSf2 / ExistingUri / DefaultGm). */
    val metronomeResolution: AndroidMetronomeClickResolver.Resolution,
)
```

- [ ] **Step 2: Populate it in the engine's export snapshot**

In `AndroidPlaybackEngine.exportAudioFileWith`, find where `ExportEngineSnapshot(...)` is constructed and add the new argument:

```kotlin
            metronomeResolution = clickResolver.resolve(),
```

- [ ] **Step 3: Write the failing export test**

Create `.../src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporterMetronomeTest.kt`. Model it on the existing `AudioExporterTest` (reuse its fake `SynthDriver` / `PlayerDriver` / `AudioFileEncoder` factories and `ExportEngineSnapshot` construction). The new assertion: when `metronomeEnabled = true` and `metronomeBeats` is non-empty, the exporter creates a SECOND synth and fires metronome notes — i.e. a fake metronome synth receives `noteOn` on channel 9, and its `writeFloat` output is mixed into the encoder input.

Concretely, use a `FakeSynthDriver` that records `noteOn` calls and emits a constant non-zero `writeFloat`, and a fake encoder that records the peak of the PCM it receives. Assert:
- with metronome enabled + a beat at tick 0 and a player that advances past it, the metronome synth saw ≥1 `noteOn(channel = 9, ...)`, and
- the encoder received non-zero samples attributable to the metronome (e.g. compare encoder peak with metronome enabled vs disabled).

```kotlin
package io.github.jiyimeta.sheetmusic.audio.export

// imports mirroring AudioExporterTest (fakes, model types, junit, coroutines-test)

class AudioExporterMetronomeTest {
    @Test
    fun exportFiresMetronomeNotesWhenEnabled() = runTest {
        // Arrange: a metronome-enabled snapshot with one downbeat at tick 0,
        // a fake player that advances currentTick from 0 past endTick, two
        // fake synths (score + metronome) from a synthFactory that returns a
        // fresh recording fake each call, and a fake encoder.
        // Act: AudioExporter(...).run(...) with metronomeResolution = DefaultGm
        //      (the fake SynthDriver.loadSoundFont returns a valid sfid).
        // Assert: the metronome synth recorded a noteOn on channel 9.
        // (Reuse the exact fake/driver wiring from AudioExporterTest.)
    }

    @Test
    fun exportSkipsMetronomeWhenDisabled() = runTest {
        // metronomeEnabled = false ⇒ no second synth is created / no noteOn.
    }
}
```

IMPORTANT: fill in the bodies using the SAME fakes and setup the existing `AudioExporterTest` uses (read it first). Do not invent new fake types if equivalents exist. The synthFactory in `AudioExporter` is `(Int) -> SynthDriver`; the test must return a fresh recording fake per call so the score synth and metronome synth are distinguishable (e.g. collect created fakes into a list and inspect the second one).

- [ ] **Step 4: Run to verify it fails**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*AudioExporterMetronomeTest"`
Expected: FAIL — the exporter doesn't build a metronome synth yet (no `noteOn` recorded).

- [ ] **Step 5: Implement metronome mixing in `AudioExporter.run`**

Add imports:
```kotlin
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeMixer
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeSf2Loader
```

The `AudioExporter` constructor already has `resolver: SoundfontResolver` and `context: Context?`. After the score `synth`/`player`/`encoder` are created in `run`, build the optional metronome:

```kotlin
        val metronomeSynth = if (snapshot.metronomeEnabled && snapshot.metronomeBeats.isNotEmpty()) {
            synthFactory(sampleRate).also { ms ->
                MetronomeSf2Loader.load(ms, snapshot.metronomeResolution, resolver, context)
                ms.setGain(snapshot.metronomeVolume)
            }
        } else {
            null
        }
        val metronomeMixer = metronomeSynth?.let { ms ->
            MetronomeMixer(ms, snapshot.metronomeBeats).also { it.isEnabled = true }
        }
```

In the render loop, after `synth.writeFloat(frames, left, right)` and before `encoder.appendPcmFloat(...)`, mix the metronome:

```kotlin
                metronomeMixer?.let { mm ->
                    mm.updateCurrentTick(player.currentTick)
                    val mLeft = FloatArray(frames)
                    val mRight = FloatArray(frames)
                    mm.synth.writeFloat(frames, mLeft, mRight)
                    for (i in 0 until frames) {
                        left[i] += mLeft[i]
                        right[i] += mRight[i]
                    }
                }
```

In the `finally` teardown block, close the metronome synth:

```kotlin
            try { metronomeSynth?.close() } catch (_: Throwable) {}
```

(`MetronomeMixer.fire` fires `noteOn`+`noteOff` on channel 9 for each beat in `(lastTick, currentTick]`; FluidSynth's channel 9 selects the loaded SF2's bank-128 preset — same contract as live.)

- [ ] **Step 6: Run to verify it passes**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest --tests "*AudioExporterMetronomeTest"`
Expected: PASS (2 tests). Then run the full module suite to confirm no regression:
Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git -C <worktree> add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/ExportEngineSnapshot.kt Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporter.kt Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/export/AudioExporterMetronomeTest.kt
git -C <worktree> commit -m "feat(android-audio): mix metronome (custom click) into offline export"
```

---

## Task 7: Final verification + on-device follow-up note

- [ ] **Step 1: Swift Android cross-compile (full)**

Run:
```bash
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28
```
Expected: success (Core + JNI compile for Android).

- [ ] **Step 2: Full Kotlin unit suite**

Run: `./Android/gradlew :SheetMusicAudioAndroid:testDebugUnitTest`
Expected: PASS (all suites including the new Metronome / resolver / exporter tests).

- [ ] **Step 3: gate-android-tests for any new Swift tests**

If any Swift test files were added (none expected in Phase 3 — Core was Phase 1), run `Scripts/gate-android-tests.sh`. Otherwise skip.

- [ ] **Step 4: Document the on-device verification (cannot run here — no device)**

Add a short note to `Android/SheetMusicAudioAndroid/README.md` under a "Custom metronome click" heading: a host passes `metronomeClickProvider = MetronomeClickProvider { MetronomeClickSource.ClickSamples(strongWavBytes, weakWavBytes) }` to `AndroidPlaybackEngine`; live playback and export then use it; `.DefaultGm` / no provider keeps the GM drum-kit. State that on-device audio verification (real FluidSynth click) is the remaining manual step: build libs (`Scripts/android-build-libs.sh`), run the Compose example, enable metronome, confirm the custom click sounds in playback and in an exported file.

Commit the README note:
```bash
git -C <worktree> add Android/SheetMusicAudioAndroid/README.md
git -C <worktree> commit -m "docs(android-audio): document custom metronome click provider"
```

- [ ] **Step 5: No further commit** — verification only.

---

## Self-Review

**Spec coverage (Android-integration section):**
- JNI `nativeBuildClickSoundFont` reusing Core → Task 1. ✓
- Kotlin `MetronomeClickSource`/`MetronomeClickProvider` seam → Task 2. ✓
- Resolve → load click SF2 into FluidSynth (live) → Tasks 3–5. ✓
- Custom click in offline export (and implementing the missing Android export metronome) → Task 6. ✓ (scope explicitly chosen: live + export)
- Backward compatibility (no provider → GM) → resolver `DefaultGm` + engine no-provider test. ✓

**Placeholder scan:** Task 5 Step 3 and Task 6 Step 3 describe tests that must reuse the existing test file's established fakes/encoders rather than reproducing them verbatim (the exact codec/fake wiring lives in those files and must be read at implementation time). These are deliberate "reuse existing setup" instructions, not lazy placeholders — the assertions and structure are fully specified; only the boilerplate fake construction is delegated to the existing pattern. Every production-code change has complete code.

**Type consistency:** `MetronomeClickSource` (ClickSamples ByteArray/ByteArray, SoundFont Uri, DefaultGm), `MetronomeClickProvider.metronomeClickSource()`, `JniBridge.buildClickSoundFont(ByteArray,ByteArray):ByteArray`, `AndroidMetronomeClickResolver(provider, jniBridge).resolve(): Resolution`, `Resolution.{GeneratedSf2(bytes), ExistingUri(uri), DefaultGm}`, `MetronomeSf2Loader.load(synth, resolution, soundfontResolver, context)`, `ExportEngineSnapshot.metronomeResolution` are all used consistently across tasks. The Swift entry `nativeBuildClickSoundFont(strongWav:weakWav:) -> Data` matches the Kotlin wrapper's `(ByteArray, ByteArray) -> ByteArray`.

**Verification limits (be honest):** Kotlin JVM unit tests cover the dispatch/wiring logic with fakes; the Swift cross-compile confirms the JNI + Core build for Android; **real FluidSynth click audio is NOT verified here (no device)** and is the documented manual follow-up (Task 7 Step 4). The `MetronomeSf2Loader` Uri/file glue and the `SoundFont(Uri)` passthrough are not JVM-testable (Uri unavailable under `isReturnDefaultValues`) and rely on the on-device check.

**Note for the implementer:** If Gradle can't authenticate to GitHub Packages (wirelet plugin) despite `~/.gradle/gradle.properties` having `gpr.*`, or the swift-java generated `SheetMusicAndroidJNI` Java class is stale (unresolved `nativeBuildClickSoundFont`), report BLOCKED with the exact error — do not stub around the codegen. Re-running the Swift Android build (Task 1) regenerates the bindings the Kotlin composite build consumes.
