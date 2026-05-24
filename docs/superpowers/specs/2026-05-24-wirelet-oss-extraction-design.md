# Wirelet — OSS extraction of wire-format toolkit

**Status**: Spec (brainstorming complete, awaiting plan)
**Date**: 2026-05-24
**Author**: Kiichi Ito (with Claude)

## Purpose

Extract the `@WireFormat` macro family, the Swift-source schema parser, the Kotlin codec emitter, the Kotlin runtime, and a Gradle plugin from `swift-sheet-music` into a standalone repository, **`wirelet`**, so that the same toolkit can power both:

1. `swift-sheet-music` itself (current sole consumer).
2. The Android / iOS app(s) that consume `swift-sheet-music`, and any future cross-platform Swift+Kotlin project that needs a shared binary codec generated from a single Swift source of truth.

The toolkit ships as a single OSS project initially kept private on GitHub, opened up once the author judges it ready (criteria out of scope of this design).

## Non-goals

- A general-purpose protobuf/flatbuffers replacement. `wirelet` is intentionally smaller in scope: one Swift source → Swift + Kotlin codecs, opinionated for swift-java-style cross-runtime IPC.
- TypeScript / Rust / other emitters. The schema layer is designed to be language-pluggable so they can be added later, but only Kotlin ships in v0.1.
- Sonatype / Maven Central publishing. v0.1 uses GitHub Packages exclusively (same Path A pattern already in use for `sheet-music-android`).

## Naming

- Project / repo: **`wirelet`** (`github.com/jiyimeta/wirelet`).
- Swift package: `swift-wirelet` (SwiftPM convention).
- Kotlin Maven coordinates: `io.github.jiyimeta:wirelet-runtime`, `io.github.jiyimeta:wirelet-gradle-plugin`.
- Gradle plugin ID: `io.github.jiyimeta.wirelet`.
- README opens with a one-liner disambiguating from Square Wire (different problem, different mechanism — wirelet is Swift-macro-driven, not protobuf-driven).

Rationale: "wirelet" reads as a diminutive of "wire format" and signals the intended lightness next to protobuf / flatbuffers / capnproto. The only meaningful name collision (Packed.dev's internal Java class) is in an unrelated and unknown ecosystem.

## Repository layout

Single monorepo with both languages at known paths:

```
wirelet/                                    # GitHub repo root
├── Package.swift                           # SwiftPM at root (required)
├── README.md                               # tagline + Square-Wire disambiguation
├── LICENSE                                 # Apache-2.0 (matches swift-sheet-music)
├── CHANGELOG.md
├── docs/
│   ├── wire-format-spec.md                 # language-neutral binary spec
│   ├── getting-started-swift.md
│   ├── getting-started-kotlin.md
│   └── schema-evolution.md
├── Sources/                                # SwiftPM targets
│   ├── Wirelet/                            # runtime: BinaryReader/Writer + macro re-exports
│   ├── WireletMacros/                      # @WireFormat / @WireFormatEnum / @WireFormatChoice / @WireFormatField
│   ├── WireletSchema/                      # Swift source -> schema model
│   ├── WireletKotlinEmitter/               # schema -> Kotlin source
│   └── EmitWireletKotlin/                  # CLI: emit-wirelet-kotlin
├── Tests/
│   ├── WireletMacrosTests/
│   ├── WireletSchemaTests/
│   ├── WireletKotlinEmitterTests/
│   ├── EmitWireletKotlinTests/
│   └── ConformanceTests/                   # Swift side of cross-language fixtures
├── kotlin/                                 # Gradle root (independent build)
│   ├── settings.gradle.kts                 # rootProject.name = "wirelet"
│   ├── build.gradle.kts
│   ├── runtime/                            # :runtime → wirelet-runtime artifact
│   │   └── src/main/kotlin/io/github/jiyimeta/wirelet/
│   │       ├── BinaryReader.kt
│   │       └── BinaryWriter.kt
│   ├── gradle-plugin/                      # io.github.jiyimeta.wirelet plugin
│   │   └── src/main/kotlin/...
│   └── conformance-tests/                  # Kotlin side of cross-language fixtures
│       └── fixtures/                       # golden .bin + .json pairs
└── examples/
    ├── swift-standalone/                   # @WireFormat usage without SheetMusic
    ├── kotlin-standalone/                  # runtime usage direct
    └── cross-roundtrip/                    # Swift encoder + Android decoder
        ├── shared-schema/
        ├── swift-encoder/
        └── android-decoder/
```

Constraints honored:
- `Package.swift` must live at repo root (SwiftPM requirement; no `swift/` subdirectory).
- Kotlin lives under `kotlin/` to keep its `settings.gradle.kts` from colliding with SwiftPM tooling.
- Worktrees for `wirelet` itself will follow the same `.claude/worktrees/` convention as `swift-sheet-music`.

Physical location on disk: `~/Developer/Personal/swift-packages/wirelet/` (peer of `swift-sheet-music`).

## Phasing

Six phases, each ending in a working / committable state. Specs and plans for this initiative live in `swift-sheet-music/docs/superpowers/{specs,plans}/`, NOT in the new repo, even after extraction. Phases are presented in execution order; swift-sheet-music remains on its current in-tree copies of the toolkit through Phase 4 and switches to the OSS package in Phase 5.

### Phase 0 — repo init

- Create `~/Developer/Personal/swift-packages/wirelet/`, `git init`.
- Stub: `Package.swift` (empty target list), `kotlin/settings.gradle.kts`, `README.md` (placeholder), `LICENSE` (Apache-2.0).
- Push to `github.com/jiyimeta/wirelet` as a **private** repo.
- `swift-sheet-music` is untouched.

### Phase 1 — code port (existing functionality only)

Copy from `swift-sheet-music` into `wirelet`, renaming as we go:

| swift-sheet-music | wirelet |
|---|---|
| `Sources/SheetMusicWireFormatMacros/` | `Sources/WireletMacros/` |
| `Sources/SheetMusicWireFormat/` | `Sources/Wirelet/` |
| `Sources/WireFormatSchema/` | `Sources/WireletSchema/` |
| `Sources/WireFormatKotlinEmitter/` | `Sources/WireletKotlinEmitter/` |
| `Sources/EmitKotlinCodecs/` | `Sources/EmitWireletKotlin/` |
| `Tests/WireFormatSchemaTests/` | `Tests/WireletSchemaTests/` |
| `Tests/WireFormatKotlinEmitterTests/` | `Tests/WireletKotlinEmitterTests/` |
| `Tests/EmitKotlinCodecsTests/` | `Tests/EmitWireletKotlinTests/` |
| `Android/SheetMusicAndroid/.../io/github/jiyimeta/sheetmusic/wireformat/BinaryReader.kt` | `kotlin/runtime/.../io/github/jiyimeta/wirelet/BinaryReader.kt` |
| (same) `BinaryWriter.kt` | (same) `BinaryWriter.kt` |

Type-level renames inside the moved code:
- Macro names stay as `@WireFormat`, `@WireFormatEnum`, `@WireFormatChoice` (user-facing surface; not project-scoped).
- Internal helper types prefixed `SheetMusic*` or `WireFormat*` adopt `Wirelet*` where they are part of the public surface; pure internals can stay unprefixed.
- Kotlin package `io.github.jiyimeta.sheetmusic.wireformat` → `io.github.jiyimeta.wirelet`.

End of phase: `swift test` (from `wirelet/`) and `kotlin/ ./gradlew test` are both green inside `wirelet`. `swift-sheet-music` still builds because the old copies have not yet been deleted.

### Phase 2 — feature gap fill (pre-public MVP)

Implemented inside `wirelet`. Order matters because D and E together change the binary format that A, B, C ride on:

1. **D + E together — Schema evolution + Field tags.** Tag-wire-type-value (TLV) format described below. Biggest change; lands first.
2. **A — `Optional<T>` support.** Absence on the wire = `nil`; no explicit presence byte.
3. **B — `Data` / `ByteArray` support.** wire type 2 (length-delimited).
4. **C — `Dictionary<K,V>` / `Map<K,V>` support.** wire type 2; entries encoded as `(K, V)` pairs.
5. **F — Macro diagnostics polish.** Friendly error messages for unsupported types, missing tags, reserved-tag reuse, etc.
6. **G — `docs/wire-format-spec.md`.** Language-neutral spec; required for future emitters and external review.
7. **H — `examples/cross-roundtrip/`.** Standalone Swift encoder + Android decoder sharing one schema file.

End of phase: `wirelet` is feature-complete for v0.1; conformance fixtures cover all features. `swift-sheet-music` still untouched and on its in-tree copies.

### Phase 3 — Gradle plugin v1

`io.github.jiyimeta.wirelet` published as `io.github.jiyimeta:wirelet-gradle-plugin`. DSL:

```kotlin
plugins {
    id("io.github.jiyimeta.wirelet") version "0.1.0"
}

dependencies {
    implementation("io.github.jiyimeta:wirelet-runtime:0.1.0")
}

wirelet {
    sources {
        register("main") {
            schemaPaths.from(file("../shared-schema/Sources"))
            packageName.set("com.example.app.codecs")
            includePackages.add("MyApp")
            defaultSerializationPackage.set("io.github.jiyimeta.wirelet")
        }
    }
}
```

Plugin behavior:
- Creates `generateWireletCodecs` task per registered source set.
- Task forks the `emit-wirelet-kotlin` CLI as an external JVM process (keeps Kotlin port of the emitter unnecessary).
- Output rooted at `${buildDir}/generated/wirelet/${sourceSetName}/kotlin/` and added to `srcDirs`.
- `compile{Variant}Kotlin` is automatically `dependsOn(generateWireletCodecs)`.
- Schema files are declared `@InputFiles`, generated files `@OutputDirectory`, so Gradle UP-TO-DATE / build-cache work correctly.

End of phase: `wirelet` is API- and tooling-complete for v0.1. Internal release tag `v0.1.0-alpha.1` cut on the private remote.

### Phase 4 — publish readiness

- README polished with quick-start and architecture overview.
- GitHub Actions workflows: `swift.yml` (macOS+Linux), `kotlin.yml` (Ubuntu JDK 17), `conformance.yml` (cross-language), `examples.yml`, `publish.yml` (tag-triggered Maven publish + GitHub Release).
- `publish.yml` dry-run executed against `v0.1.0-alpha.1` to validate the workflow end-to-end on GitHub Packages.

End of phase: a working release pipeline exists. swift-sheet-music has still not switched over.

### Phase 5 — consumer-ize swift-sheet-music (single shot)

Two PRs land together:

**PR-W1 (`wirelet`)**: Tag `v0.1.0` on the private remote (or `v0.1.0-alpha.2` if more iteration is anticipated).

**PR-S1 (`swift-sheet-music`)**:
- `Package.swift` adds `.package(url: "git@github.com:jiyimeta/wirelet.git", revision: "<sha-of-tag>")` and updates consuming targets to depend on `Wirelet`.
- All ported source directories (`SheetMusicWireFormatMacros`, `SheetMusicWireFormat`, `WireFormatSchema`, `WireFormatKotlinEmitter`, `EmitKotlinCodecs`) deleted from `swift-sheet-music`.
- Imports updated: `import Wirelet` replaces `import SheetMusicWireFormat`; macro names unchanged.
- `Android/SheetMusicAndroid/build.gradle.kts` adds `io.github.jiyimeta:wirelet-runtime` dependency via GitHub Packages; the old hand-rolled `BinaryReader/Writer.kt` are deleted.
- `Android/settings.gradle.kts` adds the GitHub Packages Maven URL (credentials sourced from env / `~/.gradle/gradle.properties`).
- Per-module `kotlin-codegen.json` files replaced by the `wirelet` Gradle plugin DSL.

**Crucially: `swift-sheet-music` never carries a `.package(path:)` to `wirelet`, even during private development.** Local iteration uses `swift package edit` and `gradle --include-build`, both of which override resolution without modifying committed files.

End of phase: all swift-sheet-music CI (iOS / macOS / Android) green against the remote `wirelet` ref. The OSS extraction is functionally complete. Public-repo flip happens at author's discretion afterwards.

## Wire format design (Phase 2 core)

### Overview

Each field on the wire is `<tag-varint> <payload>`. The varint encodes both a numeric tag and a 3-bit wire type (wire type = `tag-varint & 0b111`, tag number = `tag-varint >> 3`). This is the same trick protobuf uses; it lets a reader skip an unknown field without consulting the schema.

| Wire type | Code | Uses |
|---|---|---|
| varint | 0 | Int / UInt / Bool / enum raw / discriminator |
| fixed-64 | 1 | Double, fixed Int64 |
| length-delimited | 2 | String / Data / Array / Dictionary / nested struct / choice |
| fixed-32 | 5 | Float, fixed Int32 |

Skipping an unknown tag is `O(1)` given the wire type:
- type 0: read and discard one varint.
- type 1: skip 8 bytes.
- type 2: read length varint `N`, skip `N` bytes.
- type 5: skip 4 bytes.

### Per-type encoding

| Swift type | Wire type | Layout |
|---|---|---|
| `UInt8/16/32/64` (varint) | 0 | raw varint |
| `Int8/16/32/64` (varint) | 0 | zig-zag varint |
| `Bool` | 0 | `0` or `1` |
| `Float` | 5 | 4 bytes little-endian |
| `Double` | 1 | 8 bytes little-endian |
| `String` | 2 | varint length + UTF-8 bytes |
| `Data` / `[UInt8]` | 2 | varint length + raw bytes |
| `[T]` (general) | 2 | varint length + concatenated `T` payloads |
| `[K: V]` | 2 | varint length + varint count + `(K, V)` pairs |
| `Optional<T>` | T's wire type | absence on the wire = `nil`; no presence byte |
| nested `@WireFormat` | 2 | varint length + nested struct body |
| `@WireFormatEnum` | rawValue's wire type | rawValue serialized directly |
| `@WireFormatChoice` | 2 | varint length + varint discriminator + payload fields |

Choice payload: the associated values of the selected case are emitted as TLV fields with tags 1..N in their declaration order.

### Field tags

```swift
@WireFormat(reservedTags: [3, 5])
struct Foo {
    var name: String              // implicit tag 1
    var count: Int                // implicit tag 2
    @WireFormatField(tag: 7)
    var explicit: Bool            // explicit tag 7
    var next: Int                 // implicit tag 8 (max+1)
}
```

Rules:
- Implicit tags start at 1 and assigned in declaration order, skipping any explicit tags already used.
- `@WireFormatField(tag:)` locks a value; subsequent implicit assignments resume at `max(previous) + 1`.
- A struct can declare reserved tag numbers that the macro will reject if a field tries to claim them.

### Schema evolution rules

| Change | Outcome |
|---|---|
| Append an `Optional` field | safe forward + backward |
| Append a non-`Optional` field | safe forward; backward requires the new code to tolerate absence (macro can require a `default`) |
| Remove a field | mark `reserved`; do not reuse tag |
| Rename a field | safe (tags identify, not names) |
| Renumber a tag | breaking |
| Change wire type (e.g. `Int` → `String`) | breaking |
| `Optional<T>` → `T` | breaking |
| `T` → `Optional<T>` | safe |
| Add a choice case | old reader's behavior on unknown discriminator: configurable (default: error). |

`docs/schema-evolution.md` is the canonical reference.

### Impact on existing swift-sheet-music wire data

The current format is positional and binary-incompatible with the new TLV format. swift-sheet-music does not persist wire data (everything flows through live JNI / IPC), so the new Swift encoder + new Kotlin decoder can ship together without a migration story. This is explicitly accepted.

### BinaryReader / Writer API

Low-level helpers expose:
- `writeVarint`, `readVarint` (zig-zag aware)
- `writeTag(tag:wireType:)`, `readTag() -> (tag, wireType)`
- `writeLengthPrefixed { body }` / `readLengthPrefixed { reader in ... }`
- `skipUnknownField(wireType:)`

Generated codecs call these. The runtime is intentionally small enough that hand-written codecs remain a sane fallback for edge cases.

## Testing strategy

| Layer | Location | Coverage |
|---|---|---|
| Swift unit | `Tests/WireletSchemaTests`, `Tests/WireletKotlinEmitterTests`, `Tests/EmitWireletKotlinTests` | parser, emitter, CLI driver |
| Swift macro | `Tests/WireletMacrosTests` | macro expansion via `SwiftSyntaxMacrosTestSupport` |
| Kotlin unit | `kotlin/runtime/src/test/` | BinaryReader / Writer / varint / skip |
| Gradle plugin | `kotlin/gradle-plugin/src/functionalTest/` | TestKit fixtures: single-module, multi-module, incremental rebuild, build-cache hit |
| **Conformance (cross)** | `kotlin/conformance-tests/fixtures/` + `Tests/ConformanceTests` | Swift-encoded `.bin` files alongside source-of-truth `.json`; both Swift and Kotlin verify they round-trip. Wire format changes require a deliberate fixture bump. |
| Examples | `examples/*` builds in CI | "README works" guarantee |

### Conformance fixture format

```
kotlin/conformance-tests/fixtures/
  ├── primitives_v1.bin            # encoded by Swift, hex-stable
  ├── primitives_v1.json           # source-of-truth values
  ├── optional_present_v1.bin
  ├── optional_absent_v1.bin
  ├── choice_v1.bin
  └── forward_compat_v2_to_v1.bin  # v2 encoder output decoded by v1 schema
```

Both languages have a fixture runner that:
- Decodes `.bin` and asserts deep-equal against `.json`.
- Re-encodes the deserialized value and asserts byte-equal to the original `.bin` (canonicalization required where order is free).

A wire-format-affecting PR is required to update fixtures; CI fails loudly if a generated codec drifts from a fixture without a matching bump.

## CI / publish

| Workflow | Trigger | Action |
|---|---|---|
| `swift.yml` | PR / push | `swift build` + `swift test` on macOS (Xcode 16+) and Linux (Swift 6.x) |
| `kotlin.yml` | PR / push | `./gradlew build test` on Ubuntu / JDK 17 |
| `conformance.yml` | PR / push | both languages run the fixture runner |
| `examples.yml` | PR / push | build each `examples/*` |
| `publish.yml` | tag push (`v*.*.*`) | publish runtime + plugin to GitHub Packages; create GitHub Release |

Publish target: **GitHub Packages** (`maven.pkg.github.com/jiyimeta/wirelet`). Works for private repos with a PAT carrying `read:packages`. Same Path A approach as `sheet-music-android` (see memory `project_android_github_packages_publish`). Sonatype / Maven Central deferred.

## swift-sheet-music consumer pattern

After Phase 5, swift-sheet-music's committed configuration always references the remote, never a local path:

| Scenario | Committed config | Dev override |
|---|---|---|
| swift-sheet-music CI / normal dev | `.package(url: "git@github.com:jiyimeta/wirelet.git", revision: "<sha>")` + SSH deploy key | — |
| Local wirelet iteration | (unchanged) | `swift package edit Wirelet --path ../wirelet` and `./gradlew --include-build ../wirelet/kotlin ...` |
| Public publish | `.package(url: "https://github.com/jiyimeta/wirelet.git", exact: "0.1.0")` | same override available |

`swift package edit` and `--include-build` apply only to local state (under `.swiftpm/` and Gradle CLI args respectively); nothing about the local checkout leaks into committed files. This is the explicit consequence of the "no local information in repos" rule.

Dev overrides are worktree-friendly: the override path can point at any `wirelet` worktree, not just `~/Developer/Personal/swift-packages/wirelet/`.

GitHub Packages access (during private phase): swift-sheet-music's CI needs the maven repo URL + credentials from env. PAT scope: `read:packages`. SSH deploy key needed for the SwiftPM resolve step. Both must be configured before PR-S1 can pass CI.

## Open questions / deferred items

- **GitHub Packages PAT rotation** policy — addressed once we set up CI, not in this design.
- **Cross-language conformance for `Dictionary`** — entry ordering is undefined in both Swift `Dictionary` and Kotlin `Map`, so the fixture needs a canonical ordering. Likely: sort by encoded-key bytes. Will be locked in `docs/wire-format-spec.md`.
- **Future emitters (TS, Rust, Java)** — not in v0.1, but the schema layer must stay language-agnostic. The Kotlin emitter must not leak Kotlin-isms into `WireletSchema`.
- **Macro diagnostic completeness** — Phase 2 item F is "polish", not "100% coverage". Specific misuse cases to cover come from a separate audit during plan writing.
- **swift-sheet-music git history** for the ported directories — not preserved in `wirelet`; the migration is a clean copy. Old commits remain in swift-sheet-music history.
- **Replacement of `version: UInt32`-as-first-field convention** in swift-sheet-music's existing codecs — kept as a normal field; field tag 1 by default. No wire-level concept of "format version".
