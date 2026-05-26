# Wirelet Phase 5 — swift-sheet-music Consumer Migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut swift-sheet-music's in-tree wire-format toolkit over to the published `swift-wirelet` package (v0.1.0-alpha.1), deleting the in-tree copies and switching Android codegen from `Exec` tasks + `kotlin-codegen.json` to the `io.github.jiyimeta.wirelet` Gradle plugin DSL.

**Architecture:** Swift side replaces `SheetMusicWireFormat` + `SheetMusicWireFormatMacros` + `WireFormatSchema` + `WireFormatKotlinEmitter` + `EmitKotlinCodecs` with a single `.package(url: …swift-wirelet, revision: <alpha.1 sha>)` dependency. Macro spellings (`@WireFormat`, `@WireFormatEnum`, `@WireFormatChoice`, `@WireFormatField`) stay identical; only the imported module name changes (`SheetMusicWireFormat` → `Wirelet`). Kotlin side applies the new Gradle plugin, deletes hand-written `BinaryReader/Writer.kt`, and pulls those from the `wirelet-runtime` Maven artifact. `Sources/SheetMusicAndroidJNI/` is reshuffled into per-codec-package sub-dirs (`Metadata/`, `Audio/`, `Draw/`) so each module's `wirelet { sources { … } }` scans a single coherent directory (the v1 plugin DSL has no per-type pattern rules).

**Tech Stack:**
- `swift-wirelet` `v0.1.0-alpha.1` published at `maven.pkg.github.com/jiyimeta/swift-wirelet`. Swift package URL: `git@github.com:jiyimeta/swift-wirelet.git`. Resolved revision SHA: `509a86a5b93d518b0c0f17abf85d28b62e8de4ef`.
- Gradle 8.x, Kotlin 2.0.20, AGP 8.5.0.
- GitHub Packages credentials sourced from `GITHUB_ACTOR` / `GITHUB_TOKEN` env vars (already in use for `sheet-music-android`).

**Wire-format break (intentional):** The legacy positional encoding and the wirelet TLV encoding are byte-incompatible. All `Tests/SheetMusicTests/Resources/Golden/Audio/*.bin` fixtures are regenerated in this plan (Task 11). The spec accepts this — no persisted users exist.

**Branch / commit cadence:** Land as a single PR (PR-S1 in spec terminology). Commit per task; do not squash mid-plan. Wirelet itself stays at `v0.1.0-alpha.1` unless a fix is needed mid-integration — in which case bump to `v0.1.0-alpha.2` after Phase 5 lands, not before.

---

## File Structure

### Swift sources — deleted
- `Sources/SheetMusicWireFormat/` (4 files)
- `Sources/SheetMusicWireFormatMacros/` (5 files)
- `Sources/WireFormatSchema/`
- `Sources/WireFormatKotlinEmitter/`
- `Sources/EmitKotlinCodecs/`
- `Tests/WireFormatKotlinEmitterTests/`
- `Tests/WireFormatSchemaTests/`
- `Tests/EmitKotlinCodecsTests/`

### Swift sources — moved / created (Task 2)
- Create: `Sources/SheetMusicAndroidJNI/Metadata/ScoreMetadataWire.swift` (extracted from `JNISymbols.swift`)
- Move: `Sources/SheetMusicAndroidJNI/DrawProgram.swift` → `Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`
- Existing: `Sources/SheetMusicAndroidJNI/Audio/*.swift` (unchanged location)

### Swift sources — edited
- `Package.swift` — drop in-tree wire-format targets/products; add wirelet dep; update consumer target deps to `.product(name: "Wirelet", package: "swift-wirelet")`
- `Sources/SheetMusicAudioCore/GMInstrument.swift` — `import SheetMusicWireFormat` → `import Wirelet`
- All files in `Sources/SheetMusicAndroidJNI/**.swift` containing `import SheetMusicWireFormat` (16 files)
- `Sources/SheetMusicAndroidJNI/JNISymbols.swift` — remove `ScoreMetadataWire` declaration (moved out)
- `Tests/SheetMusicTests/WireFormatTests.swift` — `import SheetMusicWireFormat` → `import Wirelet`
- All other test files importing `SheetMusicWireFormat` (8 files under `Tests/SheetMusicTests/AndroidJNI/`)
- `Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift` — regenerate-or-assert mode flag preserved; assertion bytes will change after Task 11

### Gradle / Kotlin — edited
- `Android/settings.gradle.kts` — add `pluginManagement` Maven URL for `jiyimeta/swift-wirelet`; add dependency-resolution Maven URL for the same repo
- `Android/build.gradle.kts` — add wirelet plugin classpath stanza or alias declaration
- `Android/SheetMusicAndroid/build.gradle.kts` — replace `emitKotlinCodecs` Exec task with `plugins { id("io.github.jiyimeta.wirelet") }` + `wirelet { sources { … } }`; add `api("io.github.jiyimeta:wirelet-runtime:0.1.0-alpha.1")`
- `Android/SheetMusicAudioAndroid/build.gradle.kts` — same plugin application; reuses `wirelet-runtime` transitively via `api(project(":SheetMusicAndroid"))`
- `Examples/Android/settings.gradle.kts` — add pluginManagement + dependency-resolution Maven URLs for the wirelet GitHub Packages repo
- `Examples/Android/app/build.gradle.kts` — same plugin migration

### Gradle / Kotlin — deleted
- `Sources/SheetMusicAndroidJNI/kotlin-codegen.json` (replaced by plugin DSL)
- `Tests/EmitKotlinCodecsTests/Fixtures/kotlin-codegen.json` (test target gone)
- `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryReader.kt`
- `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryWriter.kt`

### Kotlin source — edited (package rename)
All references to `io.github.jiyimeta.sheetmusic.wireformat.BinaryReader / BinaryWriter` swap to `io.github.jiyimeta.wirelet.BinaryReader / BinaryWriter`. Affected files (per pre-flight grep):
- `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt`
- `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/GMInstrumentDecoder.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/BinaryReaderTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/PathIDDecodersTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/EncoderTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/ScoreItemIDDecoderTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/FrameMetronomeBeatStaffParamsDecoderTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/ClefAnchorDecoderTest.kt`
- `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/ScoreCursorDecoderTest.kt`

### Fixtures — regenerated (Task 11)
- All files under `Tests/SheetMusicTests/Resources/Golden/Audio/*.bin` (13 files)

---

## Task 1: Add swift-wirelet package dependency

**Files:**
- Modify: `Package.swift`

The dependency is added *before* removing in-tree modules so both paths coexist during the import swap. This task only adds the dependency stanza — module targets still reference the in-tree wire-format modules.

- [ ] **Step 1: Add swift-wirelet to `dependencies` array**

Locate the `dependencies` array near the bottom of `Package.swift` (Apple-and-Android-common section). Add the entry next to existing remote packages:

```swift
.package(
    url: "git@github.com:jiyimeta/swift-wirelet.git",
    revision: "509a86a5b93d518b0c0f17abf85d28b62e8de4ef",
),
```

The revision pins to the `v0.1.0-alpha.1` tag commit. Do not change to a branch name — committed configuration must be reproducible.

- [ ] **Step 2: Verify resolution succeeds (Apple shape)**

Run: `swift package resolve`
Expected: `Fetching git@github.com:jiyimeta/swift-wirelet.git ... resolved at 509a86a (v0.1.0-alpha.1)`. `Package.resolved` updates to pin the new dep.

If the fetch fails with an SSH auth error, the user needs a working SSH deploy key. Surface this to the user instead of switching to HTTPS — committed config uses SSH per spec.

- [ ] **Step 3: Verify resolution succeeds (Android shape)**

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 swift package resolve`
Expected: same fetch + resolve message.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(wirelet-phase5): add swift-wirelet package dep at v0.1.0-alpha.1"
```

---

## Task 2: Reshuffle SheetMusicAndroidJNI sources into per-codec-package sub-dirs

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Metadata/ScoreMetadataWire.swift`
- Move: `Sources/SheetMusicAndroidJNI/DrawProgram.swift` → `Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift` (delete extracted type)

The wirelet plugin DSL scans one directory per `sources` entry. Each generated codec package needs its own directory of `@WireFormat`-bearing Swift sources.

- [ ] **Step 1: Create `Metadata/ScoreMetadataWire.swift`**

Write to `Sources/SheetMusicAndroidJNI/Metadata/ScoreMetadataWire.swift`:

```swift
import Foundation
import SheetMusicWireFormat

/// Score metadata payload returned across JNI. The wire format is
/// `i32 titleByteLen + UTF-8 + i32 composerByteLen + UTF-8` per
/// `@WireFormat`'s synthesized encoding (legacy positional shape;
/// switches to TLV in Task 3).
@WireFormat
struct ScoreMetadataWire {
    var title: String
    var composer: String
}
```

(`import SheetMusicWireFormat` flips to `import Wirelet` in Task 3 — keep as-is for this commit so the build stays green during a single concern.)

- [ ] **Step 2: Remove the extracted declaration from JNISymbols.swift**

In `Sources/SheetMusicAndroidJNI/JNISymbols.swift`, delete the `// MARK: - Wire format payloads` block (lines 11–17 inclusive — the `MARK` comment and the `ScoreMetadataWire` struct definition). Keep the import line at the top — `JNISymbols.swift` still uses `WireFormatEncodable` indirectly via the `ScoreMetadataWire(...).encodeToData()` call.

- [ ] **Step 3: Move DrawProgram.swift into a Draw/ subdir**

```bash
mkdir -p Sources/SheetMusicAndroidJNI/Draw
git mv Sources/SheetMusicAndroidJNI/DrawProgram.swift \
       Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift
```

No content edits — only the path changes.

- [ ] **Step 4: Verify Swift build still passes**

Run: `swift build`
Expected: success. No imports change as a result of moving files.

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/Metadata/ \
        Sources/SheetMusicAndroidJNI/Draw/ \
        Sources/SheetMusicAndroidJNI/JNISymbols.swift
git commit -m "refactor(android-jni): split @WireFormat sources into Metadata/Draw subdirs"
```

---

## Task 3: Flip `import SheetMusicWireFormat` → `import Wirelet` across Swift sources

**Files (Sources):**
- `Sources/SheetMusicAndroidJNI/JNISymbols.swift`
- `Sources/SheetMusicAndroidJNI/Metadata/ScoreMetadataWire.swift`
- `Sources/SheetMusicAndroidJNI/SMuFLMetricsTable.swift`
- `Sources/SheetMusicAndroidJNI/Draw/DrawProgram.swift`
- All files under `Sources/SheetMusicAndroidJNI/Audio/*.swift` (14 files)
- `Sources/SheetMusicAudioCore/GMInstrument.swift`

**Files (Package.swift):**
- Switch the consuming targets' deps from `"SheetMusicWireFormat"` → `.product(name: "Wirelet", package: "swift-wirelet")`.

- [ ] **Step 1: Mass-rewrite imports across Sources/**

Use a Python script (avoid heredoc + sed pitfalls). Write to `/tmp/wirelet-import-flip.py`:

```python
import pathlib, sys

ROOT = pathlib.Path("Sources")
OLD = "import SheetMusicWireFormat"
NEW = "import Wirelet"
count = 0
for p in ROOT.rglob("*.swift"):
    src = p.read_text()
    if OLD not in src:
        continue
    p.write_text(src.replace(OLD, NEW))
    count += 1
    print(f"updated {p}")
print(f"\n{count} files updated")
```

Run: `python3 /tmp/wirelet-import-flip.py`
Expected: 17 files updated (sanity-check against `grep -rln 'import SheetMusicWireFormat' Sources/` before).

- [ ] **Step 2: Update Package.swift target dependencies**

In `Package.swift`, locate every `dependencies: [...]` that references `"SheetMusicWireFormat"` (3 sites: `SheetMusicAudioCore`, `SheetMusicAndroidJNI`, plus any test target deps). Replace each with `.product(name: "Wirelet", package: "swift-wirelet")`. Do **not** delete the `SheetMusicWireFormat` target itself yet — that happens in Task 4.

Example (apply the same pattern to each call site):

```swift
// before
.target(
    name: "SheetMusicAudioCore",
    dependencies: ["SheetMusicCore", "SheetMusicMIDI", "SheetMusicWireFormat"],
),

// after
.target(
    name: "SheetMusicAudioCore",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicMIDI",
        .product(name: "Wirelet", package: "swift-wirelet"),
    ],
),
```

- [ ] **Step 3: Build the Apple shape**

Run: `swift build`
Expected: success. `@WireFormat`, `@WireFormatEnum`, `@WireFormatChoice` resolve via the Wirelet module's macros.

If the build fails because wirelet's TLV format changes a macro-generated signature in a way that breaks call sites, surface the diagnostic to the user — do not patch around it.

- [ ] **Step 4: Build the Android shape**

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28`
Expected: success.

- [ ] **Step 5: Run Swift tests (golden binary failures expected)**

Run: `swift test`
Expected: most tests pass; golden binary assertion tests under `Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift` fail with byte-mismatch (wire format flipped to TLV). Capture the failure list — Task 11 regenerates fixtures.

- [ ] **Step 6: Commit**

```bash
git add Sources/ Package.swift Package.resolved
git commit -m "feat(wirelet-phase5): swap import SheetMusicWireFormat -> import Wirelet across Sources/"
```

---

## Task 4: Flip imports + delete in-tree wire-format modules

**Files:**
- Modify: every file under `Tests/SheetMusicTests/` importing `SheetMusicWireFormat` (10 files)
- Modify: `Package.swift` — drop in-tree targets/products
- Delete: `Sources/SheetMusicWireFormat/`
- Delete: `Sources/SheetMusicWireFormatMacros/`
- Delete: `Sources/WireFormatSchema/`
- Delete: `Sources/WireFormatKotlinEmitter/`
- Delete: `Sources/EmitKotlinCodecs/`
- Delete: `Tests/WireFormatKotlinEmitterTests/`
- Delete: `Tests/WireFormatSchemaTests/`
- Delete: `Tests/EmitKotlinCodecsTests/`

- [ ] **Step 1: Flip imports under Tests/**

Reuse the script from Task 3 with the root changed to `Tests`. Expected: 10 files updated.

```python
import pathlib
ROOT = pathlib.Path("Tests")
OLD = "import SheetMusicWireFormat"
NEW = "import Wirelet"
for p in ROOT.rglob("*.swift"):
    src = p.read_text()
    if OLD in src:
        p.write_text(src.replace(OLD, NEW))
        print(p)
```

- [ ] **Step 2: Drop in-tree wire-format products + targets from Package.swift**

In `Package.swift`, delete:

- The product declaration `.library(name: "SheetMusicWireFormat", targets: ["SheetMusicWireFormat"])`
- The product declaration `.executable(name: "emit-kotlin-codecs", targets: ["EmitKotlinCodecs"])`
- The target blocks for `SheetMusicWireFormatMacros`, `SheetMusicWireFormat`, `WireFormatSchema`, `WireFormatKotlinEmitter`, `EmitKotlinCodecs`
- The test-target blocks for `WireFormatKotlinEmitterTests`, `WireFormatSchemaTests`, `EmitKotlinCodecsTests`
- The trailing comment block "`SheetMusicWireFormatMacros` can depend on SwiftSyntax..." (no longer relevant)

Leave the `swift-syntax` package dep in place — Wirelet pulls swift-syntax via its own manifest, and there may be other in-tree macro users (verify via `grep -rln 'SwiftSyntax\b' Package.swift`).

If swift-syntax has no other consumers after the deletion, remove that dep too.

- [ ] **Step 3: Delete the directories**

```bash
git rm -r Sources/SheetMusicWireFormat \
         Sources/SheetMusicWireFormatMacros \
         Sources/WireFormatSchema \
         Sources/WireFormatKotlinEmitter \
         Sources/EmitKotlinCodecs \
         Tests/WireFormatKotlinEmitterTests \
         Tests/WireFormatSchemaTests \
         Tests/EmitKotlinCodecsTests
```

- [ ] **Step 4: Build + test (golden tests still failing — expected)**

Run: `swift build && swift test`
Expected: build succeeds; only golden binary tests fail (will be addressed in Task 11). If any other test fails, the import flip missed a file — grep again with `grep -rln 'SheetMusicWireFormat' Sources Tests`.

- [ ] **Step 5: Verify Android build**

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 swift build --swift-sdk aarch64-unknown-linux-android28`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(wirelet-phase5): delete in-tree wire-format modules + tests"
```

---

## Task 5: Add GitHub Packages Maven repo + plugin classpath for wirelet

**Files:**
- Modify: `Android/settings.gradle.kts`
- Modify: `Examples/Android/settings.gradle.kts`

Both Android composite-builds need to (a) resolve the `io.github.jiyimeta.wirelet` Gradle plugin and (b) resolve the `io.github.jiyimeta:wirelet-runtime` Maven artifact. Both live at the same GitHub Packages Maven URL.

- [ ] **Step 1: Update Android/settings.gradle.kts**

Inside `pluginManagement.repositories`, add:

```kotlin
maven {
    name = "WireletGitHubPackages"
    url = uri("https://maven.pkg.github.com/jiyimeta/swift-wirelet")
    credentials {
        username = System.getenv("GITHUB_ACTOR")
            ?: providers.gradleProperty("gpr.user").orNull
        password = System.getenv("GITHUB_TOKEN")
            ?: providers.gradleProperty("gpr.key").orNull
    }
    content {
        includeGroup("io.github.jiyimeta")
    }
}
```

Inside `dependencyResolutionManagement.repositories`, add the same maven block (URL + credentials + content filter).

The `content { includeGroup(...) }` filter keeps Gradle from probing the wirelet repo for every Maven Central artifact.

- [ ] **Step 2: Update Examples/Android/settings.gradle.kts**

Apply the same two stanzas (pluginManagement + dependencyResolutionManagement) to `Examples/Android/settings.gradle.kts`.

- [ ] **Step 3: Sanity-check credentials resolve**

The user must have either `GITHUB_ACTOR` + `GITHUB_TOKEN` env vars exported or `gpr.user` + `gpr.key` set in `~/.gradle/gradle.properties` (per `project_android_github_packages_publish` memory, this is already set for `sheet-music-android` consumption). The same PAT works since the wirelet repo is on the same GitHub account.

If credentials are missing, surface to the user — do not commit fallback unauthenticated repos.

Run: `cd Android && ./gradlew help`
Expected: no resolution attempts yet (no module applies the plugin). If `help` errors on missing creds, the settings stanza has a typo.

- [ ] **Step 4: Commit**

```bash
git add Android/settings.gradle.kts Examples/Android/settings.gradle.kts
git commit -m "build(wirelet-phase5): add GitHub Packages repos for wirelet plugin + runtime"
```

---

## Task 6: Apply wirelet plugin to SheetMusicAndroid module

**Files:**
- Modify: `Android/SheetMusicAndroid/build.gradle.kts`
- Delete: `Sources/SheetMusicAndroidJNI/kotlin-codegen.json` (after all three modules cut over — defer to Task 12)

This module owns the `io.github.jiyimeta.sheetmusic` codecs (`ScoreMetadataWire` → `ScoreMetadataWireCodec`).

- [ ] **Step 1: Remove the `emitKotlinCodecs` Exec block + supporting wiring**

Delete the entire `// ─── Wire-format codec codegen ───…` block from `Android/SheetMusicAndroid/build.gradle.kts` (the `val emitKotlinCodecsOutput`, the `val emitKotlinCodecs by tasks.registering(Exec::class) { … }`, the second `android { sourceSets["main"].kotlin.srcDir(emitKotlinCodecsOutput) }`, and the `tasks.matching { ... }` that wires `compileKotlin → emitKotlinCodecs`).

- [ ] **Step 2: Apply the wirelet plugin**

In the top `plugins { ... }` block, add `id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.1"`.

- [ ] **Step 3: Configure the wirelet extension**

Append at module scope (after the existing `dependencies { ... }` block):

```kotlin
val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    swiftPackagePath.set(File(packageRoot, "wirelet-checkout"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Metadata"))
            codecPackage.set("io.github.jiyimeta.sheetmusic")
            modelPackage.set("io.github.jiyimeta.sheetmusic")
        }
    }
}
```

**Important about `swiftPackagePath`:** the wirelet plugin v1 forks `swift run --package-path <swiftPackagePath>` and requires a local checkout of the wirelet repo (no pre-built binary fallback). The path above (`<repo>/wirelet-checkout`) is the dev override location. Add `wirelet-checkout/` to `.gitignore` in Task 13. **Document this clearly in the PR description**: users (and CI) must run `git clone git@github.com:jiyimeta/swift-wirelet.git wirelet-checkout` (or equivalent SSH clone at the pinned SHA) before any Gradle command.

If this constraint becomes a footgun in practice, file a follow-up issue on wirelet to add a "use installed plugin binary" path. Out of scope here.

- [ ] **Step 4: Add `wirelet-runtime` dependency**

In the `dependencies { … }` block:

```kotlin
api("io.github.jiyimeta:wirelet-runtime:0.1.0-alpha.1")
```

Use `api` (not `implementation`) so downstream modules (SheetMusicAudioAndroid, Examples/Android) see the runtime classes (`BinaryReader`, `BinaryWriter`) on the compile classpath.

- [ ] **Step 5: Verify task graph**

Run: `cd Android && ./gradlew :SheetMusicAndroid:tasks --group wirelet`
Expected: `generateWireletCodecsMain` listed under the `wirelet` group.

- [ ] **Step 6: Verify the build (only this module — others still on old codegen for now)**

Generated codecs will land at `Android/SheetMusicAndroid/build/generated/wirelet/main/kotlin/io/github/jiyimeta/sheetmusic/ScoreMetadataWireCodec.kt`. The compile task should succeed.

Run: `cd Android && ./gradlew :SheetMusicAndroid:compileReleaseKotlin`
Expected: success. If `swift run` fails because the `wirelet-checkout` symlink is missing, create it now:

```bash
ln -s ~/Developer/Personal/swift-packages/swift-wirelet wirelet-checkout
```

(Gitignore added in Task 13.)

- [ ] **Step 7: Commit**

```bash
git add Android/SheetMusicAndroid/build.gradle.kts
git commit -m "build(SheetMusicAndroid): switch to wirelet plugin DSL"
```

---

## Task 7: Apply wirelet plugin to SheetMusicAudioAndroid module

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/build.gradle.kts`

This module owns the `io.github.jiyimeta.sheetmusic.audio.serialization` codecs (the bulk of the codegen — GMInstrument, Frame, MetronomeBeat, ScoreCursor, ClefAnchor, StaffAddress, StaffParams, AudioExportRange, LoopHighlight, PathIDs, ScoreItemID, CursorFrame).

- [ ] **Step 1: Delete the Exec codegen block**

Remove the entire `// ─── Wire-format codec codegen ───…` block (analogous to Task 6 Step 1, but the `--include-package` filter is `io.github.jiyimeta.sheetmusic.audio.serialization`).

- [ ] **Step 2: Apply the plugin + extension**

Add `id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.1"` to `plugins { ... }`.

Append:

```kotlin
val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    swiftPackagePath.set(File(packageRoot, "wirelet-checkout"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Audio"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.audio.serialization")
            modelPackage.set("io.github.jiyimeta.sheetmusic.audio.model")
            stripNameSuffix.set("Wire")
        }
    }
}
```

The `stripNameSuffix = "Wire"` reproduces the legacy `nameTransform.stripSuffix` behavior (e.g. `FrameWire` → `Frame`).

- [ ] **Step 3: No runtime dep needed (already transitive via SheetMusicAndroid)**

Confirm `api(project(":SheetMusicAndroid"))` is present in the existing `dependencies { ... }` — it brings `wirelet-runtime` onto this module's classpath.

- [ ] **Step 4: Verify the build**

Run: `cd Android && ./gradlew :SheetMusicAudioAndroid:compileReleaseKotlin`
Expected: success. The generated `io/github/jiyimeta/sheetmusic/audio/serialization/*Codec.kt` files land under `build/generated/wirelet/main/kotlin/`.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAudioAndroid/build.gradle.kts
git commit -m "build(SheetMusicAudioAndroid): switch to wirelet plugin DSL"
```

---

## Task 8: Apply wirelet plugin to Examples/Android/app module

**Files:**
- Modify: `Examples/Android/app/build.gradle.kts`

This module owns the `com.example.sheetmusic.draw.*` codecs (DrawProgram + DrawCommand + EncodablePage + FontID).

- [ ] **Step 1: Delete the Exec codegen block**

Same pattern as Tasks 6/7. The current Exec invocation filters `--include-package "com.example.sheetmusic.draw"`.

- [ ] **Step 2: Apply the plugin + extension**

Add `id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.1"` to `plugins { ... }`.

Append:

```kotlin
val packageRoot: File = rootProject.projectDir.resolve("../..").canonicalFile

wirelet {
    swiftPackagePath.set(File(packageRoot, "wirelet-checkout"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Draw"))
            codecPackage.set("com.example.sheetmusic.draw")
            modelPackage.set("com.example.sheetmusic.draw.model")
        }
    }
}
```

Note: `packageRoot` differs from Android/ — Examples/Android is one extra level deep (`Examples/Android/app/` → `../../`).

- [ ] **Step 3: Verify the build**

Run: `cd Examples/Android && ./gradlew :app:compileDebugKotlin`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Examples/Android/app/build.gradle.kts
git commit -m "build(examples-android): switch draw codecs to wirelet plugin DSL"
```

---

## Task 9: Delete hand-written BinaryReader/Writer.kt

**Files:**
- Delete: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryReader.kt`
- Delete: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryWriter.kt`
- Delete: the empty `wireformat/` directory if no files remain

The wirelet runtime provides equivalent classes in package `io.github.jiyimeta.wirelet`.

- [ ] **Step 1: Confirm no remaining production code references the old package**

Run: `grep -rln 'io.github.jiyimeta.sheetmusic.wireformat' Android/ Examples/Android/`
Expected: only the two files we are about to delete + test files (Task 10 fixes those).

- [ ] **Step 2: Delete the files**

```bash
git rm Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryReader.kt \
       Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryWriter.kt
rmdir Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat 2>/dev/null || true
```

- [ ] **Step 3: Verify SheetMusicAndroid still compiles**

Run: `cd Android && ./gradlew :SheetMusicAndroid:compileReleaseKotlin`
Expected: success — generated codecs reference `io.github.jiyimeta.wirelet.BinaryReader` (from the wirelet-runtime jar), not the deleted classes.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(android): delete hand-written BinaryReader/Writer (use wirelet-runtime)"
```

---

## Task 10: Update Kotlin imports from `…sheetmusic.wireformat` → `…wirelet`

**Files:** the 10 Kotlin files listed in the File Structure section above.

- [ ] **Step 1: Run a one-shot rename across Kotlin sources + tests**

Write `/tmp/wirelet-kotlin-import-flip.py`:

```python
import pathlib

ROOTS = [pathlib.Path("Android"), pathlib.Path("Examples/Android")]
OLD = "io.github.jiyimeta.sheetmusic.wireformat"
NEW = "io.github.jiyimeta.wirelet"
count = 0
for root in ROOTS:
    for p in root.rglob("*.kt"):
        src = p.read_text()
        if OLD not in src:
            continue
        p.write_text(src.replace(OLD, NEW))
        count += 1
        print(p)
print(f"{count} files updated")
```

Run: `python3 /tmp/wirelet-kotlin-import-flip.py`
Expected: 10 files updated (matches the pre-flight grep).

- [ ] **Step 2: Verify the renamed-file tests still compile + pass**

Run: `cd Android && ./gradlew :SheetMusicAndroid:test :SheetMusicAudioAndroid:test`
Expected: production tests pass. The handful of unit tests that decode the golden `.bin` files will fail at this stage — Task 11 fixes them.

- [ ] **Step 3: Commit**

```bash
git add Android/ Examples/Android/
git commit -m "refactor(android): rename wireformat package -> wirelet"
```

---

## Task 11: Regenerate golden binary fixtures

**Files:**
- Modify: `Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift` (write-mode toggle + re-run)
- Overwrite: `Tests/SheetMusicTests/Resources/Golden/Audio/*.bin` (13 files)

The legacy positional encoding is gone. Each `.bin` re-encodes via wirelet TLV. Both the Swift assertions and the Kotlin assertions (`Android/SheetMusicAudioAndroid/src/test/.../*Test.kt`) read these bytes.

- [ ] **Step 1: Inspect GoldenBinaryTests.swift for a regen path**

Read `Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift` (full file). The test likely has either:

- (a) a `regenerate = true` flag, or
- (b) a comparison-only path with no built-in writer.

If (a), set the flag, run the test once, then revert the flag to false and commit the new `.bin` files.

If (b), add a one-shot helper next to the test:

```swift
#if REGENERATE_GOLDEN_FIXTURES
@Test func regenerateAllGoldenFixtures() throws {
    let baseURL = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Golden/Audio")
    for case let (name, value) in GoldenBinaryTests.allCases {
        try value.encodeToData().write(to: baseURL.appendingPathComponent(name))
    }
}
#endif
```

Run it via `swift test -Xswiftc -DREGENERATE_GOLDEN_FIXTURES --filter regenerateAllGoldenFixtures`. Then delete the `#if` block (do not commit it).

Whichever path applies, the goal is that the `.bin` files on disk match the new wirelet TLV bytes.

- [ ] **Step 2: Verify Swift golden tests now pass**

Run: `swift test --filter GoldenBinaryTests`
Expected: all green.

- [ ] **Step 3: Verify Kotlin golden tests pass**

The `.bin` files are synced into `Android/SheetMusicAudioAndroid/src/test/resources/golden/` by the `syncGoldenBinaries` task. Run:

```bash
cd Android && ./gradlew :SheetMusicAudioAndroid:test
```

Expected: all green. The Kotlin decoders (`PathIDDecodersTest`, `ScoreCursorDecoderTest`, etc.) read the regenerated bytes via the wirelet-emitted codec + wirelet `BinaryReader`.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/Resources/Golden/Audio/ \
        Tests/SheetMusicTests/AndroidJNI/Audio/GoldenBinaryTests.swift
git commit -m "test(golden-binaries): regenerate in wirelet TLV format"
```

---

## Task 12: Delete the kotlin-codegen.json files

**Files:**
- Delete: `Sources/SheetMusicAndroidJNI/kotlin-codegen.json`
- Delete: `Tests/EmitKotlinCodecsTests/Fixtures/kotlin-codegen.json` (already gone if Task 4 cleared the whole test dir — verify)

The plugin DSL now owns this configuration.

- [ ] **Step 1: Verify nothing references the JSON**

Run: `grep -rln 'kotlin-codegen.json' . 2>/dev/null | grep -v '.build\|.git'`
Expected: empty (Tasks 6/7/8 already removed the `inputs.file(...)` lines).

- [ ] **Step 2: Delete**

```bash
git rm Sources/SheetMusicAndroidJNI/kotlin-codegen.json
```

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(android-jni): drop kotlin-codegen.json (replaced by wirelet plugin DSL)"
```

---

## Task 13: Document the wirelet-checkout dev override + gitignore

**Files:**
- Modify: `.gitignore`
- Modify: `CLAUDE.md` (or a new `docs/android-build.md`)

The wirelet plugin requires `swiftPackagePath` to point at a local checkout. Document the workflow so neither contributors nor CI is blocked.

- [ ] **Step 1: Add `wirelet-checkout` to `.gitignore`**

Append to repo root `.gitignore`:

```
# Local checkout of swift-wirelet referenced by the Gradle plugin's
# swiftPackagePath. See CLAUDE.md "Android build" section.
/wirelet-checkout
/wirelet-checkout/
```

- [ ] **Step 2: Add a short setup note to CLAUDE.md**

Inside the `## Android build (Phase 1–3)` section, append a sub-section near the end:

```markdown
### Wirelet local checkout

Android Gradle builds invoke the `io.github.jiyimeta.wirelet` plugin,
which forks `swift run` against a local `swift-wirelet` checkout pinned
by `swiftPackagePath` in each module's `wirelet { … }` block. Bootstrap
once per workspace:

    git clone git@github.com:jiyimeta/swift-wirelet.git wirelet-checkout
    cd wirelet-checkout
    git checkout 509a86a5b93d518b0c0f17abf85d28b62e8de4ef   # v0.1.0-alpha.1

A symlink works too if you already have a checkout elsewhere:

    ln -s ~/Developer/Personal/swift-packages/swift-wirelet wirelet-checkout

The `wirelet-checkout/` path is gitignored.
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore CLAUDE.md
git commit -m "docs(android): document wirelet-checkout dev-override setup"
```

---

## Task 14: Full Android composite-build verification

- [ ] **Step 1: Clean + build SheetMusicAndroid + SheetMusicAudioAndroid**

```bash
cd Android && ./gradlew clean assembleRelease
```

Expected: success. Both `.aar` artifacts produced; no codegen errors; no missing classes.

- [ ] **Step 2: Run all unit tests in the Android composite**

```bash
cd Android && ./gradlew test
```

Expected: all green.

- [ ] **Step 3: Build the Compose example app**

```bash
cd Examples/Android && ./gradlew clean :app:assembleDebug
```

Expected: success.

- [ ] **Step 4: Smoke-test on a connected emulator (optional but recommended)**

If a Pixel 6 Pro API 36 (or similar) AVD is running, install and launch:

```bash
cd Examples/Android && ./gradlew :app:installDebug
adb shell am start -n com.example.sheetmusic/.MainActivity
```

Expected: the test score loads and renders; tapping play (if a `gm.sf2` is staged) starts playback without crashing. Confirm via screenshot that ScoreMetadata + audio playback both work through the new codecs.

If the user is not in front of an emulator, skip this step — the assembleDebug success is sufficient for unattended CI.

- [ ] **Step 5: Commit (if any incidental fixes were needed)**

If steps 1–4 surfaced any small fixes, commit them with descriptive messages. If they were all green, skip this commit.

---

## Task 15: Apple build verification

- [ ] **Step 1: SwiftPM build + test**

```bash
swift build
swift test
```

Expected: all green.

- [ ] **Step 2: Xcode example app build (iOS Simulator)**

```bash
cd Examples/Apple && xcodegen generate
xcodebuild -project SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           -skipPackagePluginValidation \
           build
```

Expected: success.

- [ ] **Step 3: Xcode example app build (Mac)**

```bash
xcodebuild -project Examples/Apple/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation \
           build
```

Expected: success.

- [ ] **Step 4: SwiftLint**

```bash
swiftlint --quiet Sources Tests
```

Expected: zero warnings / errors. If SwiftLint flags imports of `Wirelet` as `unused`, the offending file probably had `SheetMusicWireFormat` re-exporting more than just macros — surface to the user.

- [ ] **Step 5: Commit (only if fixes were needed)**

Same handling as Task 14 Step 5.

---

## Task 16: Update memory + close out

- [ ] **Step 1: Update `project_wirelet_oss_extraction.md` memory**

Bump the dated summary to reflect Phase 5 completion (note: this is a memory file, not a docs commit; do not commit memory edits).

- [ ] **Step 2: Confirm there is nothing left referencing `SheetMusicWireFormat`**

```bash
grep -rln 'SheetMusicWireFormat\|emit-kotlin-codecs\|WireFormatSchema\|WireFormatKotlinEmitter\|EmitKotlinCodecs' . \
    --include='*.swift' --include='*.kt' --include='*.kts' --include='*.json' \
    --include='*.md' --include='*.sh' --include='*.yml'
```

Expected: matches only in `docs/superpowers/{specs,plans}/` (frozen historical record per CLAUDE.md "Don't update docs/superpowers/{plans,specs}/").

- [ ] **Step 3: Final summary commit (optional)**

If any incidental file changes accrued during Task 14/15, fold them into the existing per-task commits via interactive rebase (`git rebase -i origin/main`) — only if the user explicitly authorizes a rewrite. Otherwise leave commits as-is.

---

## Open follow-ups (post-Phase-5)

- **`wirelet-checkout` is awkward.** v1 plugin requires a Swift toolchain + local clone. Once the OSS extraction stabilises, file an issue on `swift-wirelet` to support either a pre-built emitter binary on Maven Central, or a `swiftSourceArtifact` config that the plugin can fetch itself.
- **Per-type package rules.** The current sub-dir split (Task 2) hides a real limitation in the v1 plugin DSL. A `rules` block in `wirelet { sources { … } }` would let consumers keep monolithic source dirs. Out of scope for Phase 5; revisit alongside the binary-distribution issue above.
- **CI credentials.** Phase 5 PR-S1 must land alongside (or be preceded by) a CI secret-store update so `swift.yml` / `android-publish.yml` have `GITHUB_TOKEN` + SSH deploy-key access to `jiyimeta/swift-wirelet`. Surface this to the user before merging to main.
