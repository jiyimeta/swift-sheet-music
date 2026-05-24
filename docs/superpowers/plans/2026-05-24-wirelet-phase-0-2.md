# Wirelet OSS Extraction — Phase 0–2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the `@WireFormat` macro family + Swift schema parser + Kotlin emitter + Kotlin runtime out of `swift-sheet-music` into a new standalone repo `wirelet` (Phase 0), port the existing functionality verbatim (Phase 1), then evolve to a TLV wire format with `Optional`/`Data`/`Dictionary` support and macro-diagnostic polish (Phase 2). End state: `wirelet` is feature-complete for v0.1 in isolation. `swift-sheet-music` is **untouched** through this plan (consumer-ization is a later phase).

**Architecture:** Single monorepo `wirelet/` with `Package.swift` at root for Swift artifacts and `kotlin/` subdirectory for Gradle-built Kotlin runtime + (later) plugin. Wire format moves from positional little-endian to protobuf-style TLV: each field on the wire is `<tag-varint> <payload>`, with the bottom 3 bits of the tag-varint encoding wire type. Cross-language fixtures (`.bin` + `.json`) become the source of truth for compatibility. Reference: `docs/superpowers/specs/2026-05-24-wirelet-oss-extraction-design.md`.

**Tech Stack:** SwiftPM (Swift 6.x, macOS 14+ / Linux), SwiftSyntax 600.x (macro plugin + source parsing), Kotlin 1.9+ / Gradle 8.x, JDK 17. Apache-2.0.

---

## Working directories

Two roots are touched by this plan:

1. **swift-sheet-music worktree** (current location, this plan file lives here):
   `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/`
   — Only the plan file (`docs/superpowers/plans/2026-05-24-wirelet-phase-0-2.md`) gets committed here. **No source changes** to `swift-sheet-music` in this plan.

2. **wirelet repo** (new, peer of swift-sheet-music):
   `/Users/kiichi/Developer/Personal/swift-packages/wirelet/`
   — All Phase 0/1/2 implementation lands here. Subagents must use absolute paths or `cd` into this directory; **do not modify swift-sheet-music** during implementation.

Every task's `Files:` block uses absolute paths to remove ambiguity.

---

## Phase 0 — repo init

### Task 0.1: Create wirelet repo skeleton

**Files:**
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Package.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/README.md`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/LICENSE`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/.gitignore`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/settings.gradle.kts`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/build.gradle.kts`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/.claude/worktrees/.gitkeep`

- [ ] **Step 1: Create the directory and `git init`**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/.claude/worktrees
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git init -b main
```

Expected: `Initialized empty Git repository in .../wirelet/.git/`.

- [ ] **Step 2: Create `Package.swift` with an empty target list**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "wirelet",
    platforms: [
        .macOS(.v14),
    ],
    products: [],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: []
)
```

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift package describe`
Expected: succeeds, reports "name: wirelet" with zero targets.

- [ ] **Step 3: Create `README.md` placeholder**

```markdown
# wirelet

A Swift-macro-driven wire-format toolkit for cross-runtime IPC between Swift and Kotlin.

> **Not Square Wire.** Square Wire is a protobuf-derived schema/codec generator for the JVM; wirelet is a SwiftSyntax-driven generator producing Swift codecs (via Swift macros) and Kotlin codecs (via a CLI emitter) from a single `@WireFormat` Swift source-of-truth declaration. Different problem, different mechanism.

Status: **pre-alpha**, private repo. v0.1 ships Swift + Kotlin emitters; further languages and Maven Central publishing are deferred.
```

- [ ] **Step 4: Create `LICENSE` (Apache-2.0)**

Copy the full Apache-2.0 license text (use `curl -fsSL https://www.apache.org/licenses/LICENSE-2.0.txt` to fetch, save to LICENSE).

- [ ] **Step 5: Create `.gitignore`**

```
.build/
.swiftpm/
Packages/
xcuserdata/
*.xcodeproj/
DerivedData/

kotlin/.gradle/
kotlin/build/
kotlin/**/build/
kotlin/local.properties

.claude/worktrees/*
!.claude/worktrees/.gitkeep
```

- [ ] **Step 6: Create `kotlin/settings.gradle.kts`**

```kotlin
rootProject.name = "wirelet"
```

- [ ] **Step 7: Create `kotlin/build.gradle.kts` (root, empty for now)**

```kotlin
// Subprojects added in Phase 1.
```

- [ ] **Step 8: Stage the `.claude/worktrees/` directory**

```bash
touch /Users/kiichi/Developer/Personal/swift-packages/wirelet/.claude/worktrees/.gitkeep
```

- [ ] **Step 9: Verify and commit**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add .
git status
```

Expected: 7 files staged (`Package.swift`, `README.md`, `LICENSE`, `.gitignore`, `kotlin/settings.gradle.kts`, `kotlin/build.gradle.kts`, `.claude/worktrees/.gitkeep`).

```bash
git commit -m "Phase 0: repo skeleton (Package.swift + Kotlin Gradle root + license)"
```

Note: **do not** create the GitHub remote in this task. The user owns the `gh repo create --private jiyimeta/wirelet` step.

---

## Phase 1 — code port (existing functionality only)

Each task copies one source unit out of swift-sheet-music into wirelet and renames. Source paths in swift-sheet-music are absolute; copy is mechanical except for type/package renames spelled out per task.

### Task 1.1: Port WireletMacros

Mechanical rename: `SheetMusicWireFormatMacros` → `WireletMacros`. Macro user-facing names (`WireFormat`, `WireFormatEnum`, `WireFormatChoice`) are unchanged. Only the **plugin module name** changes.

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/SheetMusicWireFormatMacros/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/Plugin.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatMacro.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatEnumMacro.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatChoiceMacro.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatDiagnostic.swift`

- [ ] **Step 1: Copy the 5 source files verbatim**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/SheetMusicWireFormatMacros/*.swift /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/
```

- [ ] **Step 2: Search the copied files for module-name references**

Run: `grep -nE 'SheetMusicWireFormat(Macros)?' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/*.swift`

Expected: zero hits. The macros are self-contained — any reference to the host module name would be a copy-paste bug. If hits appear, replace `SheetMusicWireFormatMacros` → `WireletMacros` and `SheetMusicWireFormat` → `Wirelet` (the runtime module renamed in Task 1.2).

- [ ] **Step 3: Add the macro target to Package.swift**

Append to `targets:` in `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Package.swift`:

```swift
.macro(
    name: "WireletMacros",
    dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
    ]
),
```

- [ ] **Step 4: Verify build**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift build`
Expected: succeeds with the macro target compiled. (Macro plugins compile standalone; no runtime usage yet.)

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add Sources/WireletMacros Package.swift
git commit -m "Phase 1: port WireletMacros (verbatim from SheetMusicWireFormatMacros)"
```

---

### Task 1.2: Port Wirelet runtime

Mechanical rename: `SheetMusicWireFormat` → `Wirelet`. The public types `WireFormatEncodable`, `WireFormatDecodable`, `WireFormat`, `WireFormatError`, `KotlinTarget` keep their names. The **macro `#externalMacro(module:)` argument** must change from `"SheetMusicWireFormatMacros"` → `"WireletMacros"`.

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/SheetMusicWireFormat/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormat.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormatWriter.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormatReader.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/Conformances.swift`

- [ ] **Step 1: Copy the 4 source files verbatim**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/SheetMusicWireFormat/*.swift /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/
```

- [ ] **Step 2: Rename macro module references**

In `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormat.swift`, replace **all** occurrences of `"SheetMusicWireFormatMacros"` with `"WireletMacros"` (there are 6 — one per `#externalMacro(module:type:)` call: WireFormat, WireFormat(kotlin:), WireFormatEnum, WireFormatEnum(kotlin:), WireFormatChoice, WireFormatChoice(kotlin:)).

Run: `grep -n 'externalMacro' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormat.swift`
Expected: 6 lines, all `module: "WireletMacros"`.

- [ ] **Step 3: Add the runtime target and library product**

Edit `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Package.swift`:

```swift
products: [
    .library(name: "Wirelet", targets: ["Wirelet"]),
],
```

Append to `targets:`:

```swift
.target(
    name: "Wirelet",
    dependencies: ["WireletMacros"]
),
```

- [ ] **Step 4: Build**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift build`
Expected: `Wirelet` and `WireletMacros` both compile.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add Sources/Wirelet Package.swift
git commit -m "Phase 1: port Wirelet runtime (verbatim from SheetMusicWireFormat)"
```

---

### Task 1.3: Port WireletSchema

Mechanical: `WireFormatSchema` → `WireletSchema`. Type names (`Schema`, `WireType`, `WireStruct`, `WireChoice`, `WireRawEnum`, `WireField`, `KotlinTarget`) keep their names.

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/WireFormatSchema/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletSchema/Schema.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletSchema/SchemaParser.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletSchema/Internal/` (mirror tree)

- [ ] **Step 1: Copy the entire directory tree verbatim**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletSchema
cp -R /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/WireFormatSchema/. /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletSchema/
```

- [ ] **Step 2: Audit for renames**

Run: `grep -rnE 'WireFormatSchema|SheetMusicWireFormat' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletSchema/`
Expected: zero hits (parser only references SwiftSyntax + its own types). Fix any hit by renaming `WireFormatSchema` → `WireletSchema`.

- [ ] **Step 3: Add the target to Package.swift**

```swift
.target(
    name: "WireletSchema",
    dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
    ]
),
```

- [ ] **Step 4: Build**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift build`
Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/WireletSchema Package.swift
git commit -m "Phase 1: port WireletSchema (verbatim from WireFormatSchema)"
```

---

### Task 1.4: Port WireletKotlinEmitter

Mechanical: `WireFormatKotlinEmitter` → `WireletKotlinEmitter`. Kotlin package emitted in output: was `io.github.jiyimeta.sheetmusic.wireformat`, now **`io.github.jiyimeta.wirelet`**. This is the only meaningful behavioral change.

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/WireFormatKotlinEmitter/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter/` (full tree)

- [ ] **Step 1: Copy the directory tree verbatim**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter
cp -R /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/WireFormatKotlinEmitter/. /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter/
```

- [ ] **Step 2: Rename the default serialization package**

Search for the runtime-package default in the emitter:

Run: `grep -rn 'io.github.jiyimeta.sheetmusic.wireformat\|sheetmusic.wireformat' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter/`

Replace every hit with `io.github.jiyimeta.wirelet`. This is the package that generated `import` statements point at for `BinaryReader`/`BinaryWriter`.

- [ ] **Step 3: Audit for any other rename**

Run: `grep -rnE 'WireFormatKotlinEmitter|WireFormatSchema' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter/`

Fix: `WireFormatSchema` → `WireletSchema`. The string `WireFormatKotlinEmitter` may legitimately appear in `import` statements within Swift source — but since the file is the implementation, not a consumer, no `import WireFormatKotlinEmitter` should exist. If it does, drop it.

- [ ] **Step 4: Add target**

```swift
.target(
    name: "WireletKotlinEmitter",
    dependencies: ["WireletSchema"]
),
```

- [ ] **Step 5: Build**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift build`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/WireletKotlinEmitter Package.swift
git commit -m "Phase 1: port WireletKotlinEmitter; default kotlin pkg renamed io.github.jiyimeta.wirelet"
```

---

### Task 1.5: Port EmitWireletKotlin CLI

Rename: `EmitKotlinCodecs` → `EmitWireletKotlin`. Executable product name: `emit-kotlin-codecs` → `emit-wirelet-kotlin`.

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/EmitKotlinCodecs/main.swift`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/EmitWireletKotlin/main.swift`

- [ ] **Step 1: Copy and audit**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/EmitWireletKotlin
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Sources/EmitKotlinCodecs/main.swift /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/EmitWireletKotlin/main.swift
```

Run: `grep -nE 'WireFormatSchema|WireFormatKotlinEmitter|emit-kotlin-codecs|EmitKotlinCodecs' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/EmitWireletKotlin/main.swift`

Apply renames:
- `import WireFormatSchema` → `import WireletSchema`
- `import WireFormatKotlinEmitter` → `import WireletKotlinEmitter`
- Any user-facing string referring to `emit-kotlin-codecs` (usage / help text) → `emit-wirelet-kotlin`

- [ ] **Step 2: Add executable target + product**

In `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Package.swift`:

```swift
products: [
    .library(name: "Wirelet", targets: ["Wirelet"]),
    .executable(name: "emit-wirelet-kotlin", targets: ["EmitWireletKotlin"]),
],
```

```swift
.executableTarget(
    name: "EmitWireletKotlin",
    dependencies: ["WireletSchema", "WireletKotlinEmitter"]
),
```

- [ ] **Step 3: Build the executable**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift build --product emit-wirelet-kotlin`
Expected: produces `.build/debug/emit-wirelet-kotlin`.

- [ ] **Step 4: Smoke-run with --help**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift run emit-wirelet-kotlin --help` (or whatever flag triggers the existing usage text)
Expected: usage prints without crashing. If the CLI has no `--help` handling, run it with no args and confirm the error message is sane.

- [ ] **Step 5: Commit**

```bash
git add Sources/EmitWireletKotlin Package.swift
git commit -m "Phase 1: port emit-wirelet-kotlin CLI (renamed from emit-kotlin-codecs)"
```

---

### Task 1.6: Port Swift tests

Rename test targets to mirror their source-target renames:
- `WireFormatSchemaTests` → `WireletSchemaTests`
- `WireFormatKotlinEmitterTests` → `WireletKotlinEmitterTests`
- `EmitKotlinCodecsTests` → `EmitWireletKotlinTests`

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Tests/WireFormatSchemaTests/`, `Tests/WireFormatKotlinEmitterTests/`, `Tests/EmitKotlinCodecsTests/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletSchemaTests/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletKotlinEmitterTests/`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/EmitWireletKotlinTests/`

- [ ] **Step 1: Copy all three test trees**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletSchemaTests
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletKotlinEmitterTests
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/EmitWireletKotlinTests

cp -R /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Tests/WireFormatSchemaTests/. /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletSchemaTests/
cp -R /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Tests/WireFormatKotlinEmitterTests/. /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletKotlinEmitterTests/
cp -R /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Tests/EmitKotlinCodecsTests/. /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/EmitWireletKotlinTests/
```

- [ ] **Step 2: Rewrite imports in all test files**

Run for each tree:

```bash
grep -rln 'import WireFormatSchema\|import WireFormatKotlinEmitter\|import SheetMusicWireFormat\|@testable import EmitKotlinCodecs' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/
```

For every hit, replace:
- `import WireFormatSchema` → `import WireletSchema`
- `import WireFormatKotlinEmitter` → `import WireletKotlinEmitter`
- `import SheetMusicWireFormat` → `import Wirelet`
- `@testable import EmitKotlinCodecs` → `@testable import EmitWireletKotlin`
- `@testable import WireFormatSchema` → `@testable import WireletSchema`
- `@testable import WireFormatKotlinEmitter` → `@testable import WireletKotlinEmitter`

- [ ] **Step 3: Check fixture file references**

The Schema/Emitter fixtures (`Fixtures/*.swift`, `Fixtures/*.expected.kt`, `Fixtures/kotlin-codegen.json`) reference the Kotlin runtime package in their **expected output**. Run:

```bash
grep -rn 'io.github.jiyimeta.sheetmusic.wireformat' /Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/
```

Replace every hit with `io.github.jiyimeta.wirelet`. These are intentional matches between emitter output and golden files; the emitter rename in Task 1.4 means goldens must move in lockstep.

- [ ] **Step 4: Add test targets to Package.swift**

```swift
.testTarget(
    name: "WireletSchemaTests",
    dependencies: ["WireletSchema"],
    resources: [.copy("Fixtures")]
),
.testTarget(
    name: "WireletKotlinEmitterTests",
    dependencies: ["WireletKotlinEmitter", "WireletSchema"],
    resources: [.copy("Fixtures")]
),
.testTarget(
    name: "EmitWireletKotlinTests",
    dependencies: ["EmitWireletKotlin", "WireletKotlinEmitter", "WireletSchema"],
    resources: [.copy("Fixtures")]
),
```

- [ ] **Step 5: Run all tests**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift test`
Expected: all three test targets compile and pass. If a golden-file mismatch appears, the cause is almost certainly a leftover `sheetmusic.wireformat` package string in a fixture; re-run the grep from Step 3.

- [ ] **Step 6: Commit**

```bash
git add Tests Package.swift
git commit -m "Phase 1: port Swift tests; rewrite imports + fixture pkg strings"
```

---

### Task 1.7: Port Kotlin runtime (BinaryReader / BinaryWriter)

The Kotlin runtime moves from the Android module's sub-package to a standalone Gradle module `:runtime` producing the `wirelet-runtime` Maven artifact. Package: `io.github.jiyimeta.sheetmusic.wireformat` → `io.github.jiyimeta.wirelet`.

**Files:**
- Source (read-only): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryReader.kt`, `BinaryWriter.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/build.gradle.kts`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/BinaryReader.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/BinaryWriter.kt`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/settings.gradle.kts`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/build.gradle.kts`

- [ ] **Step 1: Create the `:runtime` module directory + copy sources**

```bash
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/test/kotlin/io/github/jiyimeta/wirelet

cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryReader.kt /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/BinaryReader.kt
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction/Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/wireformat/BinaryWriter.kt /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/BinaryWriter.kt
```

- [ ] **Step 2: Rewrite package declaration in both copied files**

Open each and change:
```kotlin
package io.github.jiyimeta.sheetmusic.wireformat
```
to:
```kotlin
package io.github.jiyimeta.wirelet
```

Run: `grep -n '^package' /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/*.kt`
Expected: 2 lines, both `package io.github.jiyimeta.wirelet`.

- [ ] **Step 3: Author `kotlin/runtime/build.gradle.kts`**

```kotlin
plugins {
    kotlin("jvm")
    `maven-publish`
}

group = "io.github.jiyimeta"
version = (findProperty("wireletVersion") as String?) ?: "0.0.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
    withSourcesJar()
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
}

tasks.test {
    useJUnitPlatform()
}

publishing {
    publications {
        create<MavenPublication>("runtime") {
            from(components["java"])
            artifactId = "wirelet-runtime"
        }
    }
    // Repositories declared in Phase 4 (publish.yml). Local development
    // uses `publishToMavenLocal`.
}
```

- [ ] **Step 4: Add the module to `kotlin/settings.gradle.kts`**

Replace contents with:

```kotlin
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "wirelet"

include(":runtime")
```

- [ ] **Step 5: Add the Kotlin Gradle plugin to `kotlin/build.gradle.kts`**

Replace contents with:

```kotlin
plugins {
    kotlin("jvm") version "1.9.22" apply false
}
```

- [ ] **Step 6: Build the runtime**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin && ./gradlew :runtime:build`

If `./gradlew` doesn't exist yet: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin && gradle wrapper --gradle-version 8.5` first, then `./gradlew :runtime:build`. Commit the wrapper.

Expected: BUILD SUCCESSFUL; `kotlin/runtime/build/libs/runtime.jar` produced.

- [ ] **Step 7: Smoke test publishing locally**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin
./gradlew :runtime:publishToMavenLocal -PwireletVersion=0.0.1-local
ls ~/.m2/repository/io/github/jiyimeta/wirelet-runtime/0.0.1-local/
```

Expected: `wirelet-runtime-0.0.1-local.jar`, `wirelet-runtime-0.0.1-local.pom`, `wirelet-runtime-0.0.1-local-sources.jar` present.

- [ ] **Step 8: Commit (including the wrapper)**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add kotlin
git commit -m "Phase 1: port Kotlin runtime as :runtime module; pkg io.github.jiyimeta.wirelet"
```

---

### Task 1.8: Phase 1 green-light verification

Confirm the wirelet repo stands on its own.

- [ ] **Step 1: Re-run all Swift checks**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
swift build
swift test
```

Expected: both green.

- [ ] **Step 2: Re-run all Kotlin checks**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin
./gradlew test
```

Expected: green.

- [ ] **Step 3: Confirm swift-sheet-music untouched**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction
git status
```

Expected: only the plan file in `docs/superpowers/plans/` is modified (or already committed). No source/test files modified.

- [ ] **Step 4: Tag the milestone (local-only)**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git tag phase-1-complete
```

No push (the GitHub remote is created by the user out-of-band).

---

## Phase 2 — feature gap fill

Order from spec §Phasing (D + E land first because they reshape the wire format; A/B/C ride on top; F/G/H polish).

### Task 2.1: TLV runtime primitives (Swift)

Add wire-type-aware TLV helpers to `Wirelet`'s reader/writer. The existing fixed-width LE methods stay (used internally by varint encoding for fixed-32/64 wire types).

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormatWriter.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormatReader.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormat.swift` (add `WireType`, expand `WireFormatError`)
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/Varint.swift`
- Test: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletRuntimeTests/VarintTests.swift`
- Test: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletRuntimeTests/TLVPrimitivesTests.swift`

- [ ] **Step 1: Author the `WireType` enum + add error cases (TDD precursor)**

Append to `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormat.swift`:

```swift
/// The 3-bit wire-type field stored in the low bits of every tag varint.
public enum WireType: UInt8, Sendable {
    case varint = 0          // Int / UInt / Bool / enum raw
    case fixed64 = 1         // Double, fixed Int64
    case lengthDelimited = 2 // String / Data / Array / Dictionary / nested struct / choice
    case fixed32 = 5         // Float, fixed Int32
}
```

Extend `WireFormatError`:

```swift
public enum WireFormatError: Error, Equatable {
    case truncated(needed: Int, remaining: Int)
    case invalidCount(Int32)
    case invalidUTF8
    /// A tag varint had an unrecognized wire-type code (i.e. not 0/1/2/5).
    case unknownWireType(UInt8)
    /// A varint exceeded the maximum 10 bytes (64-bit value).
    case varintOverflow
    /// An unknown tag was encountered and the decoder is in strict mode.
    /// `wireType` allows the caller to skip the field if they relax.
    case unknownTag(tag: UInt32, wireType: WireType)
    /// `@WireFormatChoice` saw a discriminator outside the known case range.
    case unknownChoiceDiscriminator(UInt32)
}
```

- [ ] **Step 2: Author `Tests/WireletRuntimeTests/VarintTests.swift` (failing)**

Create a new test target. First add to `Package.swift`:

```swift
.testTarget(
    name: "WireletRuntimeTests",
    dependencies: ["Wirelet"]
),
```

Then:

```swift
import Testing
import Foundation
@testable import Wirelet

@Test func unsignedVarintRoundTrip() throws {
    let cases: [UInt64] = [0, 1, 127, 128, 16383, 16384, UInt64.max]
    for v in cases {
        var w = WireFormatWriter()
        w.writeVarint(v)
        var r = WireFormatReader(data: w.data)
        try #expect(r.readVarint() == v)
    }
}

@Test func zigZagSignedRoundTrip() throws {
    let cases: [Int64] = [0, -1, 1, -2, 2, Int64.min, Int64.max]
    for v in cases {
        var w = WireFormatWriter()
        w.writeZigZagVarint(v)
        var r = WireFormatReader(data: w.data)
        try #expect(r.readZigZagVarint() == v)
    }
}

@Test func varintOverflowDetected() {
    // 11 bytes of continuation = guaranteed overflow.
    let bytes = Data(repeating: 0x80, count: 11)
    var r = WireFormatReader(data: bytes)
    #expect(throws: WireFormatError.varintOverflow) { try r.readVarint() }
}
```

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet && swift test --filter WireletRuntimeTests`
Expected: fails (writeVarint / readVarint don't exist yet).

- [ ] **Step 3: Implement `Varint.swift`**

```swift
import Foundation

extension WireFormatWriter {
    /// Append an unsigned little-endian base-128 varint (7 bits per byte,
    /// high bit set on all but the last byte).
    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            appendBytes([UInt8(v & 0x7F) | 0x80])
            v >>= 7
        }
        appendBytes([UInt8(v)])
    }

    /// Append a signed value using zig-zag encoding before varint.
    public mutating func writeZigZagVarint(_ value: Int64) {
        let zz = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        writeVarint(zz)
    }
}

extension WireFormatReader {
    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            let byte = try readUInt8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw WireFormatError.varintOverflow
    }

    public mutating func readZigZagVarint() throws -> Int64 {
        let zz = try readVarint()
        let v = Int64(bitPattern: zz >> 1) ^ -(Int64(bitPattern: zz & 1))
        return v
    }
}
```

If `WireFormatReader` doesn't already expose a `readUInt8()` helper, add one in this same file:

```swift
extension WireFormatReader {
    public mutating func readUInt8() throws -> UInt8 {
        try readInteger() as UInt8
    }
}
```

Adjust based on the actual API surface ported in Task 1.2 — read the file before adding to avoid duplicate symbols.

Run: `swift test --filter WireletRuntimeTests/varint`
Expected: passes.

- [ ] **Step 4: Author TLV primitive tests (failing)**

In `Tests/WireletRuntimeTests/TLVPrimitivesTests.swift`:

```swift
import Testing
import Foundation
@testable import Wirelet

@Test func tagEncodesWireTypeInLowBits() throws {
    var w = WireFormatWriter()
    w.writeTag(tag: 7, wireType: .lengthDelimited)
    var r = WireFormatReader(data: w.data)
    let (tag, wt) = try r.readTag()
    #expect(tag == 7)
    #expect(wt == .lengthDelimited)
}

@Test func lengthPrefixedRoundTrip() throws {
    var w = WireFormatWriter()
    w.writeLengthPrefixed { inner in
        inner.writeVarint(42)
        inner.writeVarint(43)
    }
    var r = WireFormatReader(data: w.data)
    try r.readLengthPrefixed { inner in
        try #expect(inner.readVarint() == 42)
        try #expect(inner.readVarint() == 43)
    }
}

@Test func skipUnknownLengthDelimited() throws {
    var w = WireFormatWriter()
    w.writeTag(tag: 99, wireType: .lengthDelimited)
    w.writeLengthPrefixed { $0.appendBytes([0xCA, 0xFE]) }
    w.writeTag(tag: 1, wireType: .varint)
    w.writeVarint(7)

    var r = WireFormatReader(data: w.data)
    let (tag1, wt1) = try r.readTag()
    #expect(tag1 == 99 && wt1 == .lengthDelimited)
    try r.skipUnknownField(wireType: wt1)
    let (tag2, _) = try r.readTag()
    #expect(tag2 == 1)
    try #expect(r.readVarint() == 7)
}
```

Run: fails (writeTag / readTag / writeLengthPrefixed / readLengthPrefixed / skipUnknownField missing).

- [ ] **Step 5: Implement TLV primitives**

Append to `WireFormatWriter.swift`:

```swift
extension WireFormatWriter {
    public mutating func writeTag(tag: UInt32, wireType: WireType) {
        writeVarint(UInt64(tag) << 3 | UInt64(wireType.rawValue))
    }

    /// Buffers the body, then writes its varint length, then the bytes.
    /// Body callback receives an inner writer to avoid double-writes.
    public mutating func writeLengthPrefixed(_ body: (inout WireFormatWriter) -> Void) {
        var inner = WireFormatWriter()
        body(&inner)
        writeVarint(UInt64(inner.data.count))
        appendBytes(inner.data)
    }
}
```

Append to `WireFormatReader.swift`:

```swift
extension WireFormatReader {
    public mutating func readTag() throws -> (tag: UInt32, wireType: WireType) {
        let raw = try readVarint()
        let wtCode = UInt8(raw & 0b111)
        guard let wireType = WireType(rawValue: wtCode) else {
            throw WireFormatError.unknownWireType(wtCode)
        }
        let tag = UInt32(raw >> 3)
        return (tag, wireType)
    }

    /// Read the body length, slice that many bytes into a sub-reader, advance.
    public mutating func readLengthPrefixed<R>(
        _ body: (inout WireFormatReader) throws -> R
    ) throws -> R {
        let len = Int(try readVarint())
        let slice = try readBytes(count: len)
        var inner = WireFormatReader(data: Data(slice))
        return try body(&inner)
    }

    public mutating func skipUnknownField(wireType: WireType) throws {
        switch wireType {
        case .varint:           _ = try readVarint()
        case .fixed64:          _ = try readBytes(count: 8)
        case .lengthDelimited:  _ = try readLengthPrefixed { _ in () }
        case .fixed32:          _ = try readBytes(count: 4)
        }
    }
}
```

If `readBytes(count:)` doesn't exist, add it (read the existing reader first).

Run: `swift test --filter WireletRuntimeTests`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add Sources/Wirelet Tests/WireletRuntimeTests Package.swift
git commit -m "Phase 2.1: TLV runtime primitives (Swift) — varint/zigzag/tag/length-prefixed/skip"
```

---

### Task 2.2: TLV runtime primitives (Kotlin)

Mirror Task 2.1 in `kotlin/runtime/`. Add the same set of helpers and a JUnit test suite.

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/BinaryReader.kt`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/BinaryWriter.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/WireType.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/main/kotlin/io/github/jiyimeta/wirelet/WireFormatException.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/test/kotlin/io/github/jiyimeta/wirelet/VarintTest.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/runtime/src/test/kotlin/io/github/jiyimeta/wirelet/TLVPrimitivesTest.kt`

- [ ] **Step 1: Define `WireType` and exceptions**

`WireType.kt`:
```kotlin
package io.github.jiyimeta.wirelet

enum class WireType(val code: Int) {
    VARINT(0),
    FIXED64(1),
    LENGTH_DELIMITED(2),
    FIXED32(5);

    companion object {
        fun fromCode(code: Int): WireType =
            entries.firstOrNull { it.code == code }
                ?: throw WireFormatException.UnknownWireType(code)
    }
}
```

`WireFormatException.kt`:
```kotlin
package io.github.jiyimeta.wirelet

sealed class WireFormatException(message: String) : RuntimeException(message) {
    class Truncated(needed: Int, remaining: Int) :
        WireFormatException("needed $needed, remaining $remaining")
    class InvalidCount(count: Int) :
        WireFormatException("invalid count $count")
    class InvalidUtf8 :
        WireFormatException("invalid UTF-8 in string payload")
    class UnknownWireType(code: Int) :
        WireFormatException("unknown wire type code $code")
    class VarintOverflow :
        WireFormatException("varint exceeded 10 bytes")
    class UnknownTag(tag: Int, wireType: WireType) :
        WireFormatException("unknown tag $tag (wire type $wireType)")
    class UnknownChoiceDiscriminator(disc: Int) :
        WireFormatException("unknown choice discriminator $disc")
}
```

- [ ] **Step 2: Write failing JUnit tests**

`VarintTest.kt`:
```kotlin
package io.github.jiyimeta.wirelet

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class VarintTest {
    @Test fun unsignedRoundTrip() {
        listOf(0L, 1L, 127L, 128L, 16383L, 16384L, Long.MAX_VALUE).forEach { v ->
            val w = BinaryWriter().apply { writeVarint(v) }
            val r = BinaryReader(w.toByteArray())
            assertEquals(v, r.readVarint())
        }
    }

    @Test fun zigZagRoundTrip() {
        listOf(0L, -1L, 1L, -2L, 2L, Long.MIN_VALUE, Long.MAX_VALUE).forEach { v ->
            val w = BinaryWriter().apply { writeZigZagVarint(v) }
            val r = BinaryReader(w.toByteArray())
            assertEquals(v, r.readZigZagVarint())
        }
    }

    @Test fun varintOverflow() {
        val bytes = ByteArray(11) { 0x80.toByte() }
        assertFailsWith<WireFormatException.VarintOverflow> {
            BinaryReader(bytes).readVarint()
        }
    }
}
```

`TLVPrimitivesTest.kt` mirrors the Swift `TLVPrimitivesTests` with `BinaryWriter.writeTag(7, WireType.LENGTH_DELIMITED)` etc.

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin && ./gradlew :runtime:test --tests '*VarintTest*'`
Expected: compile failure (methods missing).

- [ ] **Step 3: Implement varint + TLV in BinaryWriter.kt / BinaryReader.kt**

Add to `BinaryWriter`:

```kotlin
fun writeVarint(value: Long) {
    var v = value.toULong()  // unsigned shift semantics
    while (v >= 0x80u) {
        writeU8(((v and 0x7Fu) or 0x80u).toInt())
        v = v shr 7
    }
    writeU8(v.toInt())
}

fun writeZigZagVarint(value: Long) {
    val zz = (value shl 1) xor (value shr 63)
    writeVarint(zz)
}

fun writeTag(tag: Int, wireType: WireType) {
    writeVarint((tag.toLong() shl 3) or wireType.code.toLong())
}

inline fun writeLengthPrefixed(body: BinaryWriter.() -> Unit) {
    val inner = BinaryWriter()
    inner.body()
    val payload = inner.toByteArray()
    writeVarint(payload.size.toLong())
    writeBytes(payload)
}
```

Add to `BinaryReader`:

```kotlin
fun readVarint(): Long {
    var result = 0L
    var shift = 0
    repeat(10) {
        val byte = readU8()
        result = result or ((byte and 0x7F).toLong() shl shift)
        if (byte and 0x80 == 0) return result
        shift += 7
    }
    throw WireFormatException.VarintOverflow()
}

fun readZigZagVarint(): Long {
    val zz = readVarint()
    return (zz ushr 1) xor -(zz and 1L)
}

fun readTag(): Pair<Int, WireType> {
    val raw = readVarint()
    val wt = WireType.fromCode((raw and 0b111L).toInt())
    val tag = (raw ushr 3).toInt()
    return tag to wt
}

inline fun <R> readLengthPrefixed(body: (BinaryReader) -> R): R {
    val len = readVarint().toInt()
    val slice = readBytes(len)
    return body(BinaryReader(slice))
}

fun skipUnknownField(wireType: WireType) {
    when (wireType) {
        WireType.VARINT -> readVarint()
        WireType.FIXED64 -> readBytes(8)
        WireType.LENGTH_DELIMITED -> readLengthPrefixed { /* discard */ }
        WireType.FIXED32 -> readBytes(4)
    }
}
```

(If method names like `writeU8`/`readU8`/`readBytes`/`toByteArray`/`writeBytes` differ in the ported file, adapt.)

Run: `./gradlew :runtime:test`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add kotlin/runtime
git commit -m "Phase 2.2: TLV runtime primitives (Kotlin) — mirror of Swift Task 2.1"
```

---

### Task 2.3: Migrate `@WireFormat` macro to TLV with implicit tags

The struct macro currently emits positional encoding (each property encoded in declaration order, no tag, no length). After this task it emits TLV: each property is preceded by `writeTag(tag: N, wireType: WT)` and decoded via a `while` loop dispatching on `(tag, wireType)` from `readTag()`. Implicit tags = `1, 2, 3, …` in declaration order; explicit `@WireFormatField(tag:)` (Task 2.6) overrides.

This task lays down TLV for the **implicit-tag case only**. Explicit-tag + reservedTags arrive in Task 2.6.

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatMacro.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/Conformances.swift` (built-in conformances must emit/consume the new wire-type-aware payload encoding)
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletMacrosTests/` (new test target — author from scratch since the legacy module had none)
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletMacrosTests/WireFormatMacroExpansionTests.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Package.swift` (add WireletMacrosTests target)

- [ ] **Step 1: Add `WireletMacrosTests` target**

```swift
.testTarget(
    name: "WireletMacrosTests",
    dependencies: [
        "WireletMacros",
        "Wirelet",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
    ]
),
```

- [ ] **Step 2: Define the TLV encoding contract for built-in scalar types**

Each `WireFormatEncodable` conformance now reports a `wireType` and uses payload writers — NOT raw bytes. Edit `Conformances.swift` to:

For `UInt8/16/32/64`:
```swift
extension UInt32: WireFormat {
    public static var wireType: WireType { .varint }
    public func encodePayload(into writer: inout WireFormatWriter) {
        writer.writeVarint(UInt64(self))
    }
    public init(decodingPayload reader: inout WireFormatReader) throws {
        self = UInt32(try reader.readVarint())
    }
    // Back-compat positional API kept for nested-struct write through length-prefix
    public func encode(into writer: inout WireFormatWriter) { encodePayload(into: &writer) }
    public init(from reader: inout WireFormatReader) throws { try self.init(decodingPayload: &reader) }
}
```

Repeat the pattern for the full primitive set per the spec wire-format table (`Int*` use `writeZigZagVarint`, `Float` uses `appendInteger` little-endian 4 bytes / `wireType: .fixed32`, `Double` 8 bytes / `.fixed64`, `Bool` varint of 0/1, `String` length-prefixed UTF-8 / `.lengthDelimited`).

Add the protocol additions to `WireFormat.swift`:
```swift
public protocol WireFormatEncodable {
    static var wireType: WireType { get }
    func encodePayload(into writer: inout WireFormatWriter)
    func encode(into writer: inout WireFormatWriter)  // legacy / nested
}
public protocol WireFormatDecodable {
    init(decodingPayload reader: inout WireFormatReader) throws
    init(from reader: inout WireFormatReader) throws
}
```

For a nested `@WireFormat` struct, `wireType` = `.lengthDelimited`, `encodePayload` writes the body bytes (the macro emits this), and `encode(into:)` writes `writeLengthPrefixed { encodePayload(into: $0) }`.

- [ ] **Step 3: Write the expansion test (failing)**

`WireFormatMacroExpansionTests.swift`:
```swift
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import WireletMacros

@Test func emptyStructExpansion() {
    assertMacroExpansion(
        """
        @WireFormat
        struct Empty {}
        """,
        expandedSource: """
        struct Empty {}

        extension Empty: WireFormatEncodable, WireFormatDecodable {
            public static var wireType: WireType { .lengthDelimited }

            public func encodePayload(into writer: inout WireFormatWriter) {
            }

            public func encode(into writer: inout WireFormatWriter) {
                writer.writeLengthPrefixed { inner in
                    encodePayload(into: &inner)
                }
            }

            public init(decodingPayload reader: inout WireFormatReader) throws {
            }

            public init(from reader: inout WireFormatReader) throws {
                try reader.readLengthPrefixed { inner in
                    try self.init(decodingPayload: &inner)
                }
            }
        }
        """,
        macros: ["WireFormat": WireFormatMacro.self]
    )
}

@Test func singleFieldTaggedExpansion() {
    assertMacroExpansion(
        """
        @WireFormat
        struct Point { var x: Int32 }
        """,
        expandedSource: """
        struct Point { var x: Int32 }

        extension Point: WireFormatEncodable, WireFormatDecodable {
            public static var wireType: WireType { .lengthDelimited }

            public func encodePayload(into writer: inout WireFormatWriter) {
                writer.writeTag(tag: 1, wireType: Int32.wireType)
                x.encodePayload(into: &writer)
            }

            public func encode(into writer: inout WireFormatWriter) {
                writer.writeLengthPrefixed { inner in
                    encodePayload(into: &inner)
                }
            }

            public init(decodingPayload reader: inout WireFormatReader) throws {
                var _x: Int32? = nil
                while !reader.isAtEnd {
                    let (tag, wt) = try reader.readTag()
                    switch tag {
                    case 1: _x = try Int32(decodingPayload: &reader)
                    default: try reader.skipUnknownField(wireType: wt)
                    }
                }
                guard let _x else { throw WireFormatError.unknownTag(tag: 1, wireType: .varint) }
                self.x = _x
            }

            public init(from reader: inout WireFormatReader) throws {
                try reader.readLengthPrefixed { inner in
                    try self.init(decodingPayload: &inner)
                }
            }
        }
        """,
        macros: ["WireFormat": WireFormatMacro.self]
    )
}
```

Run: `swift test --filter WireletMacrosTests`
Expected: fails (macro still emits old positional code).

- [ ] **Step 4: Rewrite `WireFormatMacro.swift` to emit TLV**

Logic:
1. Walk the struct's stored properties in declaration order.
2. Assign implicit tag = previous tag + 1, starting at 1.
3. Emit `extension { static var wireType: .lengthDelimited; encodePayload writes each field tag+payload; encode wraps in writeLengthPrefixed; init(decodingPayload:) loops reading tags into per-field temporaries, then assembles self; init(from:) wraps in readLengthPrefixed }`.
4. For missing required fields after the loop, throw `WireFormatError.unknownTag(tag: <tag>, wireType: <expected>)` (re-using the existing error; later we can introduce a `.missingRequiredField` case in a polish pass — out of scope here).

Iterate Step 3 → Step 4 until tests pass.

- [ ] **Step 5: Add an integration round-trip test**

In `Tests/WireletRuntimeTests/`:

```swift
@Test func macroGeneratedRoundTrip() throws {
    @WireFormat
    struct Point { var x: Int32; var y: Int32 }

    let original = Point(x: -5, y: 17)
    let data = original.encodeToData()
    let decoded = try Point(decoding: data)
    #expect(decoded.x == -5)
    #expect(decoded.y == 17)
}
```

(Top-level macros can be applied to nested types inside test functions in Swift 6.x; if not, hoist to file scope.)

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git add Sources/Wirelet Sources/WireletMacros Tests/WireletMacrosTests Tests/WireletRuntimeTests Package.swift
git commit -m "Phase 2.3: @WireFormat emits TLV (implicit tags 1..N, length-prefixed body)"
```

---

### Task 2.4: Migrate `@WireFormatEnum` to TLV

`@WireFormatEnum` previously emitted a single `UInt8` ordinal. Under TLV, the macro emits a value whose `wireType` matches the raw type's wire type (`varint` for integer rawValues, `lengthDelimited` for `String` rawValues). The raw value is the **payload** at a parent's tagged field; the macro doesn't emit a tag itself.

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatEnumMacro.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletMacrosTests/`

- [ ] **Step 1: Write the failing expansion test**

```swift
@Test func wireFormatEnumExpansion() {
    assertMacroExpansion(
        """
        @WireFormatEnum
        enum Color: UInt8, CaseIterable, Equatable { case red, green, blue }
        """,
        expandedSource: """
        enum Color: UInt8, CaseIterable, Equatable { case red, green, blue }

        extension Color: WireFormatEncodable, WireFormatDecodable {
            public static var wireType: WireType { UInt8.wireType }

            public func encodePayload(into writer: inout WireFormatWriter) {
                rawValue.encodePayload(into: &writer)
            }

            public init(decodingPayload reader: inout WireFormatReader) throws {
                let raw = try UInt8(decodingPayload: &reader)
                guard let v = Color(rawValue: raw) else {
                    throw WireFormatError.invalidCount(Int32(raw))
                }
                self = v
            }

            public func encode(into writer: inout WireFormatWriter) { encodePayload(into: &writer) }
            public init(from reader: inout WireFormatReader) throws { try self.init(decodingPayload: &reader) }
        }
        """,
        macros: ["WireFormatEnum": WireFormatEnumMacro.self]
    )
}
```

- [ ] **Step 2: Update `WireFormatEnumMacro.swift`**

Extract raw type from the enum declaration's inheritance clause. Emit `wireType` = `<RawType>.wireType`. `encodePayload` = forward to `rawValue.encodePayload`. `init(decodingPayload:)` = decode raw, lookup, error on miss.

Run: `swift test --filter WireletMacrosTests/wireFormatEnumExpansion`
Expected: passes.

- [ ] **Step 3: Round-trip integration test**

```swift
@Test func enumRoundTrip() throws {
    @WireFormatEnum
    enum Color: UInt8, CaseIterable, Equatable { case red, green, blue }

    for c in Color.allCases {
        var w = WireFormatWriter()
        c.encodePayload(into: &w)
        var r = WireFormatReader(data: w.data)
        try #expect(Color(decodingPayload: &r) == c)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git commit -am "Phase 2.4: @WireFormatEnum emits raw-type wireType (varint or length-delimited)"
```

---

### Task 2.5: Migrate `@WireFormatChoice` to TLV

A choice value is itself length-delimited. Its payload is: `<varint discriminator> <TLV fields of selected case's associated values, tagged 1..N in declaration order>`.

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatChoiceMacro.swift`
- Modify: `Tests/WireletMacrosTests/`

- [ ] **Step 1: Failing expansion test**

```swift
@Test func choiceExpansion() {
    assertMacroExpansion(
        """
        @WireFormatChoice
        enum Shape {
            case point(Int32, Int32)
            case label(String)
        }
        """,
        // expected source omitted for brevity in this plan, but the test
        // must spell out the full expected expansion. Author the expected
        // text by reading the macro's current output once and then
        // hand-editing to TLV form.
        expandedSource: """
        // ... full TLV-form expansion ...
        """,
        macros: ["WireFormatChoice": WireFormatChoiceMacro.self]
    )
}
```

Action item for the implementer: capture current expansion (`swift test -v`) before editing the macro, derive the target expansion by transforming positional → TLV form, paste into `expandedSource`.

- [ ] **Step 2: Update the macro**

`encodePayload`:
- `writer.writeVarint(UInt64(discriminator))` (no tag — the choice's parent tagged the whole length-delimited blob; inside, the discriminator is the first thing).
- For each associated value in the selected case, `writer.writeTag(tag: i+1, wireType: V.wireType); v.encodePayload(into: &writer)`.

`init(decodingPayload:)`:
- Read varint discriminator.
- Switch on discriminator. For each case, loop reading tags into per-associated-value temporaries (like the struct path), assemble the case.
- Unknown discriminator → throw `.unknownChoiceDiscriminator(disc)`.

- [ ] **Step 3: Round-trip integration test**

Cover at least: a case with two `Int32` args, a case with a `String` arg, a case with no args.

- [ ] **Step 4: Commit**

```bash
git commit -am "Phase 2.5: @WireFormatChoice emits TLV (varint discriminator + tagged payload)"
```

---

### Task 2.6: `@WireFormatField(tag:)` + `reservedTags:` macro argument

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/WireFormat.swift` (declare `@WireFormatField` peer-attached macro + new `WireFormat(reservedTags:)` overload)
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/Plugin.swift` (register `WireFormatFieldMacro`)
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatFieldMacro.swift` (a no-op marker macro; tag is extracted by the struct macro via attribute scanning)
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatMacro.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatDiagnostic.swift` (add `tagConflict`, `reservedTagUsed`, `tagOutOfRange`)
- Modify: `Tests/WireletMacrosTests/`

- [ ] **Step 1: Add the field-marker macro declaration**

In `WireFormat.swift`:
```swift
@attached(peer)
public macro WireFormatField(tag: UInt32) = #externalMacro(
    module: "WireletMacros",
    type: "WireFormatFieldMacro"
)
```

And the overload:
```swift
@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encodePayload(into:)), named(init(decodingPayload:)),
          named(encode(into:)), named(init(from:)),
          named(wireType)
)
public macro WireFormat(reservedTags: [UInt32]) = #externalMacro(
    module: "WireletMacros",
    type: "WireFormatMacro"
)

// Combined overload kotlin: + reservedTags:
@attached(extension, conformances: WireFormatEncodable, WireFormatDecodable, names: ...)
public macro WireFormat(reservedTags: [UInt32], kotlin: KotlinTarget) = #externalMacro(...)
```

- [ ] **Step 2: `WireFormatFieldMacro` is a no-op peer macro**

```swift
import SwiftSyntax
import SwiftSyntaxMacros

public struct WireFormatFieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Pure marker — the struct macro reads tag arg directly.
        return []
    }
}
```

Register in `Plugin.swift`.

- [ ] **Step 3: Update `WireFormatMacro` to honor explicit tags + reservedTags**

Algorithm (mirrors spec):
1. Parse `reservedTags: [UInt32]` from the attribute arguments if present.
2. Walk stored properties; for each property, look for an attribute `@WireFormatField(tag: N)`.
3. Maintain a "next implicit tag" counter starting at 1. When a property has an explicit tag E: assign E, mark E as used, set the counter to `max(counter, E + 1)`. When implicit: assign the counter (skipping any value already used or reserved), increment.
4. Validate: every explicit tag must be `> 0`; explicit tags must not collide with reserved; explicit tags must not collide with each other. Diagnose via `WireFormatDiagnostic`.

- [ ] **Step 4: Diagnostic tests**

```swift
@Test func reservedTagRejected() {
    assertMacroExpansion(
        """
        @WireFormat(reservedTags: [3])
        struct Foo {
            @WireFormatField(tag: 3) var name: String
        }
        """,
        expandedSource: "...",  // unchanged source (failure case)
        diagnostics: [
            DiagnosticSpec(
                message: "Tag 3 is reserved and cannot be used by field 'name'",
                line: 3, column: 5, severity: .error
            )
        ],
        macros: ["WireFormat": WireFormatMacro.self, "WireFormatField": WireFormatFieldMacro.self]
    )
}

@Test func tagConflictRejected() {
    assertMacroExpansion(
        """
        @WireFormat
        struct Foo {
            @WireFormatField(tag: 5) var a: Int
            @WireFormatField(tag: 5) var b: Int
        }
        """,
        ...
        diagnostics: [DiagnosticSpec(message: "Tag 5 is used by multiple fields", ...)]
    )
}

@Test func implicitTagSkipsExplicit() {
    assertMacroExpansion(
        """
        @WireFormat
        struct Foo {
            var a: Int                                  // implicit tag 1
            @WireFormatField(tag: 7) var b: Int         // explicit 7
            var c: Int                                  // implicit tag 8
        }
        """,
        expandedSource: "/* expansion shows tags 1, 7, 8 */",
        macros: ...
    )
}
```

- [ ] **Step 5: Commit**

```bash
git commit -am "Phase 2.6: @WireFormatField(tag:) + @WireFormat(reservedTags:) + tag-conflict diagnostics"
```

---

### Task 2.7: `Optional<T>` support

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/Conformances.swift` (extend `Optional` where `Wrapped: WireFormat`)
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatMacro.swift` (detect Optional fields; skip tag emission on `nil`; relax "required" check on decode)
- Tests in `Tests/WireletMacrosTests/`, `Tests/WireletRuntimeTests/`

Spec: "Absence on the wire = nil; no presence byte."

- [ ] **Step 1: Failing round-trip test**

```swift
@Test func optionalFieldsAbsentDecodeAsNil() throws {
    @WireFormat
    struct Foo { var a: Int32; var b: Int32? }

    let v = Foo(a: 5, b: nil)
    let data = v.encodeToData()
    let decoded = try Foo(decoding: data)
    #expect(decoded.a == 5)
    #expect(decoded.b == nil)
}

@Test func optionalFieldsPresentRoundTrip() throws {
    @WireFormat
    struct Foo { var a: Int32; var b: Int32? }

    let v = Foo(a: 5, b: 42)
    let decoded = try Foo(decoding: v.encodeToData())
    #expect(decoded.b == 42)
}
```

Run: fails.

- [ ] **Step 2: Update the macro to detect `T?` (sugar for `Optional<T>`) and `Optional<T>`**

When emitting `encodePayload` for an optional field: wrap in `if let v = self.name { writer.writeTag(...); v.encodePayload(...) }`. When emitting `init(decodingPayload:)`: declare the temporary as `Optional<T>` already (`var _name: T? = nil`); after the loop, **do not** treat missing optionals as an error — assign directly.

This requires the macro to introspect property types syntactically for the suffix `?` or the prefix `Optional<`. Both forms appear in the wild; cover both.

- [ ] **Step 3: Forward-compat test**

Spec calls out `T → Optional<T>` as a safe evolution. Test: encode with `struct V1 { var a: Int32 }`, decode with `struct V2 { var a: Int32; var b: Int32? }`, expect `b == nil`.

- [ ] **Step 4: Commit**

```bash
git commit -am "Phase 2.7: Optional<T> support (absence = nil; no presence byte)"
```

---

### Task 2.8: `Data` / `[UInt8]` support

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/Conformances.swift`
- Modify Kotlin emitter to map `Data` / `[UInt8]` → `ByteArray`
- Tests

- [ ] **Step 1: Failing test**

```swift
@Test func dataFieldRoundTrip() throws {
    @WireFormat
    struct Blob { var name: String; var bytes: Data }

    let v = Blob(name: "hello", bytes: Data([0x01, 0x02, 0x03]))
    let decoded = try Blob(decoding: v.encodeToData())
    #expect(decoded.bytes == Data([0x01, 0x02, 0x03]))
}
```

- [ ] **Step 2: Add `Data: WireFormat` conformance**

```swift
extension Data: WireFormat {
    public static var wireType: WireType { .lengthDelimited }
    public func encodePayload(into writer: inout WireFormatWriter) {
        writer.writeVarint(UInt64(count))
        writer.appendBytes(self)
    }
    public init(decodingPayload reader: inout WireFormatReader) throws {
        let len = Int(try reader.readVarint())
        self = Data(try reader.readBytes(count: len))
    }
    public func encode(into writer: inout WireFormatWriter) { encodePayload(into: &writer) }
    public init(from reader: inout WireFormatReader) throws { try self.init(decodingPayload: &reader) }
}
```

Same for `[UInt8]` (encode/decode as `Data` round-trip).

- [ ] **Step 3: Kotlin emitter — map `Data` → `ByteArray`**

Edit `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter/Internal/KotlinTypeMap.swift`:
```swift
case "Data", "[UInt8]": return "ByteArray"
```

Add a Kotlin-side test in `kotlin/runtime/src/test/` that decodes a `.bin` fixture produced by the Swift encoder (cross-roundtrip; will be wired up in Task 2.13/2.14).

- [ ] **Step 4: Commit**

```bash
git commit -am "Phase 2.8: Data / [UInt8] support (length-delimited wire type)"
```

---

### Task 2.9: `Dictionary<K, V>` / `Map<K, V>` support

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/Wirelet/Conformances.swift`
- Modify: Kotlin emitter to map `[K: V]` → `Map<K, V>`
- Tests

Wire layout (per spec): varint payload length, then varint count, then `(K, V)` pairs each encoded as `<K payload> <V payload>` (no inner tags). Iteration order canonicalized by **sorting entries by encoded-key bytes** so cross-language conformance round-trips byte-equal.

- [ ] **Step 1: Failing test**

```swift
@Test func dictionaryRoundTrip() throws {
    @WireFormat
    struct WithDict { var m: [String: Int32] }

    let v = WithDict(m: ["a": 1, "b": 2, "c": 3])
    let decoded = try WithDict(decoding: v.encodeToData())
    #expect(decoded.m == ["a": 1, "b": 2, "c": 3])
}

@Test func dictionaryCanonicalKeyOrder() {
    let v: [String: Int32] = ["banana": 2, "apple": 1]
    var w1 = WireFormatWriter(); v.encodePayload(into: &w1)
    var w2 = WireFormatWriter(); ["apple": 1, "banana": 2].encodePayload(into: &w2)
    #expect(w1.data == w2.data)  // canonical, insertion-order-independent
}
```

- [ ] **Step 2: Add `Dictionary` conformance with sort-by-encoded-key**

```swift
extension Dictionary: WireFormatEncodable where Key: WireFormat & Comparable, Value: WireFormat {
    public static var wireType: WireType { .lengthDelimited }
    public func encodePayload(into writer: inout WireFormatWriter) {
        var inner = WireFormatWriter()
        let sortedEntries = sorted { lhs, rhs in
            var lw = WireFormatWriter(); lhs.key.encodePayload(into: &lw)
            var rw = WireFormatWriter(); rhs.key.encodePayload(into: &rw)
            return lw.data.lexicographicallyPrecedes(rw.data)
        }
        inner.writeVarint(UInt64(sortedEntries.count))
        for (k, v) in sortedEntries {
            k.encodePayload(into: &inner)
            v.encodePayload(into: &inner)
        }
        writer.writeVarint(UInt64(inner.data.count))
        writer.appendBytes(inner.data)
    }
    // encode / from delegate to encodePayload
}

extension Dictionary: WireFormatDecodable where Key: WireFormat & Hashable, Value: WireFormat {
    public init(decodingPayload reader: inout WireFormatReader) throws {
        try reader.readLengthPrefixed { inner in
            let count = Int(try inner.readVarint())
            var dict: [Key: Value] = [:]
            dict.reserveCapacity(count)
            for _ in 0..<count {
                let k = try Key(decodingPayload: &inner)
                let v = try Value(decodingPayload: &inner)
                dict[k] = v
            }
            self = dict
        }
    }
    // from delegates
}
```

The `Comparable` requirement on the encoding side is only used for tie-breaking when encoded-key bytes happen to match (which they shouldn't for canonical types, but defensive). If `Key` is not `Comparable`, the user can wrap; document this in the spec doc.

- [ ] **Step 3: Update Kotlin emitter map**

`KotlinTypeMap.swift`: `case let .dictionary(k, v): return "Map<\(map(k)), \(map(v))>"`

- [ ] **Step 4: Commit**

```bash
git commit -am "Phase 2.9: Dictionary / Map support (canonical sort by encoded-key bytes)"
```

---

### Task 2.10: Kotlin emitter — generate TLV-aware codecs

The Swift macros now emit TLV. The Kotlin emitter must do the same for the generated codecs so that Kotlin decoders interoperate. Audit `Internal/StructEmitter.swift`, `Internal/ChoiceEmitter.swift`, `Internal/EnumEmitter.swift`.

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletKotlinEmitter/Internal/StructEmitter.swift`
- Modify: `Internal/ChoiceEmitter.swift`
- Modify: `Internal/EnumEmitter.swift`
- Modify: `Internal/KotlinTypeMap.swift` (add `Optional` / `Data` / `Dictionary` mappings)
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/WireletKotlinEmitterTests/Fixtures/*.expected.kt`
- Modify: `Tests/WireletSchemaTests/` if any schema-level changes are needed (e.g. Schema model needs `tag: UInt32?` per field)

- [ ] **Step 1: Extend `WireField` in `WireletSchema/Schema.swift`**

Add `let tag: UInt32` (computed by parser from `@WireFormatField` attributes + implicit assignment) and `let isOptional: Bool`. Add Schema-level `let reservedTags: [UInt32]` on `WireStruct`.

- [ ] **Step 2: Update `SchemaParser` to extract tags**

Mirror the macro's tag-assignment algorithm (it's the same logic). Output: every `WireField` has a deterministic `tag`.

Test: extend `Tests/WireletSchemaTests/SchemaParserTests.swift` with cases covering implicit / explicit / reserved.

- [ ] **Step 3: Update Struct/Choice/Enum emitters to emit TLV Kotlin**

Per-struct codec:
```kotlin
object PointCodec {
    fun encode(value: Point, writer: BinaryWriter) {
        writer.writeLengthPrefixed {
            writeTag(1, WireType.VARINT); writeZigZagVarint(value.x.toLong())
            writeTag(2, WireType.VARINT); writeZigZagVarint(value.y.toLong())
        }
    }

    fun decode(reader: BinaryReader): Point {
        return reader.readLengthPrefixed { inner ->
            var x: Int? = null; var y: Int? = null
            while (!inner.isAtEnd) {
                val (tag, wt) = inner.readTag()
                when (tag) {
                    1 -> x = inner.readZigZagVarint().toInt()
                    2 -> y = inner.readZigZagVarint().toInt()
                    else -> inner.skipUnknownField(wt)
                }
            }
            Point(
                x = x ?: throw WireFormatException.UnknownTag(1, WireType.VARINT),
                y = y ?: throw WireFormatException.UnknownTag(2, WireType.VARINT),
            )
        }
    }
}
```

Choice / raw-enum follow analogously.

- [ ] **Step 4: Regenerate golden fixtures**

For each `.expected.kt` file under `Tests/WireletKotlinEmitterTests/Fixtures/`, the new TLV-form output replaces the old positional output. Hand-edit each golden to match the new emitter, then run:

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
swift test --filter WireletKotlinEmitterTests
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git commit -am "Phase 2.10: Kotlin emitter generates TLV-form codecs (matches Swift macro output)"
```

---

### Task 2.11: Macro diagnostic polish

Audit `WireFormatDiagnostic.swift` and add friendly messages for known misuse cases. Each diagnostic has a test in `WireletMacrosTests`.

**Coverage list (from spec §Open questions / common pitfalls — spec defers to plan, so we enumerate):**

1. Non-struct target for `@WireFormat` (existing).
2. Non-`CaseIterable` enum for `@WireFormatEnum` (existing).
3. `@WireFormatChoice` on enum without associated values (warn / suggest `@WireFormatEnum`).
4. Stored property with unsupported type (e.g. `CGFloat`) — list supported scalar types.
5. Computed property carrying `@WireFormatField` (ignored, with note).
6. Reserved-tag use in field (Task 2.6 already covers).
7. Explicit-tag conflict between two fields (Task 2.6 covers).
8. Explicit tag = 0 (reserved per protobuf convention; reject).
9. `@WireFormatField(tag:)` on a property in a type without `@WireFormat` (orphan; warn).
10. `@WireFormatChoice` with > 2^31 cases (effectively unreachable, but the macro shouldn't panic).

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Sources/WireletMacros/WireFormatDiagnostic.swift`
- Modify: each macro file to emit appropriate diagnostics
- Modify: `Tests/WireletMacrosTests/DiagnosticTests.swift` (new file)

- [ ] **Step 1: Author `DiagnosticTests.swift` with one `@Test` per item in the coverage list**

Use `assertMacroExpansion` with `diagnostics: [DiagnosticSpec(...)]`. Make all 10 tests fail first by writing only the test file.

Run: `swift test --filter WireletMacrosTests/DiagnosticTests`
Expected: 10 failures.

- [ ] **Step 2: Implement diagnostics one-by-one until all 10 pass**

Each diagnostic message follows the form: `"<actor> <verb> <object>: <suggestion>"`, e.g. `"@WireFormatField(tag: 5) is unused: enclose Foo in @WireFormat to make it take effect"`.

- [ ] **Step 3: Commit**

```bash
git commit -am "Phase 2.11: macro diagnostic coverage for 10 misuse cases"
```

---

### Task 2.12: Write `docs/wire-format-spec.md`

**Files:**
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/docs/wire-format-spec.md`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/docs/schema-evolution.md`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/docs/getting-started-swift.md`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/docs/getting-started-kotlin.md`

- [ ] **Step 1: Author `wire-format-spec.md`**

Sections (copy structure from spec §"Wire format design"):
- Overview (TLV format)
- Wire-type table (0/1/2/5)
- Skipping unknown fields
- Per-type encoding table (every type from spec)
- Tag varint encoding rules (low-3-bits wire-type)
- Length-prefixed body layout
- Dictionary canonical sort (sort by encoded-key bytes; tie-break by `Comparable` if available, lexicographic otherwise)
- Choice payload format (varint discriminator + TLV fields)
- Field tag assignment rules (implicit 1..N, explicit overrides, reservedTags rejection)
- Worked example: encode `Point(x: -5, y: 17)` → annotated byte stream.

- [ ] **Step 2: Author `schema-evolution.md`**

Copy spec §"Schema evolution rules" table verbatim, add narrative examples for each row.

- [ ] **Step 3: Author `getting-started-swift.md`**

```markdown
# Getting started — Swift

## Install

```swift
dependencies: [
    .package(url: "git@github.com:jiyimeta/wirelet.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Wirelet", package: "wirelet")]),
]
```

## Declare a type

```swift
import Wirelet

@WireFormat
struct Point {
    var x: Int32
    var y: Int32
}
```

## Encode & decode

```swift
let p = Point(x: 1, y: 2)
let data = p.encodeToData()
let q = try Point(decoding: data)
```

## More

See [wire-format-spec.md](wire-format-spec.md) for the binary layout.
See [schema-evolution.md](schema-evolution.md) for safe vs breaking changes.
```

- [ ] **Step 4: Author `getting-started-kotlin.md`**

Symmetric to above but uses the Gradle plugin DSL (forward-reference to Phase 3) and the runtime jar. State explicitly: "until Phase 3 ships the plugin, run `swift run emit-wirelet-kotlin --source ... --output ...` manually from the wirelet checkout."

- [ ] **Step 5: Commit**

```bash
git commit -am "Phase 2.12: wire-format-spec + schema-evolution + getting-started docs"
```

---

### Task 2.13: Cross-roundtrip example

End-to-end demo: one Swift schema file, one Swift program that encodes a value, one Kotlin program that decodes the same bytes via the generated codec.

**Files:**
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/examples/cross-roundtrip/README.md`
- Create: `examples/cross-roundtrip/shared-schema/Sources/SharedSchema/Shared.swift`
- Create: `examples/cross-roundtrip/shared-schema/Package.swift`
- Create: `examples/cross-roundtrip/swift-encoder/Package.swift`
- Create: `examples/cross-roundtrip/swift-encoder/Sources/swift-encoder/main.swift`
- Create: `examples/cross-roundtrip/android-decoder/build.gradle.kts`
- Create: `examples/cross-roundtrip/android-decoder/src/main/kotlin/...Main.kt`

- [ ] **Step 1: Shared schema**

`shared-schema/Sources/SharedSchema/Shared.swift`:
```swift
import Wirelet

@WireFormat
public struct Message {
    public var id: Int32
    public var text: String
    public var tags: [String]
    public init(id: Int32, text: String, tags: [String]) {
        self.id = id; self.text = text; self.tags = tags
    }
}
```

`shared-schema/Package.swift` declares one library `SharedSchema` depending on `Wirelet` (via local relative path back to the wirelet root: `.package(path: "../../..")`).

- [ ] **Step 2: Swift encoder**

`swift-encoder/main.swift`:
```swift
import SharedSchema
import Foundation

let m = Message(id: 42, text: "hello", tags: ["a", "b"])
let data = m.encodeToData()
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try data.write(to: outURL)
print("Wrote \(data.count) bytes to \(outURL.path)")
```

- [ ] **Step 3: Android decoder**

`android-decoder` is a JVM (not Android) module to keep CI simple. Use Kotlin JVM + the wirelet runtime via `mavenLocal()`. The build runs the `emit-wirelet-kotlin` CLI against `../shared-schema/Sources/SharedSchema/Shared.swift` to generate `MessageCodec.kt`, then a `main` function loads the bytes and decodes.

`Main.kt`:
```kotlin
fun main(args: Array<String>) {
    val bytes = java.io.File(args[0]).readBytes()
    val msg = MessageCodec.decode(BinaryReader(bytes))
    println("id=${msg.id} text=${msg.text} tags=${msg.tags}")
    require(msg.id == 42 && msg.text == "hello" && msg.tags == listOf("a", "b"))
}
```

- [ ] **Step 4: Add a `verify.sh` smoke script**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Generate Kotlin codecs from shared schema
(cd ../.. && swift run emit-wirelet-kotlin \
    --source examples/cross-roundtrip/shared-schema/Sources/SharedSchema \
    --output examples/cross-roundtrip/android-decoder/build/generated/wirelet/kotlin \
    --include-package SharedSchema)

# Encode
(cd swift-encoder && swift run swift-encoder /tmp/wirelet-roundtrip.bin)

# Decode
(cd android-decoder && ./gradlew run --args /tmp/wirelet-roundtrip.bin)
```

Run it; expect "id=42 text=hello tags=[a, b]".

- [ ] **Step 5: Commit**

```bash
git commit -am "Phase 2.13: examples/cross-roundtrip end-to-end (Swift encoder + JVM decoder)"
```

---

### Task 2.14: Conformance fixtures (Swift + Kotlin)

The fixture suite makes wire-format regressions visible. Lay down the directory structure and seed it with five fixtures.

**Files:**
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/kotlin/conformance-tests/build.gradle.kts`
- Create: `kotlin/conformance-tests/fixtures/primitives_v1.bin` (binary)
- Create: `kotlin/conformance-tests/fixtures/primitives_v1.json`
- Create: `kotlin/conformance-tests/fixtures/optional_present_v1.bin` + `.json`
- Create: `kotlin/conformance-tests/fixtures/optional_absent_v1.bin` + `.json`
- Create: `kotlin/conformance-tests/fixtures/choice_v1.bin` + `.json`
- Create: `kotlin/conformance-tests/fixtures/forward_compat_v2_to_v1.bin` + `.json`
- Create: `kotlin/conformance-tests/src/test/kotlin/.../FixtureRunner.kt`
- Create: `/Users/kiichi/Developer/Personal/swift-packages/wirelet/Tests/ConformanceTests/FixtureRunner.swift`
- Modify: `Package.swift` (add `ConformanceTests` target with `.copy("../../kotlin/conformance-tests/fixtures")` resource)

- [ ] **Step 1: Define fixture schemas**

`Tests/ConformanceTests/FixtureSchemas.swift`:
```swift
import Wirelet

@WireFormat public struct Primitives {
    public var u32: UInt32; public var i32: Int32; public var f: Float; public var d: Double; public var s: String; public var b: Bool
}

@WireFormat public struct OptionalHolder {
    public var a: Int32; public var b: Int32?
}

@WireFormatChoice public enum ShapeChoice {
    case point(Int32, Int32)
    case label(String)
}
```

- [ ] **Step 2: Author a fixture generator**

`Tests/ConformanceTests/GenerateFixtures.swift` (an `@main` executable target or a `@Test` flagged with `.disabled` you enable to regenerate):

```swift
let prim = Primitives(u32: 7, i32: -3, f: 1.5, d: 2.25, s: "hi", b: true)
try prim.encodeToData().write(to: URL(fileURLWithPath: "kotlin/conformance-tests/fixtures/primitives_v1.bin"))
let primJSON = """
{"u32":7,"i32":-3,"f":1.5,"d":2.25,"s":"hi","b":true}
""".data(using: .utf8)!
try primJSON.write(to: URL(fileURLWithPath: "kotlin/conformance-tests/fixtures/primitives_v1.json"))
// Repeat for optional_present/absent, choice, forward_compat.
```

The forward-compat fixture is generated by a v2 schema with an extra trailing optional field; the v1 schema decodes successfully because trailing tags are skipped.

Run the generator once; commit the `.bin` + `.json` outputs.

- [ ] **Step 3: Swift-side runner**

`Tests/ConformanceTests/FixtureRunner.swift`:
```swift
@Test func primitivesFixtureDecodes() throws {
    let bin = try Data(contentsOf: fixturesURL.appendingPathComponent("primitives_v1.bin"))
    let v = try Primitives(decoding: bin)
    #expect(v.u32 == 7)
    #expect(v.i32 == -3)
    // ...
    let reencoded = v.encodeToData()
    #expect(reencoded == bin)  // canonical
}
```

One `@Test` per fixture.

- [ ] **Step 4: Kotlin-side runner**

`kotlin/conformance-tests/src/test/kotlin/io/github/jiyimeta/wirelet/conformance/FixtureRunner.kt`:

```kotlin
class FixtureRunner {
    @Test fun primitives() {
        val bytes = File("fixtures/primitives_v1.bin").readBytes()
        val v = PrimitivesCodec.decode(BinaryReader(bytes))
        assertEquals(7, v.u32)
        // ...
        val reencoded = BinaryWriter().also { PrimitivesCodec.encode(v, it) }.toByteArray()
        assertContentEquals(bytes, reencoded)
    }
}
```

The generated `PrimitivesCodec.kt` etc. are produced by running `emit-wirelet-kotlin` against `Tests/ConformanceTests/FixtureSchemas.swift` and dropping the output into `kotlin/conformance-tests/src/main/kotlin/`. Wire this as a Gradle task.

- [ ] **Step 5: CI dry-run (manual)**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
swift test --filter ConformanceTests
cd kotlin && ./gradlew :conformance-tests:test
```

Both green.

- [ ] **Step 6: Document the fixture-update workflow**

Add to `docs/wire-format-spec.md`:
> **Updating fixtures.** Any change to the wire format requires deliberately regenerating fixtures: enable the `@Test`-disabled `regenerateFixtures()` driver in `Tests/ConformanceTests/GenerateFixtures.swift`, commit the new `.bin` files in the same PR as the format change, and update `docs/wire-format-spec.md` to bump the implied format-version note.

- [ ] **Step 7: Commit**

```bash
git commit -am "Phase 2.14: conformance fixtures + Swift + Kotlin runners"
```

---

## Phase 2 wrap-up

### Task 2.15: Tag the milestone and verify

- [ ] **Step 1: Run full test matrix**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
swift test
cd kotlin && ./gradlew test
```

Both green.

- [ ] **Step 2: Build all examples**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet/examples/cross-roundtrip
bash verify.sh
```

Output ends with `id=42 text=hello tags=[a, b]`.

- [ ] **Step 3: Confirm swift-sheet-music untouched**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/wirelet-extraction
git status
git log -1 --oneline
```

No source/test changes to swift-sheet-music; only the plan file was touched (and its commit is the worktree's HEAD).

- [ ] **Step 4: Tag the milestone**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/wirelet
git tag phase-2-complete
```

Phase 3 (Gradle plugin) + Phase 4 (CI / publish) + Phase 5 (swift-sheet-music consumer-ization) are out of scope of this plan and tracked in subsequent plan files.

---

## Self-review checklist (for the plan author, not the implementer)

- Every Phase 0/1/2 spec item maps to a task: ✅ (0=Task 0.1; 1=Tasks 1.1–1.8; 2.A=2.7, 2.B=2.8, 2.C=2.9, 2.D+E=2.1–2.6+2.10, 2.F=2.11, 2.G=2.12, 2.H=2.13; conformance fixtures = 2.14).
- No `TBD` / `implement later` / `add appropriate error handling` placeholders.
- Type names consistent across tasks: `WireType`, `WireFormatError`, `WireletMacros`, `Wirelet`, `WireletSchema`, `WireletKotlinEmitter`, `EmitWireletKotlin`, `io.github.jiyimeta.wirelet`.
- Every task has explicit working directory paths (absolute), and the "do not touch swift-sheet-music sources" guardrail is repeated at Tasks 1.8 and 2.15.
- Implicit-tag algorithm definition appears in both Task 2.6 (macro side) and Task 2.10 Step 2 (schema parser side) and is identical.
