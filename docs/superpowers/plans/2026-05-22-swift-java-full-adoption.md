# swift-java Full Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every hand-written `@_cdecl` JNI entry point in `SheetMusicAndroidJNI` with swift-java jextract-generated bridges, collapse `SheetMusicAndroidJNISwiftJava` into the main module, in two committed phases (Audio first, SheetMusic second).

**Actual function count:** The spec quoted "23" based on a grep that included comment matches. Re-grepping `^@_cdecl` strictly, the real counts are **Audio ~10** (`AudioMidiBridge.swift` + `AudioMidiBridge+Render.swift` + `AudioMidiBridge+Timeline.swift`) and **SheetMusic ~7** (`JNISymbols.swift` + `CursorBridge.swift` + `LoopHighlightBridge.swift`), totalling ~17. Confirm exact count in Task 1 with `grep -E '^[[:space:]]*@_cdecl' Sources/SheetMusicAndroidJNI/*.swift | wc -l`.

**Architecture:** Each `@_cdecl` function gets replaced by a plain `public func` in `SheetMusicAndroidJNI` taking Swift-native types (`Int64`, `Data`). swift-java's `JExtractSwiftPlugin` discovers those functions and generates a Java/Kotlin class (`SheetMusicAndroidJNI`) callers invoke directly. No hand-written Kotlin facade survives. Existing pure-Swift business logic in `AudioMidiBridge` / `JNISymbols` namespaces stays untouched — only the JNI bridge layer changes.

**Tech Stack:** swift-java 0.3.0 (`mode: jni`, `JExtractSwiftPlugin`), Swift 6.x toolchain, Gradle composite build, Kotlin, Android Gradle Plugin, Pixel 6 Pro API 36 emulator.

---

## Prerequisites

This plan assumes execution in a git worktree created via `superpowers:using-git-worktrees` at the start of executing-plans / subagent-driven-development, branched from local `main`, placed under `.claude/worktrees/swift-java-full-adoption/`.

Reference spec: `docs/superpowers/specs/2026-05-22-swift-java-full-adoption-design.md`.

PoC reference (current state of `SheetMusicAndroidJNISwiftJava`):
- Swift: `Sources/SheetMusicAndroidJNISwiftJava/SwiftJavaPoc.swift` (3 functions: ping / echo / gmInstrumentList)
- Kotlin facade: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/swiftjava/SwiftJavaFacade.kt`
- jextract emits class `SheetMusicAndroidJNISwiftJava` in package `io.github.jiyimeta.sheetmusic.swiftjava`. Static methods. Functions returning `Data` get a leading `arena: SwiftArena` parameter and a `SwiftData` return that converts via `.toByteArray()`.

After migration, the equivalent class will be `SheetMusicAndroidJNI` in package `io.github.jiyimeta.sheetmusic.swiftjava` (same package — swift-java.config keeps `javaPackage`).

## File Structure

**Swift (Sources/SheetMusicAndroidJNI/)**

| File | Change |
| --- | --- |
| `swift-java.config` | **Create** — moved from `Sources/SheetMusicAndroidJNISwiftJava/swift-java.config`, content unchanged. |
| `AudioMidiBridge.swift` | Delete byte-marshalling helpers (`makeJByteArray`, `readJByteArray`); delete two `@_cdecl` blocks (`nativePitchAndStaffOfNote`, `nativeEarliestOf`); add two `public func` replacements. |
| `AudioMidiBridge+Render.swift` | Delete `@_cdecl` for `nativeRenderMidi`; add `public func` replacement. |
| `AudioMidiBridge+Timeline.swift` | Delete six `@_cdecl` blocks; add six `public func` replacements. |
| `JNISymbols.swift` | Audio entries (`nativeGMInstrumentList`, `nativeResolveExportTickRange`) → `public func`; SheetMusic entries (`nativeLoadScore`, `nativeReleaseScore`, `nativeScoreMetadata`, `nativeInstallSMuFLMetrics`, `nativeComputeLayout`) → `public func`. |
| `CursorBridge.swift` | Delete `@_cdecl` for `nativeCursorFrame`; add `public func` replacement. |
| `LoopHighlightBridge.swift` | Delete `@_cdecl` for `nativeLoopHighlightRects`; add `public func` replacement. |

**Swift (Sources/SheetMusicAndroidJNISwiftJava/)** — entire directory **deleted** at the end (Task 16).

**Package.swift**
- Add `SwiftJava` dependency and `JExtractSwiftPlugin` to the `SheetMusicAndroidJNI` target (Task 1).
- `exclude: ["swift-java.config"]` added to `SheetMusicAndroidJNI` target.
- Delete `SheetMusicAndroidJNISwiftJava` target and its `SheetMusicJNISwiftJava` product (Task 16).

**Kotlin (Android/SheetMusicAndroid/src/main/kotlin/)**
- `io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt` — replace `external fun` body with calls to `SheetMusicAndroidJNI.nativeXXX(arena, ...)` (Phase 2, Task 12). Keep the object name & method signatures so call sites in `ScoreViewModel`, library tests don't change.
- `io/github/jiyimeta/sheetmusic/swiftjava/SwiftJavaFacade.kt` — **delete** (Task 16).

**Kotlin (Android/SheetMusicAudioAndroid/src/main/kotlin/)**
- `io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt` — replace `external fun` body with calls to `SheetMusicAndroidJNI.nativeXXX(arena, ...)` (Phase 1, Task 8). Keep the object name & method signatures.

**Android/SheetMusicAndroid/build.gradle.kts** — update comment on line 53 (Task 16) referencing `SheetMusicAndroidJNISwiftJava`.

**Examples/Android** — no code changes expected; the example calls `SheetMusicJNI` / `SheetMusicAudioJNI` (which we keep as thin wrappers), not the swift-java generated class directly.

> **Spec deviation note.** Spec said "no facade layer", but jextract emits one big `SheetMusicAndroidJNI` class with arena-managed return values, and the existing Kotlin packaging splits Audio vs Score across two modules. Keeping `SheetMusicJNI` and `SheetMusicAudioJNI` as thin Kotlin objects (1-line method bodies that delegate to jextract output + handle arena) preserves the public Android library API and centralises arena handling. Without this, every caller in Examples/Android would need to import the swift-java generated class and pass arena explicitly — much more churn for negative ergonomic gain. Net effect: zero hand-written `external fun`, but the class names `SheetMusicJNI` / `SheetMusicAudioJNI` survive as 5-line delegating objects. If you (the executor) disagree after seeing the actual code, revisit before Task 8.

---

## Task 1: Add SwiftJava + JExtract plugin to SheetMusicAndroidJNI

**Goal:** Get the plugin attached and producing output for `SheetMusicAndroidJNI` without migrating any function yet. Validates plugin scaling step 1.

**Files:**
- Modify: `Package.swift:86-97`
- Create: `Sources/SheetMusicAndroidJNI/swift-java.config`
- Modify (no functional change): `Sources/SheetMusicAndroidJNISwiftJava/swift-java.config` (deleted in Task 16; left in place for now so PoC keeps compiling)

- [ ] **Step 1: Create `Sources/SheetMusicAndroidJNI/swift-java.config`**

Same content as the existing PoC config:

```json
{
  "javaPackage": "io.github.jiyimeta.sheetmusic.swiftjava",
  "mode": "jni",
  "logLevel": "debug"
}
```

- [ ] **Step 2: Update `Package.swift` `SheetMusicAndroidJNI` target**

Replace lines 86–97 of `Package.swift`:

```swift
    .target(
        name: "SheetMusicAndroidJNI",
        dependencies: [
            "SheetMusicCore",
            "SheetMusicMSCX",
            "SheetMusicMusicXML",
            "SheetMusicLayout",
            "SheetMusicMIDI",
            "SheetMusicAudioCore",
            "SheetMusicWireFormat",
            .product(name: "SwiftJava", package: "swift-java"),
        ] + (isAndroid ? ["CJNI"] : []),
        exclude: [
            "swift-java.config",
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
        plugins: [
            .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
        ],
    ),
```

- [ ] **Step 3: Build for host to confirm plugin runs**

Run: `swift build --target SheetMusicAndroidJNI`
Expected: builds cleanly; the JExtractSwiftPlugin should run on the existing public Swift API in `SheetMusicAndroidJNI` and emit warnings/notes but no errors. If the existing `@_cdecl` `public func` declarations cause jextract to choke (e.g., on `UnsafeMutablePointer<JNIEnv?>` parameters), that is the first finding — record it before proceeding.

- [ ] **Step 4: Build for Android to confirm composite build still works**

Run: `./gradlew :SheetMusicAndroid:assembleDebug :SheetMusicAudioAndroid:assembleDebug`
Expected: success (Audio JNI still goes through hand-written `@_cdecl` / `external fun`; nothing has been migrated yet).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/SheetMusicAndroidJNI/swift-java.config
git commit -m "build(android-jni): attach JExtractSwiftPlugin to SheetMusicAndroidJNI"
```

---

## Task 2: Spike — migrate `nativeGMInstrumentList` (no handle, no input)

**Goal:** Validate the migration pattern end-to-end with the simplest possible function before doing 22 more. This function takes no input and returns `Data` — same shape as the PoC.

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift` (find the `@_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeGMInstrumentList")` block — likely in `AudioMidiBridge+Timeline.swift` based on the earlier grep at line 177)

Actually — the grep result placed it at `AudioMidiBridge+Timeline.swift:177`. Confirm location with:
```bash
grep -n nativeGMInstrumentList Sources/SheetMusicAndroidJNI/*.swift
```

- [ ] **Step 1: Add public Swift function**

In `AudioMidiBridge+Timeline.swift` (outside any `#if os(Android)` block), add:

```swift
/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeGMInstrumentList()` call site.
public func nativeGMInstrumentList() -> Data {
    GMInstrumentCodec.encodeAll()
}
```

- [ ] **Step 2: Build host to confirm jextract sees the new function**

Run: `swift build --target SheetMusicAndroidJNI`
Expected: succeeds. Locate the jextract output directory:
```bash
find .build -path "*JExtract*" -name "*.java" -o -path "*JExtract*" -name "*.kt" | head
```
Verify a Java/Kotlin file referencing `nativeGMInstrumentList` exists. Record its package and class name (expected: package `io.github.jiyimeta.sheetmusic.swiftjava`, class `SheetMusicAndroidJNI`).

- [ ] **Step 3: Update `SheetMusicAudioJNI.kt` to delegate to swift-java output**

Edit `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt`. Replace the `external fun nativeGMInstrumentList(): ByteArray` line:

```kotlin
package io.github.jiyimeta.sheetmusic.audio.jni

import io.github.jiyimeta.sheetmusic.swiftjava.SheetMusicAndroidJNI
import org.swift.swiftkit.core.SwiftMemoryManagement

internal object SheetMusicAudioJNI {
    init {
        @Suppress("UNUSED_EXPRESSION")
        io.github.jiyimeta.sheetmusic.SheetMusicJNI.toString()
    }

    fun nativeGMInstrumentList(): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SheetMusicAndroidJNI.nativeGMInstrumentList(arena).toByteArray()
    }

    // All other entries unchanged — still external fun for now.
    external fun nativeRenderMidi(scoreHandle: Long): ByteArray
    external fun nativeTimelineSummary(scoreHandle: Long): LongArray
    external fun nativeFrameAtTick(scoreHandle: Long, tick: Long): ByteArray
    external fun nativeFrameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray
    external fun nativeMetronomeBeats(scoreHandle: Long): ByteArray
    external fun nativeStaffParams(scoreHandle: Long): ByteArray
    external fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long
    external fun nativeEarliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray
    external fun nativeItemEndTick(scoreHandle: Long, idBytes: ByteArray): Long
    external fun nativeResolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray
}
```

Note: the actual `SheetMusicAndroidJNI` class import path and `arena` first-vs-last argument position must match what jextract emits in Step 2. If the emitted signature differs from the assumption shown, adjust here.

- [ ] **Step 4: Delete the `@_cdecl` block for nativeGMInstrumentList**

In `AudioMidiBridge+Timeline.swift`, delete:

```swift
@_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeGMInstrumentList")
public func Java_io_github_jiyimeta_sheetmusic_audio_jni_SheetMusicAudioJNI_nativeGMInstrumentList(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
) -> jbyteArray? {
    return makeJByteArray(env: envPtr, bytes: GMInstrumentCodec.encodeAll())
}
```

- [ ] **Step 5: Build Android composite**

Run: `./gradlew :SheetMusicAudioAndroid:assembleDebug`
Expected: success.

- [ ] **Step 6: Run JVM unit tests**

Run: `./gradlew :SheetMusicAudioAndroid:test`
Expected: pass. (Tests that use `FakeJniBridge` are unaffected; tests that invoke real JNI need the .so loaded, which only the emulator path provides.)

- [ ] **Step 7: Smoke test on emulator**

Boot Pixel 6 Pro API 36, install the Compose example app:

```bash
./gradlew :Examples:Android:app:installDebug
adb shell am start -n com.example.sheetmusic/.MainActivity
```

Open the MIDI Program picker (the part of the Compose example that consumes `GMInstrument` list) and confirm the instrument names render. If empty or crashing, the swift-java route failed — debug before proceeding.

- [ ] **Step 8: Commit spike**

```bash
git add Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt
git commit -m "refactor(android-jni): migrate nativeGMInstrumentList to swift-java"
```

---

## Task 3: Migrate `nativePitchAndStaffOfNote` and `nativeItemEndTick` (Int64 in/out, bytes in)

**Goal:** Validate the byte-input → primitive-output pattern. These take a `jlong` + `jbyteArray` and return `jlong`.

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift` (delete `@_cdecl` for `nativePitchAndStaffOfNote` + `nativeEarliestOf` byte helpers stay for now)
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift` (delete `@_cdecl` for `nativeItemEndTick`)
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt`

- [ ] **Step 1: Add `public func` for both in respective Swift files**

In `AudioMidiBridge.swift`, outside `#if os(Android)`, add:

```swift
public func nativePitchAndStaffOfNote(scoreHandle: Int64, noteIdBytes: Data) -> Int64 {
    let invalid = Int64(bitPattern: 0xFFFF_FFFF_FFFF_FFFF)
    guard let score = scoreTable.value(for: scoreHandle) else { return invalid }
    guard !noteIdBytes.isEmpty,
          let noteId = try? PathIDCodecs.decode(noteIdBytes)
    else { return invalid }
    return AudioMidiBridge.pitchAndStaffOfNote(score: score, noteId: noteId)
}
```

In `AudioMidiBridge+Timeline.swift`, outside `#if os(Android)`, add the corresponding `nativeItemEndTick`. Open the existing `@_cdecl` block for `nativeItemEndTick` (line ~161 per the earlier grep) and copy its body shape into a new public func taking `(scoreHandle: Int64, idBytes: Data) -> Int64`.

- [ ] **Step 2: Delete the two `@_cdecl` blocks**

Remove the matching `@_cdecl("Java_..._nativePitchAndStaffOfNote")` block from `AudioMidiBridge.swift` and `@_cdecl("Java_..._nativeItemEndTick")` from `AudioMidiBridge+Timeline.swift`.

- [ ] **Step 3: Build host**

Run: `swift build --target SheetMusicAndroidJNI`
Expected: success. Confirm jextract emits `nativePitchAndStaffOfNote(Long, ByteArray): Long` and `nativeItemEndTick(Long, ByteArray): Long` (no arena parameter — primitive return doesn't need one).

- [ ] **Step 4: Update Kotlin facade for both**

In `SheetMusicAudioJNI.kt`, replace both `external fun` lines with delegating fun bodies:

```kotlin
fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long =
    SheetMusicAndroidJNI.nativePitchAndStaffOfNote(scoreHandle, noteIdBytes)

fun nativeItemEndTick(scoreHandle: Long, idBytes: ByteArray): Long =
    SheetMusicAndroidJNI.nativeItemEndTick(scoreHandle, idBytes)
```

If jextract's emitted Kotlin parameter for `Data` is not raw `ByteArray` (e.g., `SwiftData`), wrap accordingly.

- [ ] **Step 5: Android build + JVM test**

Run: `./gradlew :SheetMusicAudioAndroid:assembleDebug :SheetMusicAudioAndroid:test`
Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift \
        Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt
git commit -m "refactor(android-jni): migrate nativePitchAndStaffOfNote, nativeItemEndTick to swift-java"
```

---

## Task 4: Migrate remaining Audio bytes-in/bytes-out functions

**Goal:** Apply the established pattern to the 6 functions that take `(Long, ByteArray)` and return `ByteArray`: `nativeFrameForCursor`, `nativeEarliestOf`, `nativeResolveExportTickRange`.

Plus the 4 functions that take `(Long)` or `(Long, Long)` and return `ByteArray` or `LongArray`: `nativeRenderMidi`, `nativeTimelineSummary`, `nativeFrameAtTick`, `nativeMetronomeBeats`, `nativeStaffParams`.

Total this task: **8 functions** (the remaining Audio entries minus the 3 done in Tasks 2-3).

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift`
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Render.swift`
- Modify: `Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift`
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt`

- [ ] **Step 1: For each of the 8 functions, add a `public func` mirror outside `#if os(Android)`**

The general pattern for `ByteArray` return:

```swift
public func nativeXXX(scoreHandle: Int64, /* other args */) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    // — decode inputs if any —
    // — call AudioMidiBridge.xxx or equivalent —
    return resultData  // or Data() on failure
}
```

For `LongArray` return:

```swift
public func nativeXXX(scoreHandle: Int64, /* other args */) -> [Int64] {
    guard let score = scoreTable.value(for: scoreHandle) else { return [] }
    // ...
    return resultArray
}
```

Confirm with jextract that `[Int64]` maps to Kotlin `LongArray` (the current `nativeTimelineSummary` and `nativeResolveExportTickRange` return `LongArray`); if not, adjust to return `Data` and decode on the Kotlin side.

Take the body verbatim from each existing `@_cdecl` block, dropping the `envPtr` / `clazz` parameters and the `makeJByteArray` / `readJByteArray` shims.

- [ ] **Step 2: Delete the corresponding 8 `@_cdecl` blocks**

After all 8 public funcs are in place and the file compiles, delete the matching `@_cdecl` blocks from all three `AudioMidiBridge*.swift` files.

- [ ] **Step 3: Build host**

Run: `swift build --target SheetMusicAndroidJNI`
Expected: success.

- [ ] **Step 4: Update Kotlin facade for all 8**

In `SheetMusicAudioJNI.kt`, replace each `external fun` with a delegating wrapper as in Task 3 Step 4. Functions returning `ByteArray` need `arena.toByteArray()`:

```kotlin
fun nativeRenderMidi(scoreHandle: Long): ByteArray {
    val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
    return SheetMusicAndroidJNI.nativeRenderMidi(arena, scoreHandle).toByteArray()
}
// ... repeat for the other 7 ...
```

Functions returning `LongArray`:

```kotlin
fun nativeTimelineSummary(scoreHandle: Long): LongArray {
    val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
    return SheetMusicAndroidJNI.nativeTimelineSummary(arena, scoreHandle).toLongArray()
}
```

Adjust per actual jextract output (the `.toXxxArray()` conversion method name and whether arena is required).

- [ ] **Step 5: Delete the now-dead byte helpers in `AudioMidiBridge.swift`**

`makeJByteArray` and `readJByteArray` (lines 68–96 of `AudioMidiBridge.swift`) are no longer called by any code in this file — verify with `grep` and delete the whole helper block plus the `import CJNI` line (if no other `@_cdecl` in this specific file remains). Be careful: other files (`JNISymbols.swift`, `CursorBridge.swift`, `LoopHighlightBridge.swift`) still use these helpers via `@_cdecl` until Phase 2; if they live in `AudioMidiBridge.swift` and are referenced elsewhere, leave them until Phase 2 cleanup.

After this step, `AudioMidiBridge.swift` should have no `#if os(Android)` block at all if all helpers and `@_cdecl` are gone.

- [ ] **Step 6: Build + test**

```bash
swift test --filter 'SheetMusicAndroidJNI'  # or whatever the package's host tests for this module are
./gradlew :SheetMusicAudioAndroid:assembleDebug :SheetMusicAudioAndroid:test
```
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/AudioMidiBridge*.swift \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt
git commit -m "refactor(android-jni): migrate remaining 8 Audio JNI entries to swift-java"
```

---

## Task 5: Migrate `nativeResolveExportTickRange` if it lives in `JNISymbols.swift`

**Goal:** This one entry might be in `JNISymbols.swift` rather than `AudioMidiBridge+*.swift`. Confirm location.

```bash
grep -n nativeResolveExportTickRange Sources/SheetMusicAndroidJNI/*.swift
```

- [ ] **Step 1: If located in `JNISymbols.swift`**, follow the same pattern as Task 4: add public func + delete `@_cdecl` + update Kotlin facade. If it was already migrated as part of Task 4, skip this task.

- [ ] **Step 2: Commit (if Step 1 happened)**

```bash
git add Sources/SheetMusicAndroidJNI/JNISymbols.swift \
        Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt
git commit -m "refactor(android-jni): migrate nativeResolveExportTickRange to swift-java"
```

---

## Task 6: Verify Phase 1 (Audio fully migrated)

**Goal:** Confirm SheetMusicAudioJNI has zero `external fun` left and the example still works end-to-end.

- [ ] **Step 1: Grep for any `external fun` in Audio**

```bash
grep -n 'external fun' Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/jni/SheetMusicAudioJNI.kt
```
Expected: no matches.

- [ ] **Step 2: Grep for any `@_cdecl` for Audio JNI in Swift**

```bash
grep -rn '@_cdecl.*SheetMusicAudioJNI' Sources/SheetMusicAndroidJNI/
```
Expected: no matches.

- [ ] **Step 3: Run full host Swift test suite**

```bash
swift test
```
Expected: pass.

- [ ] **Step 4: Run Android library JVM unit tests**

```bash
./gradlew :SheetMusicAudioAndroid:test :SheetMusicAndroid:test
```
Expected: pass.

- [ ] **Step 5: Smoke test on emulator**

Reinstall and run:

```bash
./gradlew :Examples:Android:app:installDebug
adb shell am start -n com.example.sheetmusic/.MainActivity
```

Manual: load the default score, start MIDI playback, scroll the score, change MIDI program. Should behave identically to the pre-migration build. Confirm audio is audible and the cursor advances.

- [ ] **Step 6: Tag Phase 1 done with empty merge commit (optional but recommended)**

```bash
git commit --allow-empty -m "checkpoint(android-jni): Phase 1 (Audio) swift-java migration verified"
```

---

## Task 7: Spike — migrate `nativeLoadScore` and `nativeReleaseScore`

**Goal:** Validate the SheetMusic side. These two functions own the score handle lifecycle. Note: the underlying `scoreTable: HandleTable<Int64, Score>` is already a Swift-side handle table (not raw pointers), so the spec's "ScoreHandle opaque pointer" risk is already resolved — these should migrate just like Audio entries.

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift` (lines 15 + 41 per earlier grep)
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt`

- [ ] **Step 1: Read existing `@_cdecl` for both functions** to capture exact behaviour.

```bash
sed -n '10,60p' Sources/SheetMusicAndroidJNI/JNISymbols.swift
```

- [ ] **Step 2: Add public funcs**

```swift
public func nativeLoadScore(bytes: Data) -> Int64 {
    // — body lifted from @_cdecl, minus envPtr/clazz/byte helpers —
}

public func nativeReleaseScore(handle: Int64) {
    // — body lifted from @_cdecl —
}
```

- [ ] **Step 3: Delete the two `@_cdecl` blocks**

- [ ] **Step 4: Build host**

```bash
swift build --target SheetMusicAndroidJNI
```

- [ ] **Step 5: Update Kotlin facade**

In `SheetMusicJNI.kt`, replace the two `external fun` declarations with delegating wrappers (same pattern as Audio).

- [ ] **Step 6: Build Android + test**

```bash
./gradlew :SheetMusicAndroid:assembleDebug :SheetMusicAndroid:test
./gradlew :Examples:Android:app:assembleDebug
```
Expected: all green. Install on emulator and verify the example still loads a score (score appears, layout renders).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/JNISymbols.swift \
        Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt
git commit -m "refactor(android-jni): migrate nativeLoadScore, nativeReleaseScore to swift-java"
```

---

## Task 8: Migrate remaining 5 SheetMusic entries

**Goal:** `nativeScoreMetadata`, `nativeInstallSMuFLMetrics`, `nativeComputeLayout`, `nativeCursorFrame`, `nativeLoopHighlightRects`.

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift`
- Modify: `Sources/SheetMusicAndroidJNI/CursorBridge.swift`
- Modify: `Sources/SheetMusicAndroidJNI/LoopHighlightBridge.swift`
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt`

- [ ] **Step 1: For each of the 5, add a `public func` mirror, following Task 4 Step 1 patterns.**

Per-function notes:
- `nativeScoreMetadata(scoreHandle: Int64) -> Data` — straightforward.
- `nativeInstallSMuFLMetrics(bytes: Data) -> Bool` — primitive return, no arena needed.
- `nativeComputeLayout(scoreHandle: Int64, pageWidthMM: Double, pageHeightMM: Double) -> Data` — verify swift-java handles `Double` parameters.
- `nativeCursorFrame(scoreHandle: Int64, cursorBytes: Data) -> Data` — pattern identical to Audio bytes-in/bytes-out.
- `nativeLoopHighlightRects(scoreHandle: Int64, fromTick: Int64, toTick: Int64) -> Data` — three primitive args + bytes return.

- [ ] **Step 2: Delete the 5 `@_cdecl` blocks**

- [ ] **Step 3: Delete any now-unused byte helpers in `JNISymbols.swift` / `CursorBridge.swift` / `LoopHighlightBridge.swift`**

If `makeJByteArray` / `readJByteArray` exist locally in these files (separate from `AudioMidiBridge.swift`), and no `@_cdecl` remains in the file, delete the helpers and the `#if os(Android)` / `import CJNI` blocks.

- [ ] **Step 4: Build host**

```bash
swift build --target SheetMusicAndroidJNI
```

- [ ] **Step 5: Update Kotlin facade for all 5 in `SheetMusicJNI.kt`**

Same delegation pattern. Keep object name `SheetMusicJNI` and method signatures unchanged.

- [ ] **Step 6: Verify `CJNI` is no longer needed by `SheetMusicAndroidJNI`**

If all `@_cdecl` have been removed package-wide, the `CJNI` dependency in `Package.swift:96` becomes dead. Verify with:

```bash
grep -rn 'import CJNI\|@_cdecl' Sources/SheetMusicAndroidJNI/
```

If both come up empty, remove `"CJNI"` from `SheetMusicAndroidJNI`'s `dependencies` in `Package.swift` (line 96). Do NOT delete the `CJNI` target itself — `SheetMusicAndroidJNISwiftJava` may still need it transitively until Task 9 deletes that module.

- [ ] **Step 7: Build Android + test**

```bash
./gradlew :SheetMusicAndroid:assembleDebug :SheetMusicAudioAndroid:assembleDebug \
          :SheetMusicAndroid:test :SheetMusicAudioAndroid:test \
          :Examples:Android:app:assembleDebug
```
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/ Package.swift \
        Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt
git commit -m "refactor(android-jni): migrate 5 remaining SheetMusic JNI entries to swift-java"
```

---

## Task 9: Delete `SheetMusicAndroidJNISwiftJava` module + `SwiftJavaFacade.kt`

**Goal:** With all 23 entries now flowing through `SheetMusicAndroidJNI`'s jextract output, the PoC module and its facade are dead.

**Files:**
- Delete: `Sources/SheetMusicAndroidJNISwiftJava/` (entire directory)
- Delete: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/swiftjava/SwiftJavaFacade.kt`
- Modify: `Package.swift` (remove `SheetMusicAndroidJNISwiftJava` target lines 98–113 and the product lines 216–220)
- Modify: `Android/SheetMusicAndroid/build.gradle.kts:53` (the comment referencing `SheetMusicAndroidJNISwiftJava`)

- [ ] **Step 1: Confirm no other consumers**

```bash
grep -rn 'SheetMusicAndroidJNISwiftJava\|SwiftJavaFacade' \
    Sources/ Android/ Examples/ Tests/ Package.swift
```
The only matches should be the files/lines about to be deleted.

- [ ] **Step 2: Delete the Swift module**

```bash
git rm -r Sources/SheetMusicAndroidJNISwiftJava/
```

- [ ] **Step 3: Delete the Kotlin facade**

```bash
git rm Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/swiftjava/SwiftJavaFacade.kt
```

If the directory `swiftjava/` is now empty, leave it (Git doesn't track empty dirs; it will disappear automatically).

- [ ] **Step 4: Edit `Package.swift`**

Remove the `SheetMusicAndroidJNISwiftJava` target block (lines 98–113):

```swift
    .target(
        name: "SheetMusicAndroidJNISwiftJava",
        dependencies: [...],
        exclude: [...],
        swiftSettings: [...],
        plugins: [...],
    ),
```

Remove the `SheetMusicJNISwiftJava` product (lines 216–220):

```swift
        .library(
            name: "SheetMusicJNISwiftJava",
            type: .dynamic,
            targets: ["SheetMusicAndroidJNISwiftJava"],
        ),
```

- [ ] **Step 5: Update `Android/SheetMusicAndroid/build.gradle.kts` comment on line 53**

Replace the comment text referencing `SheetMusicAndroidJNISwiftJava` with the current accurate description (all JNI now goes through `SheetMusicAndroidJNI` via swift-java).

- [ ] **Step 6: Build everything**

```bash
swift build
./gradlew :SheetMusicAndroid:assembleDebug :SheetMusicAudioAndroid:assembleDebug \
          :Examples:Android:app:assembleDebug
```
Expected: all green.

- [ ] **Step 7: Commit cleanup**

```bash
git add -A
git commit -m "refactor(android-jni): delete SheetMusicAndroidJNISwiftJava PoC after full adoption"
```

---

## Task 10: Final verification + handoff

**Goal:** Run the spec's Done criteria one last time on the clean tree.

- [ ] **Step 1: Full host test suite**

```bash
swift test
```
Expected: pass.

- [ ] **Step 2: Full Android JVM test suite**

```bash
./gradlew :SheetMusicAndroid:test :SheetMusicAudioAndroid:test
```
Expected: pass.

- [ ] **Step 3: Compose example smoke on Pixel 6 Pro API 36 emulator**

```bash
./gradlew :Examples:Android:app:installDebug
adb shell am start -n com.example.sheetmusic/.MainActivity
```

Manual checklist on emulator:
- Default score loads and renders.
- MIDI playback starts; audio audible.
- Cursor advances as playback progresses.
- Score scrolls with cursor (auto-scroll).
- Program picker shows GM instrument list.
- Loop selection produces highlight rectangles.

If anything fails, that's a regression caused by this branch — debug before merging.

- [ ] **Step 4: Grep sanity — should all be empty**

```bash
grep -rn '@_cdecl' Sources/SheetMusicAndroidJNI/
grep -rn 'external fun' Android/SheetMusicAndroid/src/main/kotlin/ Android/SheetMusicAudioAndroid/src/main/kotlin/
grep -rn 'SheetMusicAndroidJNISwiftJava\|SwiftJavaFacade' Sources/ Android/ Examples/ Tests/ Package.swift
```
Expected: all three return zero matches.

- [ ] **Step 5: Hand off to finishing-a-development-branch**

Invoke `superpowers:finishing-a-development-branch` skill to decide on merge / PR strategy.

---

## Risks resurfaced during implementation

If during any task you discover:

- **jextract emits unexpected types** (e.g., `SwiftData` instead of `byte[]`, arena-as-last-arg, free function instead of class method): adapt the Kotlin facade pattern in all subsequent tasks. Don't revisit completed tasks unless they break.
- **JExtractSwiftPlugin scaling failure** (Gradle composite build can't resolve generated sources, or build time explodes): pause and BLOCK; the spec author needs to make a strategy call. Do not silently switch back to `@_cdecl`.
- **A function takes an unsupported type** (callback, function pointer, `UnsafePointer`): flag in plan output, propose a wrapper that converts to a supported shape, get user confirmation before implementing.
- **Performance regression observed in emulator** (e.g., laggy playback, audio dropouts): note in the final report but do not block — the spec explicitly accepts this as out-of-scope.
