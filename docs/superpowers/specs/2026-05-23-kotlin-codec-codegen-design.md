# Kotlin codec codegen from Swift `@WireFormat` — design

Auto-generate Kotlin encoders/decoders from the Swift `@WireFormat`
family of macros, eliminating ~700 lines of hand-maintained mirror
codecs from the Android side. The generator is a build-time
component that runs from Gradle into a non-committed output directory.

## Background

After the swift-java full adoption (2026-05-22), the Swift ↔ Kotlin
JNI boundary is fully auto-generated; the remaining hand-written
boilerplate concentrates in **wire-format payload codecs on the
Kotlin side**:

- `Android/SheetMusicAudioAndroid/src/main/kotlin/.../audio/serialization/`
  — 12 files, 609 lines of decoders/encoders that mirror the Swift
  side's `@WireFormat` / `@WireFormatChoice` / `@WireFormatEnum`
  generated codecs byte-for-byte.
- `Android/SheetMusicAndroid/src/main/kotlin/.../ScoreMetadata.kt`
  — ~30 lines of inline `ByteBuffer` parsing for the
  `ScoreMetadataWire` payload.
- `Examples/Android/app/src/main/java/.../draw/DrawProgramDecoder.kt`
  — 123 lines decoding the `@WireFormatChoice`-driven DrawProgram
  payload.

Each time a wire format changes, both sides must be updated in lockstep,
and the only safety net is the per-codec Kotlin unit test catching a
byte-level disagreement after the fact. The Swift macro already knows
the schema at compile time — it's the input it expanded to generate
the Swift codec. Routing that same schema description into a Kotlin
emitter closes the loop.

## Goal

After this work:

- A new generic codegen library under `Sources/` parses Swift sources
  for `@WireFormat`-family annotations and emits a Kotlin source
  string per type.
- A standalone Swift executable (`emit-kotlin-codecs`) drives the
  parse → emit pipeline for a target Swift directory, writing `.kt`
  files into a caller-specified output directory.
- The Android Gradle build invokes `emit-kotlin-codecs` before
  `compileDebugKotlin`, with generated `.kt` landing under
  `<module>/build/generated/source/wire-format/` and being added to
  the relevant Kotlin source sets. Generated files are **not**
  committed to git.
- All current hand-written codecs in `audio/serialization/`,
  `ScoreMetadata.decode`, and `DrawProgramDecoder` are deleted and
  replaced by the generated equivalents.
- The existing Kotlin codec unit tests pass against the generated
  codecs with import-path changes only (codec class names and method
  signatures preserved; the test bodies stay byte-identical assertions).

## Non-goals

- **`BravuraMetricsBuilder` inline byte assembly.** The byte-packing
  loop inside `buildTable` is ~20 lines; the surrounding path-walking
  logic dominates. Migrating just the encoder portion is possible but
  marginal — defer indefinitely.
- **Wire format byte changes.** Codegen produces byte-identical
  output to the current hand-written codecs. Any wire format
  evolution is a separate concern.
- **Replacing the Swift `@WireFormat` macros.** The Swift codegen
  path is untouched; this work adds a *second* consumer of the same
  schema, side-by-side with the existing Swift macro expansion.
- **Sharing the schema parser with the Swift macros immediately.**
  The Swift macro can keep its own ad-hoc traversal; this spec only
  requires a new parser used by the Kotlin emitter. Unifying both
  consumers is a follow-up worth doing only if maintenance friction
  shows up.
- **Other JVM targets (server-side JVM, Java-only consumers).** The
  emitter targets Kotlin specifically; pure-Java emission is out of
  scope.

## Scope

In:

- New SwiftPM library targets: `WireFormatSchema` (SwiftSyntax →
  schema model) and `WireFormatKotlinEmitter` (schema + config →
  Kotlin source).
- New SwiftPM executable target: `emit-kotlin-codecs` (CLI binding
  the two).
- Add `kotlinType:` and `kotlinTarget:` arguments to
  `@WireFormat` / `@WireFormatChoice` / `@WireFormatEnum`. Default
  behaviour unchanged when arguments are absent.
- Per-target config file at
  `Sources/SheetMusicAndroidJNI/kotlin-codegen.json`. Add to the
  target's `exclude:` list in `Package.swift` so SwiftPM does not
  treat it as a resource (mirroring `swift-java.config`).
- Gradle integration in `Android/SheetMusicAudioAndroid`,
  `Android/SheetMusicAndroid`, and `Examples/Android/app` to run the
  CLI before Kotlin compilation.
- Deletion of hand-written codec files (Audio serialization module,
  inline ScoreMetadata decode, DrawProgramDecoder) and pointer updates
  at callers.

Out:

- `BravuraMetricsBuilder` (Non-goals).
- Apple-side build, iOS/macOS targets.
- swift-java JNI surface — untouched.
- ZIP wire format (`@WireFormatRandom` remains deferred per the
  prior spec).

## Architecture

```
Sources/
  SheetMusicWireFormatMacros/      (existing — augmented to accept
                                    new attribute arguments and pass
                                    them through unchanged)
  WireFormatSchema/                (NEW — SwiftSyntax-based parser.
                                    Pure library, no I/O. Produces a
                                    `Schema` value object: type list,
                                    fields, choice cases, enum cases,
                                    user-supplied attribute args.)
  WireFormatKotlinEmitter/         (NEW — schema + KotlinCodegenConfig
                                    → Kotlin source string per type.
                                    Pure library, no I/O.)
  EmitKotlinCodecs/                (NEW — executable target. Reads
                                    config JSON + scans target Swift
                                    dir, runs parser, runs emitter,
                                    writes .kt files.)
Sources/SheetMusicAndroidJNI/
  kotlin-codegen.json              (NEW — config for this module)
```

The data flow at codegen time:

```
Swift sources ──► WireFormatSchema.parse ──► Schema
                                              │
KotlinCodegenConfig (from JSON) ──────────────┤
                                              ▼
                              WireFormatKotlinEmitter.emit
                                              │
                                              ▼
                              <output>/<TypeName>Codec.kt
```

`KotlinCodegenConfig` (public API of the emitter):

```swift
public struct KotlinCodegenConfig {
    public var defaultModelPackage: String     // where the Kotlin data class lives
    public var defaultCodecPackage: String     // where the codec lands (may differ)
    public var nameTransform: NameTransform    // e.g. .stripSuffix("Wire")
    public var rules: [Rule]                   // pattern → per-type override
}
public struct Rule {
    public var pattern: String                 // glob, e.g. "Score*"
    public var modelPackage: String?           // nil → use default
    public var codecPackage: String?           // nil → use default
}
public enum NameTransform { case identity, stripSuffix(String) }
```

Model package and codec package are treated as independent because
the existing Kotlin layout has them as siblings
(`audio.model` / `audio.serialization`), not parent-child. Generated
codec files reference data classes via `import <modelPackage>.<Name>`
in their header.

Resolution order for a given `@WireFormat` type's Kotlin location:

1. `@WireFormat(kotlinType: "fully.qualified.Name")` override — use
   verbatim, skip config entirely.
2. `@WireFormat(kotlinTarget: .none)` — emit no Kotlin file for this
   type. Useful for Apple-only types that happen to use the macro.
3. Config `rules[]` pattern match (first hit wins) → model class
   placed at `(modelPackage ?? default) + transform(simpleName)`,
   codec placed at `(codecPackage ?? default) + transform(simpleName)
   + "Codec"` (or `…Decoder`/`…Encoder` per type — see Generated
   file layout).
4. Config defaults likewise.
5. No match and no default → CLI exits non-zero with an error
   identifying the unmapped type.

The opt-out is signalled in the macro source as
`@WireFormat(kotlinTarget: .none)`. The macros export a public enum
`KotlinTarget { case none }` in the runtime module
(`SheetMusicWireFormat`) so the literal `.none` resolves at parse
time. The schema parser recognises this attribute argument and marks
the type as skip-Kotlin.

### Generated file layout

For each `@WireFormat` type `FooWire` resolved to
`io.github.jiyimeta.sheetmusic.audio.model.Foo`, the emitter writes:

```
<output>/io/github/jiyimeta/sheetmusic/audio/model/FooCodec.kt
```

containing a single `internal object FooCodec` with `encode` /
`decode` / `encodePayload` / `decodePayload` matching the public API
shape currently used in `audio/serialization/`.

The generated file references model classes by name only — the
emitter does **not** generate the data classes themselves. The
existing hand-written Kotlin model types in `audio/model/` remain
the source of truth for Kotlin-side data shape.

### Gradle integration

Each consuming Gradle module declares a task:

```kotlin
val packageRoot = rootProject.projectDir.parentFile  // swift-sheet-music root
val emitKotlinCodecs by tasks.registering(Exec::class) {
    workingDir = packageRoot
    commandLine = listOf(
        "swift", "run", "--package-path", packageRoot.absolutePath,
        "emit-kotlin-codecs",
        "--config", "Sources/SheetMusicAndroidJNI/kotlin-codegen.json",
        "--source", "Sources/SheetMusicAndroidJNI",
        "--output", layout.buildDirectory.dir(
            "generated/source/wire-format/kotlin"
        ).get().asFile.absolutePath,
    )
}
android.sourceSets["main"].kotlin.srcDir(
    layout.buildDirectory.dir("generated/source/wire-format/kotlin")
)
tasks.named("preBuild").configure { dependsOn(emitKotlinCodecs) }
```

`packageRoot` resolution differs per module:
- `Android/SheetMusicAndroid/build.gradle.kts` → `../../..`
- `Android/SheetMusicAudioAndroid/build.gradle.kts` → `../../..`
- `Examples/Android/app/build.gradle.kts` → `../../..`

The plan documents the exact path expression once per module.

The CLI is idempotent and fast (parser walks Swift sources, no
network, no build). Output directory is wiped at the start of each
invocation to handle deletions/renames.

## Migration order

Three commits, two verification rounds:

1. **Toolchain commit.** Add `WireFormatSchema`,
   `WireFormatKotlinEmitter`, `EmitKotlinCodecs` targets. Add the
   new macro attribute arguments. Write the `kotlin-codegen.json`
   for `SheetMusicAndroidJNI`. **No deletions yet.** Verify
   `emit-kotlin-codecs` produces byte-identical output to two
   hand-written codecs (`MetronomeBeatCodec`, `StaffParamsCodec`)
   via a diff test in `Tests/EmitKotlinCodecsTests/`.
2. **Audio module migration.** Wire Gradle integration into
   `SheetMusicAudioAndroid`. Delete the 12 hand-written files under
   `audio/serialization/main/`. Confirm existing unit tests under
   `audio/serialization/test/` pass unchanged against generated
   codecs. Smoke-test Compose example app on Pixel 6 Pro API 36.
   Commit.
3. **SheetMusicAndroid + Examples/Android migration.** Wire Gradle
   integration into `SheetMusicAndroid` (replacing
   `ScoreMetadata.decode`) and `Examples/Android/app` (replacing
   `DrawProgramDecoder`). Confirm tests pass. Smoke-test Compose
   example. Commit.

## Technical risks (resolved during implementation)

These are the unknowns we enter implementation with. Each should
be front-loaded by an early experiment in its phase.

- **SwiftSyntax parsing without the macro plugin sandbox.** The
  existing macros run inside the SwiftSyntax plugin protocol; the
  new parser runs as a normal SwiftPM executable that imports
  `SwiftSyntax` directly. Resolution: spike during Step 1 by
  parsing one `@WireFormat` declaration and printing the schema.
  If SwiftSyntax in a non-plugin context has unexpected friction,
  fall back to running the parser as a swift-syntax-based
  `BuildToolPlugin` — same parser, different invocation.
- **`@WireFormatChoice` enum case payloads.** Sum types with
  associated values (`ScoreCursor`, `ScoreItemID`, `ClefAnchor`,
  `DrawCommand`, `AudioExportRange`) require emitting Kotlin
  sealed-class hierarchies. The emitter must consult the Kotlin
  model's existing shape — currently sealed `class` /
  `data class` nested. Resolution: emitter takes the case name
  verbatim from the Swift enum case; if the Kotlin sealed-class
  naming diverges, that's caller error and yields a compile error
  at Kotlin compile time, which surfaces it immediately.
- **Gradle composite build invoking swift toolchain.** Some CI
  environments may not have a Swift toolchain at the right path.
  Resolution: document the dependency in `Android/README.md` and
  fail fast with a clear error if `swift` is not on PATH. CI is
  not currently set up for the Android side, so this is a
  developer-machine concern only.
- **Incremental build correctness.** `emit-kotlin-codecs` will
  re-emit all files on every invocation; Gradle picks up file
  timestamp changes and recompiles even when nothing changed.
  Resolution: emitter compares each new file's contents to the
  on-disk version and skips the write if identical (preserves
  mtime). Cheap and fully avoids spurious recompiles.

## Verification

A phase is "done" when all of:

1. `swift test` — full host-platform Swift test suite green
   (includes new `WireFormatSchema` + `WireFormatKotlinEmitter` +
   `EmitKotlinCodecs` tests).
2. `./gradlew :SheetMusicAndroid:test :SheetMusicAudioAndroid:test`
   — Android library JVM unit tests green using generated codecs.
3. `./gradlew -p Examples/Android :app:testDebugUnitTest` — example
   app unit tests (including `DrawProgramDecoderTest`) green.
4. Compose example app installed on Pixel 6 Pro API 36 emulator,
   manual smoke: MIDI playback audible, score scrolls with cursor.
5. Byte-level diff test in `Tests/EmitKotlinCodecsTests/`
   confirms generated Kotlin produces the same bytes as a fixed
   reference output for every codec.

After Phase 3, the same checks gate the final merge.

## Open questions for the plan

The plan author resolves these during implementation:

- **Where does the executable live in the SwiftPM topology?**
  Standalone `Sources/EmitKotlinCodecs/` is the simplest option.
  Alternative: SwiftPM `BuildToolPlugin` driven by Gradle indirectly.
  Recommendation: standalone executable (simpler debugging,
  unambiguous CLI surface). Plan inspects what swift-java + Gradle
  expectations imply and confirms.
- **How does the parser discover Swift files?** Walk the
  `--source` directory recursively for `*.swift`, skipping
  `swift-java.config` and any `.build/` artifacts. Plan documents
  the exact filter.
- **Single-pass vs. two-pass emission for cross-type references?**
  When `@WireFormatChoice` references another `@WireFormat` type,
  the emitter needs the target's resolved Kotlin name. Plan
  decides between two-pass (build symbol table first, then emit) vs.
  on-demand (assume caller-provided name during emit, validate
  later). Recommendation: two-pass — symbol table is cheap and
  catches forward references cleanly.
- **What does the spike diff test compare against?** Either freeze
  a copy of the current hand-written codec under `Tests/Fixtures/`
  and diff against fresh emitter output, or generate the new
  output into a temp dir and diff against the live
  `audio/serialization/MetronomeBeatCodec.kt` file. Plan picks one.
