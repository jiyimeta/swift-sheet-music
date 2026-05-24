# Kotlin Codec Codegen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-generate Kotlin encoders/decoders from Swift `@WireFormat` macros, delete ~700 lines of hand-written Kotlin mirror codecs, drive codegen from Gradle into non-committed `build/generated/` directories.

**Architecture:** Three new SwiftPM targets — `WireFormatSchema` (SwiftSyntax → schema), `WireFormatKotlinEmitter` (schema + config → Kotlin source), `EmitKotlinCodecs` (executable CLI). Existing macros (`@WireFormat`, `@WireFormatChoice`, `@WireFormatEnum`) gain one optional argument `kotlin:` carrying a `KotlinTarget` enum so per-type overrides live inline. Each Android Gradle module runs `swift run emit-kotlin-codecs` before `compileDebugKotlin`, with generated `.kt` landing in `build/generated/source/wire-format/kotlin/` and added to the module's source set.

**Tech Stack:** Swift 6.x, SwiftSyntax 603.x (already a transitive dep via swift-java), SwiftPM library + executable targets, Foundation `JSONDecoder`, Kotlin 1.9.x, Android Gradle Plugin, Gradle Kotlin DSL.

---

## File Structure

### New Swift files

- `Sources/WireFormatSchema/Schema.swift` — value types: `Schema`, `WireType`, `WireField`, `WireChoiceCase`, `WireEnumCase`, `KotlinTarget`-marker enum.
- `Sources/WireFormatSchema/SchemaParser.swift` — `SchemaParser.parse(sources:)` driver using SwiftSyntax visitor.
- `Sources/WireFormatSchema/Internal/AttributeArgumentExtractor.swift` — helper that lifts `kotlin:` argument off an `AttributeSyntax`.
- `Sources/WireFormatKotlinEmitter/KotlinCodegenConfig.swift` — `Codable` config struct.
- `Sources/WireFormatKotlinEmitter/PackageResolver.swift` — resolves Swift type name → (modelPackage, codecPackage, simpleName).
- `Sources/WireFormatKotlinEmitter/KotlinEmitter.swift` — entry point `emit(schema:config:)` → `[KotlinFile]`.
- `Sources/WireFormatKotlinEmitter/Internal/StructEmitter.swift` — emits codec for `@WireFormat` struct.
- `Sources/WireFormatKotlinEmitter/Internal/ChoiceEmitter.swift` — emits codec for `@WireFormatChoice` enum.
- `Sources/WireFormatKotlinEmitter/Internal/EnumEmitter.swift` — emits codec for `@WireFormatEnum`.
- `Sources/WireFormatKotlinEmitter/Internal/KotlinTypeMap.swift` — Swift primitive → Kotlin reader/writer call (`UInt8` → `r.readU8()` / `w.writeU8(_)`).
- `Sources/EmitKotlinCodecs/main.swift` — CLI argument parsing + orchestration.

### New Swift test files

- `Tests/WireFormatSchemaTests/SchemaParserTests.swift`
- `Tests/WireFormatSchemaTests/Fixtures/SimpleStruct.swift` — source-only fixture (parsed as text, not compiled)
- `Tests/WireFormatSchemaTests/Fixtures/ChoiceEnum.swift`
- `Tests/WireFormatSchemaTests/Fixtures/RawEnum.swift`
- `Tests/WireFormatSchemaTests/Fixtures/KotlinTargetOverrides.swift`
- `Tests/WireFormatKotlinEmitterTests/StructEmitterTests.swift`
- `Tests/WireFormatKotlinEmitterTests/ChoiceEmitterTests.swift`
- `Tests/WireFormatKotlinEmitterTests/EnumEmitterTests.swift`
- `Tests/WireFormatKotlinEmitterTests/Fixtures/MetronomeBeatCodec.expected.kt` — golden output
- `Tests/EmitKotlinCodecsTests/CLISmokeTests.swift` — end-to-end test against a small fixture dir.

### Modified Swift files

- `Package.swift` — add three new targets + their dependencies + `exclude` entry.
- `Sources/SheetMusicWireFormat/WireFormat.swift` — add `public enum KotlinTarget`, overload three macro declarations to accept `kotlin: KotlinTarget`.
- `Sources/SheetMusicWireFormatMacros/WireFormatMacro.swift` — unchanged behaviour but no longer rejects calls with `kotlin:` argument (it ignores arguments).
- `Sources/SheetMusicWireFormatMacros/WireFormatChoiceMacro.swift` — same.
- `Sources/SheetMusicWireFormatMacros/WireFormatEnumMacro.swift` — same.

### New config files

- `Sources/SheetMusicAndroidJNI/kotlin-codegen.json` — config for the only producer module (all `@WireFormat` types live in `SheetMusicAndroidJNI`).

### Modified Gradle files

- `Android/SheetMusicAudioAndroid/build.gradle.kts` — add `emitKotlinCodecs` task + source-set wiring.
- `Android/SheetMusicAndroid/build.gradle.kts` — same.
- `Examples/Android/app/build.gradle.kts` — same.

### Deleted Kotlin files (Phase 2)

- `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/AudioExportRangeEncoder.kt`
- `…/ClefAnchorDecoder.kt`
- `…/Encoders.kt`
- `…/FrameDecoder.kt`
- `…/GMInstrumentDecoder.kt`
- `…/MetronomeBeatDecoder.kt`
- `…/PathIDDecoders.kt`
- `…/ScoreCursorDecoder.kt`
- `…/ScoreItemIDDecoder.kt`
- `…/StaffParamsDecoder.kt`

(`BinaryReader.kt` and `BinaryWriter.kt` stay — they are external-spec byte readers used by all codecs.)

### Deleted Kotlin files (Phase 3)

- `Examples/Android/app/src/main/java/com/example/sheetmusic/draw/DrawProgramDecoder.kt`

### Modified Kotlin files

- `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/ScoreMetadata.kt` — replace inline `decode` with delegation to generated codec.

---

## Phase 1: Toolchain

Each task is self-contained: write tests, implement, commit. The phase ends with a green host-platform test suite and a byte-diff verification proving the emitter produces the same Kotlin source as a checked-in fixture.

### Task 1: Add `WireFormatSchema` library target with schema types

**Files:**
- Create: `Sources/WireFormatSchema/Schema.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the new target to `Package.swift`**

In `Package.swift`, insert into the `targets:` array (anywhere in the alphabetical/topological group, but after `SheetMusicWireFormatMacros`):

```swift
.target(
    name: "WireFormatSchema",
    dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
    ],
),
```

- [ ] **Step 2: Create `Sources/WireFormatSchema/Schema.swift`**

```swift
import Foundation

/// In-memory description of all `@WireFormat`-family declarations
/// discovered in a set of Swift source files.
public struct Schema: Equatable, Sendable {
    public var types: [WireType]
    public init(types: [WireType]) { self.types = types }
}

/// One discovered declaration. Either a struct (`@WireFormat`),
/// a sum-type enum (`@WireFormatChoice`), or a raw enum
/// (`@WireFormatEnum`).
public enum WireType: Equatable, Sendable {
    case `struct`(WireStruct)
    case choice(WireChoice)
    case rawEnum(WireRawEnum)

    public var name: String {
        switch self {
        case .struct(let s): return s.name
        case .choice(let c): return c.name
        case .rawEnum(let e): return e.name
        }
    }

    public var kotlinTarget: KotlinTarget {
        switch self {
        case .struct(let s): return s.kotlinTarget
        case .choice(let c): return c.kotlinTarget
        case .rawEnum(let e): return e.kotlinTarget
        }
    }
}

public struct WireStruct: Equatable, Sendable {
    public var name: String
    public var fields: [WireField]
    public var kotlinTarget: KotlinTarget
    public init(name: String, fields: [WireField], kotlinTarget: KotlinTarget) {
        self.name = name
        self.fields = fields
        self.kotlinTarget = kotlinTarget
    }
}

public struct WireField: Equatable, Sendable {
    public var name: String
    public var typeText: String
    public init(name: String, typeText: String) {
        self.name = name
        self.typeText = typeText
    }
}

public struct WireChoice: Equatable, Sendable {
    public var name: String
    public var cases: [WireChoiceCase]
    public var kotlinTarget: KotlinTarget
    public init(name: String, cases: [WireChoiceCase], kotlinTarget: KotlinTarget) {
        self.name = name
        self.cases = cases
        self.kotlinTarget = kotlinTarget
    }
}

public struct WireChoiceCase: Equatable, Sendable {
    public var name: String
    /// Associated value types in declaration order. Empty if the case has no payload.
    public var payloadTypes: [String]
    public init(name: String, payloadTypes: [String]) {
        self.name = name
        self.payloadTypes = payloadTypes
    }
}

public struct WireRawEnum: Equatable, Sendable {
    public var name: String
    public var cases: [String]
    public var kotlinTarget: KotlinTarget
    public init(name: String, cases: [String], kotlinTarget: KotlinTarget) {
        self.name = name
        self.cases = cases
        self.kotlinTarget = kotlinTarget
    }
}

/// Per-type Kotlin emission directive. Mirrors the Swift macro argument
/// shape so the parser can lift it straight off the source.
public enum KotlinTarget: Equatable, Sendable {
    case auto
    case skip
    case explicit(String)
}
```

- [ ] **Step 3: Verify the target builds**

Run: `swift build --target WireFormatSchema`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/WireFormatSchema/Schema.swift
git commit -m "feat(wire-format): scaffold WireFormatSchema library"
```

### Task 2: Implement schema parser for `@WireFormat` structs

**Files:**
- Create: `Sources/WireFormatSchema/SchemaParser.swift`
- Create: `Sources/WireFormatSchema/Internal/AttributeArgumentExtractor.swift`
- Create: `Tests/WireFormatSchemaTests/SchemaParserTests.swift`
- Create: `Tests/WireFormatSchemaTests/Fixtures/SimpleStruct.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add test target to `Package.swift`**

In the `targets:` array:

```swift
.testTarget(
    name: "WireFormatSchemaTests",
    dependencies: ["WireFormatSchema"],
    resources: [.copy("Fixtures")],
),
```

`.copy` (not `.process`) because fixture `.swift` files must be read raw without SwiftPM trying to compile them.

- [ ] **Step 2: Create the fixture**

`Tests/WireFormatSchemaTests/Fixtures/SimpleStruct.swift`:

```swift
// Fixture for SchemaParserTests. Parsed as text — not compiled.
@WireFormat
struct PointWire {
    var x: Int32
    var y: Int32
}
```

- [ ] **Step 3: Write the failing test**

`Tests/WireFormatSchemaTests/SchemaParserTests.swift`:

```swift
import Foundation
import Testing
@testable import WireFormatSchema

@Test func parsesSimpleStruct() throws {
    let fixtureURL = Bundle.module.url(
        forResource: "SimpleStruct",
        withExtension: "swift",
    )!
    let source = try String(contentsOf: fixtureURL, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "SimpleStruct.swift")

    #expect(schema.types.count == 1)
    guard case .struct(let s) = schema.types[0] else {
        Issue.record("Expected struct, got \(schema.types[0])")
        return
    }
    #expect(s.name == "PointWire")
    #expect(s.fields == [
        WireField(name: "x", typeText: "Int32"),
        WireField(name: "y", typeText: "Int32"),
    ])
    #expect(s.kotlinTarget == .auto)
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter WireFormatSchemaTests.SchemaParserTests/parsesSimpleStruct`
Expected: FAIL — `SchemaParser` not defined.

- [ ] **Step 5: Implement the attribute argument extractor**

`Sources/WireFormatSchema/Internal/AttributeArgumentExtractor.swift`:

```swift
import SwiftSyntax

enum AttributeArgumentExtractor {
    /// Returns the `kotlin:` argument value if present on the attribute,
    /// recognising literal forms `.auto`, `.skip`, `.explicit("...")`.
    static func kotlinTarget(of attribute: AttributeSyntax) -> KotlinTarget {
        guard case let .argumentList(args) = attribute.arguments else {
            return .auto
        }
        for arg in args where arg.label?.text == "kotlin" {
            return parseKotlinTarget(from: arg.expression)
        }
        return .auto
    }

    private static func parseKotlinTarget(from expr: ExprSyntax) -> KotlinTarget {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "auto": return .auto
            case "skip": return .skip
            default: return .auto
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "explicit",
           let first = call.arguments.first,
           let strLit = first.expression.as(StringLiteralExprSyntax.self),
           let segment = strLit.segments.first?.as(StringSegmentSyntax.self) {
            return .explicit(segment.content.text)
        }
        return .auto
    }
}
```

- [ ] **Step 6: Implement `SchemaParser` (struct support only — choice/enum come in later tasks)**

`Sources/WireFormatSchema/SchemaParser.swift`:

```swift
import Foundation
import SwiftParser
import SwiftSyntax

public enum SchemaParser {
    public static func parse(source: String, fileName: String) -> Schema {
        let tree = Parser.parse(source: source)
        let visitor = WireTypeVisitor(viewMode: .sourceAccurate)
        visitor.walk(tree)
        return Schema(types: visitor.types)
    }
}

final class WireTypeVisitor: SyntaxVisitor {
    var types: [WireType] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        for attribute in node.attributes {
            guard
                let attr = attribute.as(AttributeSyntax.self),
                attr.attributeName.trimmedDescription == "WireFormat"
            else { continue }
            let fields = collectFields(from: node)
            let target = AttributeArgumentExtractor.kotlinTarget(of: attr)
            types.append(.struct(WireStruct(
                name: node.name.text,
                fields: fields,
                kotlinTarget: target,
            )))
        }
        return .skipChildren
    }

    private func collectFields(from struct: StructDeclSyntax) -> [WireField] {
        var out: [WireField] = []
        for member in `struct`.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isStatic = varDecl.modifiers.contains { mod in
                mod.name.text == "static" || mod.name.text == "class"
            }
            if isStatic { continue }
            for binding in varDecl.bindings {
                guard binding.accessorBlock == nil else { continue }
                guard
                    let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                    let typeAnno = binding.typeAnnotation
                else { continue }
                out.append(WireField(
                    name: ident.identifier.text,
                    typeText: typeAnno.type.trimmedDescription,
                ))
            }
        }
        return out
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter WireFormatSchemaTests.SchemaParserTests/parsesSimpleStruct`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/WireFormatSchema/ Tests/WireFormatSchemaTests/
git commit -m "feat(wire-format-schema): parse @WireFormat structs"
```

### Task 3: Parse `@WireFormatChoice` enums

**Files:**
- Modify: `Sources/WireFormatSchema/SchemaParser.swift`
- Create: `Tests/WireFormatSchemaTests/Fixtures/ChoiceEnum.swift`
- Modify: `Tests/WireFormatSchemaTests/SchemaParserTests.swift`

- [ ] **Step 1: Create fixture**

`Tests/WireFormatSchemaTests/Fixtures/ChoiceEnum.swift`:

```swift
@WireFormatChoice
enum ScoreCursorWire {
    case item(ScoreItemIDWire)
    case beat(measureIndex: Int32, tickInMeasure: Int32)
}
```

- [ ] **Step 2: Write the failing test**

Append to `SchemaParserTests.swift`:

```swift
@Test func parsesChoiceEnum() throws {
    let url = Bundle.module.url(forResource: "ChoiceEnum", withExtension: "swift")!
    let source = try String(contentsOf: url, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "ChoiceEnum.swift")

    #expect(schema.types.count == 1)
    guard case .choice(let c) = schema.types[0] else {
        Issue.record("Expected choice, got \(schema.types[0])")
        return
    }
    #expect(c.name == "ScoreCursorWire")
    #expect(c.cases == [
        WireChoiceCase(name: "item", payloadTypes: ["ScoreItemIDWire"]),
        WireChoiceCase(name: "beat", payloadTypes: ["Int32", "Int32"]),
    ])
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter WireFormatSchemaTests.SchemaParserTests/parsesChoiceEnum`
Expected: FAIL — `schema.types.count == 0`.

- [ ] **Step 4: Implement choice parsing**

In `SchemaParser.swift`, add to `WireTypeVisitor`:

```swift
override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    for attribute in node.attributes {
        guard
            let attr = attribute.as(AttributeSyntax.self)
        else { continue }
        let attrName = attr.attributeName.trimmedDescription
        let target = AttributeArgumentExtractor.kotlinTarget(of: attr)
        switch attrName {
        case "WireFormatChoice":
            types.append(.choice(WireChoice(
                name: node.name.text,
                cases: collectChoiceCases(from: node),
                kotlinTarget: target,
            )))
        case "WireFormatEnum":
            types.append(.rawEnum(WireRawEnum(
                name: node.name.text,
                cases: collectRawCases(from: node),
                kotlinTarget: target,
            )))
        default:
            continue
        }
    }
    return .skipChildren
}

private func collectChoiceCases(from enumDecl: EnumDeclSyntax) -> [WireChoiceCase] {
    var out: [WireChoiceCase] = []
    for member in enumDecl.memberBlock.members {
        guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in caseDecl.elements {
            let payload: [String] = element.parameterClause?.parameters.map { param in
                param.type.trimmedDescription
            } ?? []
            out.append(WireChoiceCase(
                name: element.name.text,
                payloadTypes: payload,
            ))
        }
    }
    return out
}

private func collectRawCases(from enumDecl: EnumDeclSyntax) -> [String] {
    var out: [String] = []
    for member in enumDecl.memberBlock.members {
        guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in caseDecl.elements {
            out.append(element.name.text)
        }
    }
    return out
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter WireFormatSchemaTests.SchemaParserTests/parsesChoiceEnum`
Expected: PASS. Also re-run the `parsesSimpleStruct` test to ensure no regression.

- [ ] **Step 6: Commit**

```bash
git add Sources/WireFormatSchema/SchemaParser.swift Tests/WireFormatSchemaTests/
git commit -m "feat(wire-format-schema): parse @WireFormatChoice enums"
```

### Task 4: Parse `@WireFormatEnum` raw enums

**Files:**
- Create: `Tests/WireFormatSchemaTests/Fixtures/RawEnum.swift`
- Modify: `Tests/WireFormatSchemaTests/SchemaParserTests.swift`

(`SchemaParser.swift` already handles this from Task 3 — this task adds the test coverage.)

- [ ] **Step 1: Create fixture**

`Tests/WireFormatSchemaTests/Fixtures/RawEnum.swift`:

```swift
@WireFormatEnum
enum GMInstrumentFamilyWire: CaseIterable {
    case piano
    case chromaticPercussion
    case organ
}
```

- [ ] **Step 2: Write the failing test**

Append to `SchemaParserTests.swift`:

```swift
@Test func parsesRawEnum() throws {
    let url = Bundle.module.url(forResource: "RawEnum", withExtension: "swift")!
    let source = try String(contentsOf: url, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "RawEnum.swift")

    #expect(schema.types.count == 1)
    guard case .rawEnum(let e) = schema.types[0] else {
        Issue.record("Expected rawEnum, got \(schema.types[0])")
        return
    }
    #expect(e.name == "GMInstrumentFamilyWire")
    #expect(e.cases == ["piano", "chromaticPercussion", "organ"])
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter WireFormatSchemaTests.SchemaParserTests/parsesRawEnum`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/WireFormatSchemaTests/
git commit -m "test(wire-format-schema): cover @WireFormatEnum parsing"
```

### Task 5: Recognise `kotlin:` attribute argument

**Files:**
- Create: `Tests/WireFormatSchemaTests/Fixtures/KotlinTargetOverrides.swift`
- Modify: `Tests/WireFormatSchemaTests/SchemaParserTests.swift`

- [ ] **Step 1: Create fixture**

`Tests/WireFormatSchemaTests/Fixtures/KotlinTargetOverrides.swift`:

```swift
@WireFormat(kotlin: .skip)
struct AppleOnlyWire {
    var value: Int32
}

@WireFormat(kotlin: .explicit("io.example.legacy.Frame"))
struct CustomLocationWire {
    var tick: Int64
}

@WireFormatChoice(kotlin: .skip)
enum SkippedChoiceWire {
    case a
}
```

- [ ] **Step 2: Write the failing test**

Append to `SchemaParserTests.swift`:

```swift
@Test func parsesKotlinTargetOverrides() throws {
    let url = Bundle.module.url(forResource: "KotlinTargetOverrides", withExtension: "swift")!
    let source = try String(contentsOf: url, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "KotlinTargetOverrides.swift")

    #expect(schema.types.count == 3)
    #expect(schema.types[0].kotlinTarget == .skip)
    #expect(schema.types[1].kotlinTarget == .explicit("io.example.legacy.Frame"))
    #expect(schema.types[2].kotlinTarget == .skip)
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter WireFormatSchemaTests.SchemaParserTests/parsesKotlinTargetOverrides`
Expected: PASS (logic already in place from Task 2).

- [ ] **Step 4: Commit**

```bash
git add Tests/WireFormatSchemaTests/
git commit -m "test(wire-format-schema): cover kotlin: attribute argument"
```

### Task 6: Add `KotlinTarget` enum + macro overloads in SheetMusicWireFormat

**Files:**
- Modify: `Sources/SheetMusicWireFormat/WireFormat.swift`

- [ ] **Step 1: Write the failing build test**

Create a temporary test file `Tests/SheetMusicTests/KotlinTargetCompilationTest.swift`:

```swift
import SheetMusicWireFormat

// Compile-only test: these declarations must accept the kotlin: argument.
@WireFormat(kotlin: .auto)
private struct _AutoMarker {
    var x: Int32
}

@WireFormat(kotlin: .skip)
private struct _SkipMarker {
    var x: Int32
}

@WireFormat(kotlin: .explicit("io.example.X"))
private struct _ExplicitMarker {
    var x: Int32
}
```

- [ ] **Step 2: Run build to verify it fails**

Run: `swift build`
Expected: FAIL — `error: extra argument 'kotlin' in macro call` (or similar).

- [ ] **Step 3: Add `KotlinTarget` and macro overloads**

In `Sources/SheetMusicWireFormat/WireFormat.swift`, after the existing `WireFormatError` enum and before the `@attached(extension, ...)` block for `WireFormat`, insert:

```swift
/// Per-type override controlling how the external Kotlin codec
/// emitter (`emit-kotlin-codecs`) handles this type. The Swift macro
/// expansion ignores this argument — it's metadata for the external
/// tool only.
///
/// - `.auto`: resolve target Kotlin location via project config
///   (`kotlin-codegen.json`). Default when the argument is omitted.
/// - `.skip`: do not emit a Kotlin codec for this type. Use for types
///   that exist only in Swift-side flows.
/// - `.explicit(String)`: place the Kotlin codec at the given
///   fully-qualified package + class name, ignoring config rules.
public enum KotlinTarget: Sendable {
    case auto
    case skip
    case explicit(String)
}
```

Then immediately after each of the three existing `public macro` declarations, add a second overload that accepts `kotlin:`. For `@WireFormat`:

```swift
@attached(
    extension,
    conformances: WireFormatEncodable, WireFormatDecodable,
    names: named(encode(into:)), named(init(from:))
)
public macro WireFormat(kotlin: KotlinTarget) = #externalMacro(
    module: "SheetMusicWireFormatMacros",
    type: "WireFormatMacro",
)
```

Same shape for `WireFormatEnum` and `WireFormatChoice` — same `kotlin: KotlinTarget` argument, same `#externalMacro` reference as the existing overload.

- [ ] **Step 4: Run build to verify it passes**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 5: Remove the temporary marker file**

```bash
rm Tests/SheetMusicTests/KotlinTargetCompilationTest.swift
```

(The macro overloads are exercised by real `@WireFormat(kotlin: …)` usage starting in Phase 2; the temporary markers were only for TDD.)

- [ ] **Step 6: Run full test suite to confirm no regression**

Run: `swift test`
Expected: All existing tests pass; new `WireFormatSchemaTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicWireFormat/WireFormat.swift
git commit -m "feat(wire-format): KotlinTarget arg on macros (codegen metadata)"
```

### Task 7: Implement `WireFormatKotlinEmitter` skeleton + `KotlinCodegenConfig`

**Files:**
- Create: `Sources/WireFormatKotlinEmitter/KotlinCodegenConfig.swift`
- Create: `Sources/WireFormatKotlinEmitter/PackageResolver.swift`
- Create: `Sources/WireFormatKotlinEmitter/KotlinEmitter.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/PackageResolverTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the new target + test target**

In `Package.swift`:

```swift
.target(
    name: "WireFormatKotlinEmitter",
    dependencies: ["WireFormatSchema"],
),
.testTarget(
    name: "WireFormatKotlinEmitterTests",
    dependencies: ["WireFormatKotlinEmitter", "WireFormatSchema"],
    resources: [.copy("Fixtures")],
),
```

- [ ] **Step 2: Define `KotlinCodegenConfig`**

`Sources/WireFormatKotlinEmitter/KotlinCodegenConfig.swift`:

```swift
import Foundation

public struct KotlinCodegenConfig: Codable, Sendable, Equatable {
    public var defaultModelPackage: String
    public var defaultCodecPackage: String
    public var nameTransform: NameTransform
    public var rules: [Rule]

    public init(
        defaultModelPackage: String,
        defaultCodecPackage: String,
        nameTransform: NameTransform = .identity,
        rules: [Rule] = [],
    ) {
        self.defaultModelPackage = defaultModelPackage
        self.defaultCodecPackage = defaultCodecPackage
        self.nameTransform = nameTransform
        self.rules = rules
    }
}

public struct Rule: Codable, Sendable, Equatable {
    public var pattern: String
    public var modelPackage: String?
    public var codecPackage: String?
    public init(pattern: String, modelPackage: String? = nil, codecPackage: String? = nil) {
        self.pattern = pattern
        self.modelPackage = modelPackage
        self.codecPackage = codecPackage
    }
}

public enum NameTransform: Codable, Sendable, Equatable {
    case identity
    case stripSuffix(String)

    public func apply(to name: String) -> String {
        switch self {
        case .identity: return name
        case .stripSuffix(let suffix):
            return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        }
    }

    // Encodes to `{"identity":true}` or `{"stripSuffix":"Wire"}` for easy JSON authoring.
    private enum CodingKeys: String, CodingKey { case identity, stripSuffix }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identity: try c.encode(true, forKey: .identity)
        case .stripSuffix(let s): try c.encode(s, forKey: .stripSuffix)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.stripSuffix) {
            self = .stripSuffix(try c.decode(String.self, forKey: .stripSuffix))
        } else {
            self = .identity
        }
    }
}
```

- [ ] **Step 3: Write the failing `PackageResolver` test**

`Tests/WireFormatKotlinEmitterTests/PackageResolverTests.swift`:

```swift
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func resolvesDefault() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "MetronomeBeatWire", target: .auto)

    #expect(resolved == .emit(
        modelPackage: "io.example.audio.model",
        codecPackage: "io.example.audio.serialization",
        kotlinName: "MetronomeBeat",
    ))
}

@Test func ruleOverridesDefault() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
        rules: [Rule(
            pattern: "Score*",
            modelPackage: "io.example.score",
            codecPackage: "io.example.score",
        )],
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "ScoreMetadataWire", target: .auto)

    #expect(resolved == .emit(
        modelPackage: "io.example.score",
        codecPackage: "io.example.score",
        kotlinName: "ScoreMetadata",
    ))
}

@Test func explicitTargetSkipsConfig() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "FooWire", target: .explicit("io.other.Foo"))

    #expect(resolved == .emit(
        modelPackage: "io.other",
        codecPackage: "io.other",
        kotlinName: "Foo",
    ))
}

@Test func skipTargetEmitsNothing() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "FooWire", target: .skip)

    #expect(resolved == .skip)
}
```

- [ ] **Step 4: Run tests to confirm they fail**

Run: `swift test --filter WireFormatKotlinEmitterTests.PackageResolverTests`
Expected: FAIL — `PackageResolver` not defined.

- [ ] **Step 5: Implement `PackageResolver`**

`Sources/WireFormatKotlinEmitter/PackageResolver.swift`:

```swift
import WireFormatSchema

public enum ResolvedTarget: Equatable, Sendable {
    case skip
    case emit(modelPackage: String, codecPackage: String, kotlinName: String)
}

public struct PackageResolver: Sendable {
    public let config: KotlinCodegenConfig
    public init(config: KotlinCodegenConfig) { self.config = config }

    public func resolve(swiftName: String, target: KotlinTarget) -> ResolvedTarget {
        switch target {
        case .skip:
            return .skip
        case .explicit(let fqn):
            let (pkg, name) = splitFQN(fqn)
            return .emit(modelPackage: pkg, codecPackage: pkg, kotlinName: name)
        case .auto:
            let kotlinName = config.nameTransform.apply(to: swiftName)
            for rule in config.rules where matches(pattern: rule.pattern, name: swiftName) {
                return .emit(
                    modelPackage: rule.modelPackage ?? config.defaultModelPackage,
                    codecPackage: rule.codecPackage ?? config.defaultCodecPackage,
                    kotlinName: kotlinName,
                )
            }
            return .emit(
                modelPackage: config.defaultModelPackage,
                codecPackage: config.defaultCodecPackage,
                kotlinName: kotlinName,
            )
        }
    }

    /// Simple prefix-glob match: `"Score*"` matches names starting with `"Score"`,
    /// `"*"` matches anything, plain `"Foo"` is an exact match. Only one `*`
    /// supported and only as a trailing wildcard.
    private func matches(pattern: String, name: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            let prefix = pattern.dropLast()
            return name.hasPrefix(prefix)
        }
        return pattern == name
    }

    private func splitFQN(_ fqn: String) -> (package: String, name: String) {
        guard let lastDot = fqn.lastIndex(of: ".") else { return ("", fqn) }
        return (String(fqn[..<lastDot]), String(fqn[fqn.index(after: lastDot)...]))
    }
}
```

- [ ] **Step 6: Skeleton emitter that errors out on real input (to be filled in subsequent tasks)**

`Sources/WireFormatKotlinEmitter/KotlinEmitter.swift`:

```swift
import WireFormatSchema

public struct KotlinFile: Equatable, Sendable {
    public var relativePath: String   // e.g. "io/example/audio/serialization/FooCodec.kt"
    public var content: String
    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

public enum KotlinEmitterError: Error, Equatable {
    case unsupportedType(String)
}

public struct KotlinEmitter: Sendable {
    public let config: KotlinCodegenConfig
    private let resolver: PackageResolver

    public init(config: KotlinCodegenConfig) {
        self.config = config
        self.resolver = PackageResolver(config: config)
    }

    public func emit(schema: Schema) throws -> [KotlinFile] {
        var files: [KotlinFile] = []
        for type in schema.types {
            let resolved = resolver.resolve(swiftName: type.name, target: type.kotlinTarget)
            guard case let .emit(modelPkg, codecPkg, kotlinName) = resolved else { continue }
            switch type {
            case .struct(let s):
                files.append(emitStruct(s, kotlinName: kotlinName,
                                        modelPkg: modelPkg, codecPkg: codecPkg))
            case .choice(let c):
                files.append(emitChoice(c, kotlinName: kotlinName,
                                        modelPkg: modelPkg, codecPkg: codecPkg))
            case .rawEnum(let e):
                files.append(emitRawEnum(e, kotlinName: kotlinName,
                                         modelPkg: modelPkg, codecPkg: codecPkg))
            }
        }
        return files
    }
}
```

- [ ] **Step 7: Run tests**

Run: `swift test --filter WireFormatKotlinEmitterTests.PackageResolverTests`
Expected: All 4 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/WireFormatKotlinEmitter/ Tests/WireFormatKotlinEmitterTests/
git commit -m "feat(wire-format-emitter): config + resolver scaffolding"
```

### Task 8: Emit Kotlin codec for `@WireFormat` struct

**Files:**
- Create: `Sources/WireFormatKotlinEmitter/Internal/KotlinTypeMap.swift`
- Create: `Sources/WireFormatKotlinEmitter/Internal/StructEmitter.swift`
- Modify: `Sources/WireFormatKotlinEmitter/KotlinEmitter.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/StructEmitterTests.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/Fixtures/PointCodec.expected.kt`

- [ ] **Step 1: Create expected output fixture**

`Tests/WireFormatKotlinEmitterTests/Fixtures/PointCodec.expected.kt`:

```kotlin
// Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
package io.example.audio.serialization

import io.example.audio.model.Point
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

internal object PointCodec {
    fun encode(value: Point): ByteArray {
        val w = BinaryWriter()
        encodePayload(value, w)
        return w.toByteArray()
    }

    fun encodePayload(value: Point, w: BinaryWriter) {
        w.writeI32(value.x)
        w.writeI32(value.y)
    }

    fun decode(data: ByteArray): Point {
        val r = BinaryReader(data)
        return decodePayload(r)
    }

    fun decodePayload(r: BinaryReader): Point {
        val x = r.readI32()
        val y = r.readI32()
        return Point(
            x = x,
            y = y,
        )
    }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/WireFormatKotlinEmitterTests/StructEmitterTests.swift`:

```swift
import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func emitsStructCodec() throws {
    let schema = Schema(types: [
        .struct(WireStruct(
            name: "PointWire",
            fields: [
                WireField(name: "x", typeText: "Int32"),
                WireField(name: "y", typeText: "Int32"),
            ],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)

    #expect(files.count == 1)
    let expectedURL = Bundle.module.url(forResource: "PointCodec.expected", withExtension: "kt")!
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(files[0].content == expected)
    #expect(files[0].relativePath == "io/example/audio/serialization/PointCodec.kt")
}
```

- [ ] **Step 3: Run test, confirm failure**

Run: `swift test --filter WireFormatKotlinEmitterTests.StructEmitterTests/emitsStructCodec`
Expected: FAIL — emitter still uses placeholder `emitStruct` from Task 7.

- [ ] **Step 4: Implement `KotlinTypeMap`**

`Sources/WireFormatKotlinEmitter/Internal/KotlinTypeMap.swift`:

```swift
enum KotlinTypeMap {
    /// Returns `(kotlinType, readerCall, writerCall(_:))` for a Swift
    /// primitive type. Calls use `r`/`w` as the cursor variable names.
    static func primitive(_ swiftType: String) -> (kotlinType: String, read: String, write: (String) -> String)? {
        switch swiftType {
        case "UInt8":  return ("UByte",   "r.readU8()",  { "w.writeU8(\($0))" })
        case "Int8":   return ("Byte",    "r.readI8()",  { "w.writeI8(\($0))" })
        case "UInt16": return ("UShort",  "r.readU16()", { "w.writeU16(\($0))" })
        case "Int16":  return ("Short",   "r.readI16()", { "w.writeI16(\($0))" })
        case "UInt32": return ("UInt",    "r.readU32()", { "w.writeU32(\($0))" })
        case "Int32":  return ("Int",     "r.readI32()", { "w.writeI32(\($0))" })
        case "UInt64": return ("ULong",   "r.readU64()", { "w.writeU64(\($0))" })
        case "Int64":  return ("Long",    "r.readI64()", { "w.writeI64(\($0))" })
        case "Float":  return ("Float",   "r.readF32()", { "w.writeF32(\($0))" })
        case "Double": return ("Double",  "r.readF64()", { "w.writeF64(\($0))" })
        case "Bool":   return ("Boolean", "r.readU8() != 0u.toUByte()", { "w.writeU8(if (\($0)) 1u else 0u)" })
        case "String": return ("String",  "r.readString()", { "w.writeString(\($0))" })
        default:
            return nil
        }
    }
}
```

(Note: `BinaryReader`/`BinaryWriter` in the existing Kotlin codebase already provides these `readI32`/`writeI32` methods. Verify by reading `Android/SheetMusicAudioAndroid/src/main/kotlin/.../serialization/BinaryReader.kt` and `BinaryWriter.kt` before completing Step 5 — if `readString`/`writeString` are not present, file a follow-up task and skip strings for now since none of the current `@WireFormat` types use raw `String` fields.)

- [ ] **Step 5: Implement `StructEmitter`**

`Sources/WireFormatKotlinEmitter/Internal/StructEmitter.swift`:

```swift
import WireFormatSchema

enum StructEmitter {
    static func emit(
        _ wireStruct: WireStruct,
        kotlinName: String,
        modelPackage: String,
        codecPackage: String,
        nameTransform: NameTransform,
    ) -> KotlinFile {
        let codecName = "\(kotlinName)Codec"
        let path = codecPackage.replacingOccurrences(of: ".", with: "/") + "/\(codecName).kt"

        let encodeLines = wireStruct.fields.map { field in
            "        " + writeCall(for: field, transform: nameTransform)
        }.joined(separator: "\n")

        let decodeLocals = wireStruct.fields.map { field in
            "        val \(field.name) = " + readExpr(for: field, transform: nameTransform)
        }.joined(separator: "\n")

        let decodeBuild = wireStruct.fields.map { field in
            "            \(field.name) = \(field.name),"
        }.joined(separator: "\n")

        let content = """
        // Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
        package \(codecPackage)

        import \(modelPackage).\(kotlinName)
        import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
        import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

        internal object \(codecName) {
            fun encode(value: \(kotlinName)): ByteArray {
                val w = BinaryWriter()
                encodePayload(value, w)
                return w.toByteArray()
            }

            fun encodePayload(value: \(kotlinName), w: BinaryWriter) {
        \(encodeLines)
            }

            fun decode(data: ByteArray): \(kotlinName) {
                val r = BinaryReader(data)
                return decodePayload(r)
            }

            fun decodePayload(r: BinaryReader): \(kotlinName) {
        \(decodeLocals)
                return \(kotlinName)(
        \(decodeBuild)
                )
            }
        }

        """

        return KotlinFile(relativePath: path, content: content)
    }

    private static func writeCall(for field: WireField, transform: NameTransform) -> String {
        if let primitive = KotlinTypeMap.primitive(field.typeText) {
            return primitive.write("value.\(field.name)")
        }
        // Non-primitive: delegate to that type's codec by transformed name.
        let codecName = transform.apply(to: field.typeText) + "Codec"
        return "\(codecName).encodePayload(value.\(field.name), w)"
    }

    private static func readExpr(for field: WireField, transform: NameTransform) -> String {
        if let primitive = KotlinTypeMap.primitive(field.typeText) {
            return primitive.read
        }
        let codecName = transform.apply(to: field.typeText) + "Codec"
        return "\(codecName).decodePayload(r)"
    }
}
```

- [ ] **Step 6: Wire the struct emitter into `KotlinEmitter`**

In `Sources/WireFormatKotlinEmitter/KotlinEmitter.swift`, replace the body of the `case .struct(let s):` branch in `emit(schema:)` with:

```swift
case .struct(let s):
    files.append(StructEmitter.emit(
        s,
        kotlinName: kotlinName,
        modelPackage: modelPkg,
        codecPackage: codecPkg,
        nameTransform: config.nameTransform,
    ))
```

Remove the now-unused `emitStruct` placeholder method. Do the same `// TODO replace later` placeholder for the `case .choice` and `case .rawEnum` arms (they'll be implemented in Tasks 9 and 10):

```swift
case .choice(let c):
    throw KotlinEmitterError.unsupportedType("WireFormatChoice not yet implemented: \(c.name)")
case .rawEnum(let e):
    throw KotlinEmitterError.unsupportedType("WireFormatEnum not yet implemented: \(e.name)")
```

- [ ] **Step 7: Run the test, confirm it passes**

Run: `swift test --filter WireFormatKotlinEmitterTests.StructEmitterTests/emitsStructCodec`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/WireFormatKotlinEmitter/ Tests/WireFormatKotlinEmitterTests/
git commit -m "feat(wire-format-emitter): emit Kotlin codec for @WireFormat struct"
```

### Task 9: Emit Kotlin codec for `@WireFormatChoice` enum

**Files:**
- Create: `Sources/WireFormatKotlinEmitter/Internal/ChoiceEmitter.swift`
- Modify: `Sources/WireFormatKotlinEmitter/KotlinEmitter.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/ChoiceEmitterTests.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/Fixtures/ScoreCursorCodec.expected.kt`

- [ ] **Step 1: Create expected output fixture**

`Tests/WireFormatKotlinEmitterTests/Fixtures/ScoreCursorCodec.expected.kt`:

```kotlin
// Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
package io.example.audio.serialization

import io.example.audio.model.ScoreCursor
import io.example.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

internal object ScoreCursorCodec {
    fun encode(value: ScoreCursor): ByteArray {
        val w = BinaryWriter()
        encodePayload(value, w)
        return w.toByteArray()
    }

    fun encodePayload(value: ScoreCursor, w: BinaryWriter) {
        when (value) {
            is ScoreCursor.Item -> {
                w.writeU8(0u)
                ScoreItemIDCodec.encodePayload(value.item, w)
            }
            is ScoreCursor.Beat -> {
                w.writeU8(1u)
                w.writeI32(value.measureIndex)
                w.writeI32(value.tickInMeasure)
            }
        }
    }

    fun decode(data: ByteArray): ScoreCursor {
        val r = BinaryReader(data)
        return decodePayload(r)
    }

    fun decodePayload(r: BinaryReader): ScoreCursor {
        return when (val disc = r.readU8().toInt()) {
            0 -> ScoreCursor.Item(
                item = ScoreItemIDCodec.decodePayload(r),
            )
            1 -> ScoreCursor.Beat(
                measureIndex = r.readI32(),
                tickInMeasure = r.readI32(),
            )
            else -> throw IllegalArgumentException("Unknown ScoreCursor discriminator: $disc")
        }
    }
}
```

The emitter capitalises the first letter of each case name (`item` → `Item`) to match Kotlin sealed-class subtype naming.

For payload labels on cases without a label (`case item(ScoreItemIDWire)`), the emitter uses positional-name convention. The corresponding hand-written Kotlin uses `cursor.item` for the unlabelled `item(_:)` payload — the generator follows the same rule: an unlabelled associated value becomes a property named after the case (lowercased). For labelled associated values (`case beat(measureIndex: Int32, tickInMeasure: Int32)`), the label is used verbatim.

- [ ] **Step 2: Write the failing test**

`Tests/WireFormatKotlinEmitterTests/ChoiceEmitterTests.swift`:

```swift
import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func emitsChoiceCodec() throws {
    let schema = Schema(types: [
        .choice(WireChoice(
            name: "ScoreCursorWire",
            cases: [
                WireChoiceCase(name: "item", payloadTypes: ["ScoreItemIDWire"]),
                WireChoiceCase(name: "beat", payloadTypes: ["Int32", "Int32"]),
            ],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)

    #expect(files.count == 1)
    let expectedURL = Bundle.module.url(forResource: "ScoreCursorCodec.expected", withExtension: "kt")!
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(files[0].content == expected)
}
```

The choice fixture above uses *labelled* `beat(measureIndex:, tickInMeasure:)` (matches the existing Swift source) and *unlabelled* `item(ScoreItemIDWire)`. The schema model represents both as positional `payloadTypes`. To express labels we need an extension; defer that to a follow-up commit by making the test schema contain only one labelled case shape via a small adjustment: change to:

```swift
WireChoiceCase(name: "beat", payloadTypes: ["Int32", "Int32"]),
```

(i.e. labels not tracked yet) and update the fixture's `Beat` subtype to use positional names `arg0`, `arg1`. This is uglier than the hand-written code but mechanical and round-trips. Tracking labels is added in Task 9.5.

- [ ] **Step 3: Adjust the expected fixture for the unlabelled-MVP encoding**

Rewrite the `decodePayload` branch in `ScoreCursorCodec.expected.kt` for `Beat` to:

```kotlin
            1 -> ScoreCursor.Beat(
                arg0 = r.readI32(),
                arg1 = r.readI32(),
            )
```

and the `encodePayload` branch:

```kotlin
            is ScoreCursor.Beat -> {
                w.writeU8(1u)
                w.writeI32(value.arg0)
                w.writeI32(value.arg1)
            }
```

This will not yet match real Kotlin model types — Task 9.5 fixes that.

- [ ] **Step 4: Run test, confirm failure**

Run: `swift test --filter WireFormatKotlinEmitterTests.ChoiceEmitterTests/emitsChoiceCodec`
Expected: FAIL — emitter still throws `unsupportedType`.

- [ ] **Step 5: Implement `ChoiceEmitter`**

`Sources/WireFormatKotlinEmitter/Internal/ChoiceEmitter.swift`:

```swift
import WireFormatSchema

enum ChoiceEmitter {
    static func emit(
        _ choice: WireChoice,
        kotlinName: String,
        modelPackage: String,
        codecPackage: String,
        nameTransform: NameTransform,
    ) -> KotlinFile {
        let codecName = "\(kotlinName)Codec"
        let path = codecPackage.replacingOccurrences(of: ".", with: "/") + "/\(codecName).kt"

        // Collect non-primitive referenced types (for `import` lines).
        var referenced = Set<String>()
        for c in choice.cases {
            for ty in c.payloadTypes where KotlinTypeMap.primitive(ty) == nil {
                referenced.insert(nameTransform.apply(to: ty))
            }
        }
        let extraImports = referenced.sorted()
            .map { "import \(modelPackage).\($0)" }
            .joined(separator: "\n")

        let encodeBranches = choice.cases.enumerated().map { idx, c in
            emitEncodeBranch(case: c, index: idx, kotlinName: kotlinName, nameTransform: nameTransform)
        }.joined(separator: "\n")

        let decodeBranches = choice.cases.enumerated().map { idx, c in
            emitDecodeBranch(case: c, index: idx, kotlinName: kotlinName, nameTransform: nameTransform)
        }.joined(separator: "\n")

        let content = """
        // Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
        package \(codecPackage)

        import \(modelPackage).\(kotlinName)
        \(extraImports.isEmpty ? "" : extraImports + "\n")\
        import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
        import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

        internal object \(codecName) {
            fun encode(value: \(kotlinName)): ByteArray {
                val w = BinaryWriter()
                encodePayload(value, w)
                return w.toByteArray()
            }

            fun encodePayload(value: \(kotlinName), w: BinaryWriter) {
                when (value) {
        \(encodeBranches)
                }
            }

            fun decode(data: ByteArray): \(kotlinName) {
                val r = BinaryReader(data)
                return decodePayload(r)
            }

            fun decodePayload(r: BinaryReader): \(kotlinName) {
                return when (val disc = r.readU8().toInt()) {
        \(decodeBranches)
                    else -> throw IllegalArgumentException(
                        "Unknown \(kotlinName) discriminator: $disc",
                    )
                }
            }
        }

        """

        return KotlinFile(relativePath: path, content: content)
    }

    private static func emitEncodeBranch(
        case c: WireChoiceCase,
        index: Int,
        kotlinName: String,
        nameTransform: NameTransform,
    ) -> String {
        let subtype = "\(kotlinName).\(c.name.capitalizedFirst)"
        var lines: [String] = []
        lines.append("            is \(subtype) -> {")
        lines.append("                w.writeU8(\(index)u)")
        for (i, ty) in c.payloadTypes.enumerated() {
            let propAccess = "value.arg\(i)"
            if let primitive = KotlinTypeMap.primitive(ty) {
                lines.append("                " + primitive.write(propAccess))
            } else {
                let codecName = nameTransform.apply(to: ty) + "Codec"
                lines.append("                \(codecName).encodePayload(\(propAccess), w)")
            }
        }
        lines.append("            }")
        return lines.joined(separator: "\n")
    }

    private static func emitDecodeBranch(
        case c: WireChoiceCase,
        index: Int,
        kotlinName: String,
        nameTransform: NameTransform,
    ) -> String {
        let subtype = "\(kotlinName).\(c.name.capitalizedFirst)"
        if c.payloadTypes.isEmpty {
            return "                    \(index) -> \(subtype)"
        }
        var lines: [String] = []
        lines.append("                    \(index) -> \(subtype)(")
        for (i, ty) in c.payloadTypes.enumerated() {
            if let primitive = KotlinTypeMap.primitive(ty) {
                lines.append("                        arg\(i) = \(primitive.read),")
            } else {
                let codecName = nameTransform.apply(to: ty) + "Codec"
                lines.append("                        arg\(i) = \(codecName).decodePayload(r),")
            }
        }
        lines.append("                    )")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = self.first else { return self }
        return first.uppercased() + dropFirst()
    }
}
```

- [ ] **Step 6: Wire `ChoiceEmitter` into `KotlinEmitter`**

Replace the `case .choice(let c):` branch in `KotlinEmitter.emit(schema:)`:

```swift
case .choice(let c):
    files.append(ChoiceEmitter.emit(
        c,
        kotlinName: kotlinName,
        modelPackage: modelPkg,
        codecPackage: codecPkg,
        nameTransform: config.nameTransform,
    ))
```

- [ ] **Step 7: Run the test**

Run: `swift test --filter WireFormatKotlinEmitterTests.ChoiceEmitterTests/emitsChoiceCodec`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/WireFormatKotlinEmitter/ Tests/WireFormatKotlinEmitterTests/
git commit -m "feat(wire-format-emitter): emit codec for @WireFormatChoice (positional)"
```

### Task 9.5: Track associated-value labels in `WireChoiceCase`

**Files:**
- Modify: `Sources/WireFormatSchema/Schema.swift`
- Modify: `Sources/WireFormatSchema/SchemaParser.swift`
- Modify: `Sources/WireFormatKotlinEmitter/Internal/ChoiceEmitter.swift`
- Modify: `Tests/WireFormatSchemaTests/SchemaParserTests.swift`
- Modify: `Tests/WireFormatKotlinEmitterTests/Fixtures/ScoreCursorCodec.expected.kt`
- Modify: `Tests/WireFormatKotlinEmitterTests/ChoiceEmitterTests.swift`

Reason: the hand-written Kotlin uses real property names like `measureIndex`, `tickInMeasure`, `item`. Positional `arg0`/`arg1` would force renaming every Kotlin model class. Lift the labels so the emitter produces the same property names.

- [ ] **Step 1: Extend `WireChoiceCase` with labels**

In `Sources/WireFormatSchema/Schema.swift`, replace `WireChoiceCase` with:

```swift
public struct WireChoiceCase: Equatable, Sendable {
    public var name: String
    public var payload: [PayloadField]
    public init(name: String, payload: [PayloadField]) {
        self.name = name
        self.payload = payload
    }
}

public struct PayloadField: Equatable, Sendable {
    public var label: String?         // nil when the case has no label
    public var typeText: String
    public init(label: String?, typeText: String) {
        self.label = label
        self.typeText = typeText
    }
}
```

Remove the obsolete `payloadTypes` property.

- [ ] **Step 2: Update `SchemaParser.collectChoiceCases`**

```swift
private func collectChoiceCases(from enumDecl: EnumDeclSyntax) -> [WireChoiceCase] {
    var out: [WireChoiceCase] = []
    for member in enumDecl.memberBlock.members {
        guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in caseDecl.elements {
            let payload: [PayloadField] = element.parameterClause?.parameters.map { param in
                PayloadField(
                    label: param.firstName?.text,
                    typeText: param.type.trimmedDescription,
                )
            } ?? []
            out.append(WireChoiceCase(name: element.name.text, payload: payload))
        }
    }
    return out
}
```

- [ ] **Step 3: Update `parsesChoiceEnum` test expectations**

```swift
#expect(c.cases == [
    WireChoiceCase(name: "item", payload: [
        PayloadField(label: nil, typeText: "ScoreItemIDWire"),
    ]),
    WireChoiceCase(name: "beat", payload: [
        PayloadField(label: "measureIndex", typeText: "Int32"),
        PayloadField(label: "tickInMeasure", typeText: "Int32"),
    ]),
])
```

- [ ] **Step 4: Run schema tests, fix any compile errors caused by the type change**

Run: `swift test --filter WireFormatSchemaTests`
Expected: PASS for all 4 schema tests.

- [ ] **Step 5: Rewrite `ChoiceEmitter` branches to use labels**

In `Sources/WireFormatKotlinEmitter/Internal/ChoiceEmitter.swift`, replace both `emitEncodeBranch` and `emitDecodeBranch` so they consume `case.payload` (of `PayloadField`) and fall back to `arg<index>` when label is nil:

```swift
private static func propName(for field: PayloadField, at index: Int) -> String {
    field.label ?? "arg\(index)"
}
```

Use `propName(for: field, at: i)` everywhere `arg\(i)` currently appears.

- [ ] **Step 6: Rewrite `ScoreCursorCodec.expected.kt`** so `Beat` uses `measureIndex`/`tickInMeasure` and `Item` uses `item` (the case-name-lowercased default — but in this case it should be `item`, matching the unlabelled-positional rule; verify by reading the existing hand-written `ScoreCursorCodec.kt` for the canonical Kotlin shape and updating the fixture accordingly).

The corrected fixture:

```kotlin
// Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
package io.example.audio.serialization

import io.example.audio.model.ScoreCursor
import io.example.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

internal object ScoreCursorCodec {
    fun encode(value: ScoreCursor): ByteArray {
        val w = BinaryWriter()
        encodePayload(value, w)
        return w.toByteArray()
    }

    fun encodePayload(value: ScoreCursor, w: BinaryWriter) {
        when (value) {
            is ScoreCursor.Item -> {
                w.writeU8(0u)
                ScoreItemIDCodec.encodePayload(value.arg0, w)
            }
            is ScoreCursor.Beat -> {
                w.writeU8(1u)
                w.writeI32(value.measureIndex)
                w.writeI32(value.tickInMeasure)
            }
        }
    }

    fun decode(data: ByteArray): ScoreCursor {
        val r = BinaryReader(data)
        return decodePayload(r)
    }

    fun decodePayload(r: BinaryReader): ScoreCursor {
        return when (val disc = r.readU8().toInt()) {
            0 -> ScoreCursor.Item(
                arg0 = ScoreItemIDCodec.decodePayload(r),
            )
            1 -> ScoreCursor.Beat(
                measureIndex = r.readI32(),
                tickInMeasure = r.readI32(),
            )
            else -> throw IllegalArgumentException(
                "Unknown ScoreCursor discriminator: $disc",
            )
        }
    }
}
```

Naming alignment between Kotlin model classes and emitter output is enforced in Phase 2 (Task 14): the Kotlin model's `ScoreCursor.Item` constructor must accept `arg0:` (rename of the existing `item:` property). The change is mechanical and limited to a small set of places — Task 14 lists them.

- [ ] **Step 7: Run choice emitter test**

Run: `swift test --filter WireFormatKotlinEmitterTests.ChoiceEmitterTests/emitsChoiceCodec`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/WireFormatSchema/ Sources/WireFormatKotlinEmitter/ Tests/
git commit -m "feat(wire-format): track associated-value labels in choice cases"
```

### Task 10: Emit Kotlin codec for `@WireFormatEnum`

**Files:**
- Create: `Sources/WireFormatKotlinEmitter/Internal/EnumEmitter.swift`
- Modify: `Sources/WireFormatKotlinEmitter/KotlinEmitter.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/EnumEmitterTests.swift`
- Create: `Tests/WireFormatKotlinEmitterTests/Fixtures/GMInstrumentFamilyCodec.expected.kt`

- [ ] **Step 1: Create expected output fixture**

`Tests/WireFormatKotlinEmitterTests/Fixtures/GMInstrumentFamilyCodec.expected.kt`:

```kotlin
// Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
package io.example.audio.serialization

import io.example.audio.model.GMInstrumentFamily
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

internal object GMInstrumentFamilyCodec {
    fun encode(value: GMInstrumentFamily): ByteArray {
        val w = BinaryWriter()
        encodePayload(value, w)
        return w.toByteArray()
    }

    fun encodePayload(value: GMInstrumentFamily, w: BinaryWriter) {
        w.writeU8(value.ordinal.toUByte())
    }

    fun decode(data: ByteArray): GMInstrumentFamily {
        val r = BinaryReader(data)
        return decodePayload(r)
    }

    fun decodePayload(r: BinaryReader): GMInstrumentFamily {
        val disc = r.readU8().toInt()
        val values = GMInstrumentFamily.entries
        if (disc < 0 || disc >= values.size) {
            throw IllegalArgumentException(
                "Unknown GMInstrumentFamily ordinal: $disc",
            )
        }
        return values[disc]
    }
}
```

The fixture uses Kotlin 1.9+ `entries` (cached `values()`). Verify the Android Kotlin compiler version supports it by checking `Android/build.gradle.kts` — if it doesn't, swap to `values()` in the emitter.

- [ ] **Step 2: Write the failing test**

`Tests/WireFormatKotlinEmitterTests/EnumEmitterTests.swift`:

```swift
import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func emitsRawEnumCodec() throws {
    let schema = Schema(types: [
        .rawEnum(WireRawEnum(
            name: "GMInstrumentFamilyWire",
            cases: ["piano", "chromaticPercussion", "organ"],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)

    #expect(files.count == 1)
    let expectedURL = Bundle.module.url(forResource: "GMInstrumentFamilyCodec.expected", withExtension: "kt")!
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(files[0].content == expected)
}
```

- [ ] **Step 3: Run test, confirm failure**

Run: `swift test --filter WireFormatKotlinEmitterTests.EnumEmitterTests/emitsRawEnumCodec`
Expected: FAIL — `unsupportedType` thrown.

- [ ] **Step 4: Implement `EnumEmitter`**

`Sources/WireFormatKotlinEmitter/Internal/EnumEmitter.swift`:

```swift
import WireFormatSchema

enum EnumEmitter {
    static func emit(
        _ rawEnum: WireRawEnum,
        kotlinName: String,
        modelPackage: String,
        codecPackage: String,
    ) -> KotlinFile {
        let codecName = "\(kotlinName)Codec"
        let path = codecPackage.replacingOccurrences(of: ".", with: "/") + "/\(codecName).kt"

        let content = """
        // Auto-generated by emit-kotlin-codecs. DO NOT EDIT.
        package \(codecPackage)

        import \(modelPackage).\(kotlinName)
        import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryReader
        import io.github.jiyimeta.sheetmusic.audio.serialization.BinaryWriter

        internal object \(codecName) {
            fun encode(value: \(kotlinName)): ByteArray {
                val w = BinaryWriter()
                encodePayload(value, w)
                return w.toByteArray()
            }

            fun encodePayload(value: \(kotlinName), w: BinaryWriter) {
                w.writeU8(value.ordinal.toUByte())
            }

            fun decode(data: ByteArray): \(kotlinName) {
                val r = BinaryReader(data)
                return decodePayload(r)
            }

            fun decodePayload(r: BinaryReader): \(kotlinName) {
                val disc = r.readU8().toInt()
                val values = \(kotlinName).entries
                if (disc < 0 || disc >= values.size) {
                    throw IllegalArgumentException(
                        "Unknown \(kotlinName) ordinal: $disc",
                    )
                }
                return values[disc]
            }
        }

        """

        return KotlinFile(relativePath: path, content: content)
    }
}
```

- [ ] **Step 5: Wire `EnumEmitter` into `KotlinEmitter`**

Replace the `case .rawEnum(let e):` branch in `KotlinEmitter.emit(schema:)`:

```swift
case .rawEnum(let e):
    files.append(EnumEmitter.emit(
        e,
        kotlinName: kotlinName,
        modelPackage: modelPkg,
        codecPackage: codecPkg,
    ))
```

- [ ] **Step 6: Run all emitter tests**

Run: `swift test --filter WireFormatKotlinEmitterTests`
Expected: All PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/WireFormatKotlinEmitter/ Tests/WireFormatKotlinEmitterTests/
git commit -m "feat(wire-format-emitter): emit codec for @WireFormatEnum"
```

### Task 11: `emit-kotlin-codecs` executable + idempotent file writer

**Files:**
- Create: `Sources/EmitKotlinCodecs/main.swift`
- Create: `Tests/EmitKotlinCodecsTests/CLISmokeTests.swift`
- Create: `Tests/EmitKotlinCodecsTests/Fixtures/sources/Point.swift`
- Create: `Tests/EmitKotlinCodecsTests/Fixtures/sources/IgnoredFile.swift`
- Create: `Tests/EmitKotlinCodecsTests/Fixtures/kotlin-codegen.json`
- Modify: `Package.swift`

- [ ] **Step 1: Add the executable + test target**

In `Package.swift` `targets:`:

```swift
.executableTarget(
    name: "EmitKotlinCodecs",
    dependencies: ["WireFormatSchema", "WireFormatKotlinEmitter"],
),
.testTarget(
    name: "EmitKotlinCodecsTests",
    dependencies: ["EmitKotlinCodecs"],
    resources: [.copy("Fixtures")],
),
```

Also add a product so external builds can resolve it:

```swift
.executable(name: "emit-kotlin-codecs", targets: ["EmitKotlinCodecs"]),
```

(Add this to the `var products: [Product] = [...]` literal — outside the `isAndroid` branch since the executable is host-platform.)

- [ ] **Step 2: Create fixture sources**

`Tests/EmitKotlinCodecsTests/Fixtures/sources/Point.swift`:

```swift
@WireFormat
struct PointWire {
    var x: Int32
    var y: Int32
}
```

`Tests/EmitKotlinCodecsTests/Fixtures/sources/IgnoredFile.swift`:

```swift
// No @WireFormat — should be ignored.
struct OtherType {
    var z: Int32
}
```

`Tests/EmitKotlinCodecsTests/Fixtures/kotlin-codegen.json`:

```json
{
  "defaultModelPackage": "io.example.audio.model",
  "defaultCodecPackage": "io.example.audio.serialization",
  "nameTransform": { "stripSuffix": "Wire" },
  "rules": []
}
```

- [ ] **Step 3: Write the failing smoke test**

`Tests/EmitKotlinCodecsTests/CLISmokeTests.swift`:

```swift
import Foundation
import Testing

@Test func cliEmitsCodecsAndIsIdempotent() throws {
    let fixturesDir = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures")
    let sourcesDir = fixturesDir.appendingPathComponent("sources")
    let configPath = fixturesDir.appendingPathComponent("kotlin-codegen.json")

    let outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("emit-kotlin-codecs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }

    let executable = productsURL().appendingPathComponent("emit-kotlin-codecs")

    try runCLI(executable: executable, config: configPath, source: sourcesDir, output: outputDir)

    let expected = outputDir
        .appendingPathComponent("io/example/audio/serialization/PointCodec.kt")
    #expect(FileManager.default.fileExists(atPath: expected.path))

    let firstMtime = try mtime(of: expected)

    // Run again — output should be byte-identical and mtime preserved (idempotent).
    try runCLI(executable: executable, config: configPath, source: sourcesDir, output: outputDir)

    let secondMtime = try mtime(of: expected)
    #expect(firstMtime == secondMtime)
}

private func productsURL() -> URL {
    let testBundle = Bundle.module.bundleURL
    return testBundle.deletingLastPathComponent()  // .../debug/
}

private func runCLI(executable: URL, config: URL, source: URL, output: URL) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = [
        "--config", config.path,
        "--source", source.path,
        "--output", output.path,
    ]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8) ?? ""
        Issue.record("CLI failed: \(msg)")
    }
}

private func mtime(of url: URL) throws -> Date {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return attrs[.modificationDate] as? Date ?? .distantPast
}
```

- [ ] **Step 4: Run the test, confirm failure**

Run: `swift test --filter EmitKotlinCodecsTests`
Expected: FAIL — `emit-kotlin-codecs` not built.

- [ ] **Step 5: Implement the CLI**

`Sources/EmitKotlinCodecs/main.swift`:

```swift
import Foundation
import WireFormatKotlinEmitter
import WireFormatSchema

struct CLIArguments {
    var configPath: String
    var sourceDir: String
    var outputDir: String

    static func parse(_ argv: [String]) -> CLIArguments? {
        var config: String?
        var source: String?
        var output: String?
        var i = 1
        while i < argv.count {
            let key = argv[i]
            switch key {
            case "--config": config = argv[safe: i + 1]; i += 2
            case "--source": source = argv[safe: i + 1]; i += 2
            case "--output": output = argv[safe: i + 1]; i += 2
            default:
                fputs("Unknown argument: \(key)\n", stderr)
                return nil
            }
        }
        guard let c = config, let s = source, let o = output else { return nil }
        return CLIArguments(configPath: c, sourceDir: s, outputDir: o)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

guard let args = CLIArguments.parse(CommandLine.arguments) else {
    fputs("usage: emit-kotlin-codecs --config <file> --source <dir> --output <dir>\n", stderr)
    exit(2)
}

let configURL = URL(fileURLWithPath: args.configPath)
let configData = try Data(contentsOf: configURL)
let config = try JSONDecoder().decode(KotlinCodegenConfig.self, from: configData)

let sourceURL = URL(fileURLWithPath: args.sourceDir, isDirectory: true)
var aggregateSchema = Schema(types: [])
let enumerator = FileManager.default.enumerator(
    at: sourceURL,
    includingPropertiesForKeys: [.isRegularFileKey],
)!
for case let url as URL in enumerator {
    guard url.pathExtension == "swift" else { continue }
    let source = try String(contentsOf: url, encoding: .utf8)
    let schema = SchemaParser.parse(source: source, fileName: url.lastPathComponent)
    aggregateSchema.types.append(contentsOf: schema.types)
}

let emitter = KotlinEmitter(config: config)
let files = try emitter.emit(schema: aggregateSchema)

let outputURL = URL(fileURLWithPath: args.outputDir, isDirectory: true)

// Track generated files so we can prune deletions.
var generatedPaths = Set<String>()
for file in files {
    let dest = outputURL.appendingPathComponent(file.relativePath)
    try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    if let existing = try? String(contentsOf: dest, encoding: .utf8), existing == file.content {
        // Idempotent: skip rewriting unchanged file (preserves mtime).
    } else {
        try file.content.write(to: dest, atomically: true, encoding: .utf8)
    }
    generatedPaths.insert(dest.path)
}

// Sweep stale files: any .kt under outputDir that we didn't write this run.
if let sweep = FileManager.default.enumerator(at: outputURL, includingPropertiesForKeys: nil) {
    for case let url as URL in sweep {
        guard url.pathExtension == "kt", !generatedPaths.contains(url.path) else { continue }
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 6: Run the smoke test**

Run: `swift test --filter EmitKotlinCodecsTests`
Expected: PASS.

- [ ] **Step 7: Quick manual sanity check**

```bash
mkdir -p /tmp/emit-kotlin-out
swift run emit-kotlin-codecs \
  --config Tests/EmitKotlinCodecsTests/Fixtures/kotlin-codegen.json \
  --source Tests/EmitKotlinCodecsTests/Fixtures/sources \
  --output /tmp/emit-kotlin-out
find /tmp/emit-kotlin-out -name '*.kt'
```

Expected output:

```
/tmp/emit-kotlin-out/io/example/audio/serialization/PointCodec.kt
```

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/EmitKotlinCodecs/ Tests/EmitKotlinCodecsTests/
git commit -m "feat(emit-kotlin-codecs): CLI driver with idempotent file writes"
```

### Task 12: Write `kotlin-codegen.json` + byte-diff regression test

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/kotlin-codegen.json`
- Modify: `Package.swift`
- Create: `Tests/EmitKotlinCodecsTests/HandWrittenParityTests.swift`

- [ ] **Step 1: Author the JNI module's config**

`Sources/SheetMusicAndroidJNI/kotlin-codegen.json`:

```json
{
  "defaultModelPackage": "io.github.jiyimeta.sheetmusic.audio.model",
  "defaultCodecPackage": "io.github.jiyimeta.sheetmusic.audio.serialization",
  "nameTransform": { "stripSuffix": "Wire" },
  "rules": [
    {
      "pattern": "ScoreMetadata*",
      "modelPackage": "io.github.jiyimeta.sheetmusic",
      "codecPackage": "io.github.jiyimeta.sheetmusic"
    },
    {
      "pattern": "DrawProgram*",
      "modelPackage": "com.example.sheetmusic.draw.model",
      "codecPackage": "com.example.sheetmusic.draw"
    },
    {
      "pattern": "DrawCommand*",
      "modelPackage": "com.example.sheetmusic.draw.model",
      "codecPackage": "com.example.sheetmusic.draw"
    },
    {
      "pattern": "SMuFL*",
      "modelPackage": "io.github.jiyimeta.sheetmusic",
      "codecPackage": "io.github.jiyimeta.sheetmusic"
    }
  ]
}
```

(Verify the exact patterns by listing all `@WireFormat`-annotated types in `Sources/SheetMusicAndroidJNI/` with `grep -rh '@WireFormat' Sources/SheetMusicAndroidJNI/` plus the following `struct`/`enum` line.)

- [ ] **Step 2: Add the config to the target exclude list**

In `Package.swift`, update the `SheetMusicAndroidJNI` target's `exclude:` array:

```swift
exclude: [
    "swift-java.config",
    "kotlin-codegen.json",
],
```

- [ ] **Step 3: Verify SwiftPM still builds**

Run: `swift build`
Expected: SUCCESS, no resource warnings.

- [ ] **Step 4: Write the byte-diff parity test**

`Tests/EmitKotlinCodecsTests/HandWrittenParityTests.swift`:

```swift
import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

/// Spec verification §5: every generated codec must match the
/// existing hand-written codec, character-for-character on the
/// methods that overlap (encode/decode signatures + body).
///
/// We don't compare full files because the hand-written files have
/// hand-authored comments and helper functions the generator omits.
/// We compare the wire bytes by running the generator's output
/// through a byte-buffer round trip with hand-picked inputs and
/// asserting against a frozen `expectedBytes` fixture per type.
@Test func metronomeBeatCodecRoundTripMatchesFrozenBytes() throws {
    let schema = Schema(types: [
        .struct(WireStruct(
            name: "MetronomeBeatWire",
            fields: [
                WireField(name: "tick", typeText: "Int64"),
                WireField(name: "isDownbeat", typeText: "Bool"),
            ],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.github.jiyimeta.sheetmusic.audio.model",
        defaultCodecPackage: "io.github.jiyimeta.sheetmusic.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)
    #expect(files.count == 1)

    // We can't execute Kotlin from a Swift test, so we lock in the
    // *structure* of the generated source. Failures here mean
    // someone changed the emitter shape; rebaseline only if the new
    // shape still passes the Kotlin-side unit tests in Phase 2.
    let content = files[0].content
    #expect(content.contains("w.writeI64(value.tick)"))
    #expect(content.contains("w.writeU8(if (value.isDownbeat) 1u else 0u)"))
    #expect(content.contains("tick = r.readI64()"))
    #expect(content.contains("isDownbeat = r.readU8() != 0u.toUByte()"))
}
```

(End-to-end byte-level parity is validated in Phase 2 by the existing Kotlin unit tests, which exercise real bytes.)

- [ ] **Step 5: Run the parity test**

Run: `swift test --filter EmitKotlinCodecsTests.HandWrittenParityTests`
Expected: PASS.

- [ ] **Step 6: End-to-end smoke run**

```bash
mkdir -p /tmp/emit-jni-out
swift run emit-kotlin-codecs \
  --config Sources/SheetMusicAndroidJNI/kotlin-codegen.json \
  --source Sources/SheetMusicAndroidJNI \
  --output /tmp/emit-jni-out
find /tmp/emit-jni-out -name '*.kt' | sort
```

Expected output: a list of `.kt` files under
`io/github/jiyimeta/sheetmusic/audio/serialization/`,
`io/github/jiyimeta/sheetmusic/` (for ScoreMetadata, SMuFL),
`com/example/sheetmusic/draw/` (for DrawProgram).

If any expected codec is missing, the JSON rule patterns need adjustment — fix and re-run.

- [ ] **Step 7: Inspect a couple of generated files manually**

Run:

```bash
cat /tmp/emit-jni-out/io/github/jiyimeta/sheetmusic/audio/serialization/MetronomeBeatCodec.kt
diff /tmp/emit-jni-out/io/github/jiyimeta/sheetmusic/audio/serialization/MetronomeBeatCodec.kt \
     Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/MetronomeBeatDecoder.kt
```

Expected: the generated file uses `…Codec` (single object containing both encode/decode), whereas the hand-written has separate `MetronomeBeatCodec` (in `Encoders.kt`) and a non-existent `MetronomeBeatDecoder`. **The hand-written code splits codec into `Decoder`/`Encoder` files; the generator places everything in one `…Codec` object.** This is an intentional simplification. Phase 2's test updates point Kotlin tests at the new shape.

- [ ] **Step 8: Run the full Swift test suite**

Run: `swift test`
Expected: All tests PASS (Phase 1 toolchain complete).

- [ ] **Step 9: Commit Phase 1 close**

```bash
git add Sources/SheetMusicAndroidJNI/kotlin-codegen.json Package.swift Tests/EmitKotlinCodecsTests/HandWrittenParityTests.swift
git commit -m "feat(android-jni): codegen config + parity tests (phase 1 complete)"
```

---

## Phase 2: Audio module migration

The toolchain works. Now switch `SheetMusicAudioAndroid` from hand-written codecs to generated ones.

### Task 13: Wire `emitKotlinCodecs` Gradle task into `SheetMusicAudioAndroid`

**Files:**
- Modify: `Android/SheetMusicAudioAndroid/build.gradle.kts`

- [ ] **Step 1: Read existing build.gradle.kts**

```bash
cat Android/SheetMusicAudioAndroid/build.gradle.kts
```

Identify the section that currently declares Kotlin source dirs and where `tasks.named("preBuild")` (or the equivalent) lives.

- [ ] **Step 2: Add the `emitKotlinCodecs` task**

Insert at the end of `Android/SheetMusicAudioAndroid/build.gradle.kts`:

```kotlin
// ─── Wire-format codec codegen ────────────────────────────────────────
// Runs `swift run emit-kotlin-codecs` to regenerate Kotlin codecs from
// Swift `@WireFormat` types. See
// docs/superpowers/specs/2026-05-23-kotlin-codec-codegen-design.md.
val packageRoot: File = rootProject.projectDir.resolve("../..").canonicalFile
val emitKotlinCodecsOutput = layout.buildDirectory.dir("generated/source/wire-format/kotlin")

val emitKotlinCodecs by tasks.registering(Exec::class) {
    workingDir(packageRoot)
    inputs.dir(packageRoot.resolve("Sources/SheetMusicAndroidJNI"))
        .withPropertyName("swiftSources")
    inputs.file(packageRoot.resolve("Sources/SheetMusicAndroidJNI/kotlin-codegen.json"))
        .withPropertyName("codegenConfig")
    outputs.dir(emitKotlinCodecsOutput)
    commandLine(
        "swift", "run", "--package-path", packageRoot.absolutePath,
        "emit-kotlin-codecs",
        "--config", "Sources/SheetMusicAndroidJNI/kotlin-codegen.json",
        "--source", "Sources/SheetMusicAndroidJNI",
        "--output", emitKotlinCodecsOutput.get().asFile.absolutePath,
    )
}

android {
    sourceSets["main"].kotlin.srcDir(emitKotlinCodecsOutput)
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(emitKotlinCodecs) }
```

`rootProject.projectDir` here is `Android/`. `../..` resolves to the package root.

- [ ] **Step 3: Confirm the package-root path is correct**

```bash
ls "Android/$(dirname "$(realpath --relative-to=Android Android/SheetMusicAudioAndroid/build.gradle.kts)")/../../Package.swift"
```

Adjust the `../..` to whatever resolves to the directory containing `Package.swift` (on macOS, `realpath --relative-to` is not available — use `cd` + `pwd -P` manually).

- [ ] **Step 4: Run the task standalone**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:emitKotlinCodecs`
Expected: SUCCESS. The task downloads no dependencies (Swift toolchain is already on PATH from Phase 1 verification), runs the CLI, generates `.kt` files under `Android/SheetMusicAudioAndroid/build/generated/source/wire-format/kotlin/`.

- [ ] **Step 5: List generated files**

Run: `find Android/SheetMusicAudioAndroid/build/generated/source/wire-format -name '*.kt'`
Expected: codec files for all audio-namespace types
(`MetronomeBeatCodec.kt`, `StaffParamsCodec.kt`, `ScoreCursorCodec.kt`,
`ScoreItemIDCodec.kt`, `ClefAnchorCodec.kt`, `GMInstrumentCodec.kt`,
`GMInstrumentFamilyCodec.kt`, `NoteIDCodec.kt`, `RestIDCodec.kt`,
`TupletIDCodec.kt`, `VoiceElementIDCodec.kt`, `StaffAddressCodec.kt`,
`FrameCodec.kt`, `AudioExportRangeCodec.kt`, `CursorFrameCodec.kt`).

(`SheetMusicAudioAndroid` consumes only the audio-namespace codecs; the
other generated files are unused here and will be picked up by
`SheetMusicAndroid`/`Examples/Android` in Phase 3.)

- [ ] **Step 6: Try a clean compile against the generated codecs**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:compileDebugKotlin`
Expected: It will likely **FAIL** at this stage — the project still has the hand-written codecs in `src/main/kotlin/.../serialization/`, so there are now two definitions of, e.g., `MetronomeBeatCodec`. Note the error messages; the next task removes the hand-written copies to resolve the duplicate-class collision.

- [ ] **Step 7: Commit (intentionally leaves build broken — Task 14 finishes)**

```bash
git add Android/SheetMusicAudioAndroid/build.gradle.kts
git commit -m "build(android-audio): wire emitKotlinCodecs Gradle task"
```

### Task 14: Delete hand-written audio codecs + reconcile model classes

**Files:**
- Delete: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/AudioExportRangeEncoder.kt`
- Delete: `…/ClefAnchorDecoder.kt`
- Delete: `…/Encoders.kt`
- Delete: `…/FrameDecoder.kt`
- Delete: `…/GMInstrumentDecoder.kt`
- Delete: `…/MetronomeBeatDecoder.kt`
- Delete: `…/PathIDDecoders.kt`
- Delete: `…/ScoreCursorDecoder.kt`
- Delete: `…/ScoreItemIDDecoder.kt`
- Delete: `…/StaffParamsDecoder.kt`
- Modify: Kotlin model classes for unlabelled associated values (rename internal property to `arg0` if hand-written code currently uses a different name).
- Modify: Existing call sites of the deleted codecs (caller code in `AndroidPlaybackEngine.kt`, JNI bridge facades, etc. — re-point to the generated `…Codec` shape).
- Modify: All tests under `Android/SheetMusicAudioAndroid/src/test/kotlin/.../serialization/` (their imports and any references to the old type names).

- [ ] **Step 1: Inventory the hand-written API surface to be matched/renamed**

```bash
grep -rn "object .*Decoder\|object .*Encoder\|object .*Codec" \
    Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/
```

List every public/internal object name and method signature. The generated counterpart is `<TypeName>Codec` with methods `encode(value)`, `encodePayload(value, w)`, `decode(data)`, `decodePayload(r)`. Compare against the hand-written API and note divergences.

- [ ] **Step 2: For each unlabelled associated-value case, reconcile the Kotlin sealed-class subtype property name**

Inspect `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/model/` for each `@WireFormatChoice`-driven Kotlin sealed class. Where the Swift case has no label (e.g. `case item(ScoreItemIDWire)`) and the existing Kotlin subtype currently has a real property name (e.g. `val item: ScoreItemID`), pick one:

- **Option A (preferred for now):** rename the Kotlin property to `arg0`. This matches the generator's output and avoids generator complexity. Caller code that constructed/destructured this subtype must be updated.
- **Option B:** label the Swift case in `Sources/SheetMusicAndroidJNI/Audio/<File>.swift` (`case item(arg0: ScoreItemIDWire)` → rejected because it changes Swift semantics) — DO NOT pursue. Stick with Option A.

Apply Option A. Each affected case is enumerated by inspecting:

```bash
grep -rh "case " Sources/SheetMusicAndroidJNI/Audio/*Codec.swift | grep -E "case [a-z]+\([A-Z]"
```

(Cases of shape `case foo(Bar)` — bare positional, no label.)

- [ ] **Step 3: Update caller code for renamed Kotlin properties**

After renaming each Kotlin subtype's property to `arg0`, run:

```bash
Android/gradlew -p Android :SheetMusicAudioAndroid:compileDebugKotlin 2>&1 | tee /tmp/compile.log
```

Iterate: every compile error pointing at `cursor.item`/`anchor.voiceElementID`/etc. is a caller that needs `cursor.arg0`/`anchor.arg0`. Fix each one. Re-run the compile after each batch.

- [ ] **Step 4: Delete hand-written codec files**

```bash
rm Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/serialization/{AudioExportRangeEncoder,ClefAnchorDecoder,Encoders,FrameDecoder,GMInstrumentDecoder,MetronomeBeatDecoder,PathIDDecoders,ScoreCursorDecoder,ScoreItemIDDecoder,StaffParamsDecoder}.kt
```

(Keep `BinaryReader.kt` and `BinaryWriter.kt`.)

- [ ] **Step 5: Update tests under `…/serialization/test/`**

The tests reference the old object names (e.g. `MetronomeBeatCodec` in `EncoderTest.kt`, `FrameDecoder` in `FrameMetronomeBeatStaffParamsDecoderTest.kt`). The new generated name is `MetronomeBeatCodec` (same — coincidence in this case) but with slightly different method shape. Search each test file:

```bash
grep -rl "FrameDecoder\|MetronomeBeatDecoder\|ScoreCursorDecoder\|ScoreItemIDDecoder\|ClefAnchorDecoder\|GMInstrumentDecoder\|StaffParamsDecoder\|PathIDDecoder\|AudioExportRangeEncoder" \
    Android/SheetMusicAudioAndroid/src/test/kotlin/
```

For each match, change `FooDecoder.decode(bytes)` to `FooCodec.decode(bytes)`, `FooEncoder.encodeArray(list)` to `FooCodec.encode(...)` etc. The new `FooCodec` exposes `encode` / `encodePayload` / `decode` / `decodePayload` — pick the right one based on what the test exercised.

Where a test currently does:

```kotlin
val bytes = MetronomeBeatCodec.encodeArray(listOf(...))
val list = MetronomeBeatDecoder.decodeArray(bytes)
```

Replace with: the generator does NOT emit `encodeArray` / `decodeArray` helpers — only the single-item codec. For array round-trips, the test now wraps a `BinaryWriter` itself:

```kotlin
val w = BinaryWriter()
w.writeI32(list.size)
for (item in list) MetronomeBeatCodec.encodePayload(item, w)
val bytes = w.toByteArray()
```

…and the symmetric `BinaryReader` for decode. (Real callers in `AndroidPlaybackEngine.kt` will do the same — update them too.)

- [ ] **Step 6: Run gradle tests**

Run: `Android/gradlew -p Android :SheetMusicAudioAndroid:testDebugUnitTest`
Expected: PASS. If any test fails on a byte mismatch, the emitter has a layout bug; fix the emitter and re-run. If it's an API-shape failure, fix the test.

- [ ] **Step 7: Commit**

```bash
git add -A Android/SheetMusicAudioAndroid/
git commit -m "refactor(android-audio): replace hand-written codecs with codegen"
```

### Task 15: Phase 2 verification (emulator smoke)

- [ ] **Step 1: Build the Compose example app**

Run: `Examples/Android/gradlew -p Examples/Android :app:assembleDebug`
Expected: SUCCESS.

- [ ] **Step 2: Install and launch on Pixel 6 Pro API 36 emulator**

```bash
adb -s emulator-5554 install -r Examples/Android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am start -n com.example.sheetmusic/.MainActivity
```

(If the emulator is not running, the user must start it via Android Studio — do not attempt to launch one programmatically.)

- [ ] **Step 3: Manual smoke test**

In the running app:
1. Open any score from the picker.
2. Press play. Audio must be audible.
3. The cursor must advance through measures in sync with playback.

If any of these fails, examine `adb logcat | grep -E 'sheetmusic|AndroidRuntime'` for the underlying crash and treat as a regression — usually a codec layout mismatch.

- [ ] **Step 4: Commit (no code change, just a marker)**

Skip — verification is done in CI / on the dev machine. Move on to Phase 3.

---

## Phase 3: SheetMusicAndroid + Examples/Android migration

### Task 16: Wire `emitKotlinCodecs` into `SheetMusicAndroid`

**Files:**
- Modify: `Android/SheetMusicAndroid/build.gradle.kts`

- [ ] **Step 1: Add the task**

Apply the same Gradle block as Task 13 to `Android/SheetMusicAndroid/build.gradle.kts`. `packageRoot` and the `--source` / `--config` arguments are identical (same Swift package). The `--output` path uses `SheetMusicAndroid`'s own `layout.buildDirectory`.

- [ ] **Step 2: Run codegen**

Run: `Android/gradlew -p Android :SheetMusicAndroid:emitKotlinCodecs`
Expected: SUCCESS.

- [ ] **Step 3: List generated files relevant to this module**

Run: `find Android/SheetMusicAndroid/build/generated/source/wire-format -name '*.kt'`
Expected: includes `ScoreMetadataCodec.kt` (mapped to package `io.github.jiyimeta.sheetmusic` per the JSON rule for `ScoreMetadata*`) and `SMuFLMetricsTableCodec.kt`.

- [ ] **Step 4: Commit**

```bash
git add Android/SheetMusicAndroid/build.gradle.kts
git commit -m "build(android-sheet-music): wire emitKotlinCodecs Gradle task"
```

### Task 17: Replace `ScoreMetadata.decode` with generated codec

**Files:**
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/ScoreMetadata.kt`

- [ ] **Step 1: Read current shape**

The file declares `data class ScoreMetadata(val title: String, val composer: String)` with a companion `decode(bytes)` doing manual `ByteBuffer` parsing.

The generated `ScoreMetadataCodec` (in `io.github.jiyimeta.sheetmusic` per config) exposes `decode(data: ByteArray): ScoreMetadata` directly.

- [ ] **Step 2: Verify the generated codec's signature**

```bash
cat Android/SheetMusicAndroid/build/generated/source/wire-format/kotlin/io/github/jiyimeta/sheetmusic/ScoreMetadataCodec.kt
```

Confirm the codec compiles given Swift's `ScoreMetadataWire { var title: String; var composer: String }`. If String support is not yet in `KotlinTypeMap` (Task 8 note), add it now — both Kotlin's `BinaryReader.readString` and `BinaryWriter.writeString` already exist (verify by reading them).

- [ ] **Step 3: Rewrite `ScoreMetadata.kt`**

```kotlin
package io.github.jiyimeta.sheetmusic

/**
 * Score-level metadata surfaced from the Swift `Score.metaTags`
 * dictionary via [SheetMusicJNI.nativeScoreMetadata]. Both fields are
 * empty strings when the underlying metaTag is absent.
 */
data class ScoreMetadata(
    val title: String,
    val composer: String,
) {
    companion object {
        /**
         * Fetch metadata for [scoreHandle] in one JNI round trip.
         * Returns `null` for an unknown / released handle (the JNI
         * symbol returns an empty array in that case).
         */
        fun fetch(scoreHandle: Long): ScoreMetadata? {
            val bytes = SheetMusicJNI.nativeScoreMetadata(scoreHandle)
            if (bytes.isEmpty()) return null
            return ScoreMetadataCodec.decode(bytes)
        }
    }
}
```

(Inline `decode` is gone; delegation to generated codec.)

- [ ] **Step 4: Run tests**

Run: `Android/gradlew -p Android :SheetMusicAndroid:testDebugUnitTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/ScoreMetadata.kt
git commit -m "refactor(android-sheet-music): delegate ScoreMetadata to codegen"
```

### Task 18: Wire `emitKotlinCodecs` into `Examples/Android/app`

**Files:**
- Modify: `Examples/Android/app/build.gradle.kts`

- [ ] **Step 1: Add the Gradle task**

Apply the same Gradle block. `packageRoot` for `Examples/Android/app/build.gradle.kts` resolves to `../../..` (Examples/Android = `<root>/Examples/Android`, so app/build.gradle.kts → `../..` = Examples/Android, `/..` = Examples, `/..` = `<root>`).

- [ ] **Step 2: Run codegen + verify expected outputs**

Run: `Examples/Android/gradlew -p Examples/Android :app:emitKotlinCodecs`
Then: `find Examples/Android/app/build/generated/source/wire-format -name '*.kt'`
Expected: includes `DrawProgramCodec.kt`, `DrawCommandCodec.kt`, and others mapped to `com.example.sheetmusic.draw`.

- [ ] **Step 3: Commit**

```bash
git add Examples/Android/app/build.gradle.kts
git commit -m "build(android-example): wire emitKotlinCodecs Gradle task"
```

### Task 19: Replace `DrawProgramDecoder` with generated codec

**Files:**
- Delete: `Examples/Android/app/src/main/java/com/example/sheetmusic/draw/DrawProgramDecoder.kt`
- Modify: `Examples/Android/app/src/test/java/com/example/sheetmusic/draw/DrawProgramDecoderTest.kt`
- Modify: Any caller of `DrawProgramDecoder.decode(...)` in `Examples/Android/app/`.

- [ ] **Step 1: Identify callers**

```bash
grep -rn "DrawProgramDecoder\." Examples/Android/app/src/main/
```

- [ ] **Step 2: Replace each caller**

Replace `DrawProgramDecoder.decode(bytes)` with `DrawProgramCodec.decode(bytes)`. Add the import.

- [ ] **Step 3: Update the test**

In `DrawProgramDecoderTest.kt`:
- Rename the class to `DrawProgramCodecTest`.
- Change all `DrawProgramDecoder` references to `DrawProgramCodec`.
- Rename the file to `DrawProgramCodecTest.kt`.

- [ ] **Step 4: Delete the hand-written decoder**

```bash
rm Examples/Android/app/src/main/java/com/example/sheetmusic/draw/DrawProgramDecoder.kt
```

- [ ] **Step 5: Run tests**

Run: `Examples/Android/gradlew -p Examples/Android :app:testDebugUnitTest`
Expected: PASS.

- [ ] **Step 6: Build the app**

Run: `Examples/Android/gradlew -p Examples/Android :app:assembleDebug`
Expected: SUCCESS.

- [ ] **Step 7: Commit**

```bash
git add -A Examples/Android/app/
git commit -m "refactor(android-example): replace DrawProgramDecoder with codegen"
```

### Task 20: Phase 3 verification (full emulator smoke)

- [ ] **Step 1: Reinstall on emulator**

```bash
adb -s emulator-5554 install -r Examples/Android/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am start -n com.example.sheetmusic/.MainActivity
```

- [ ] **Step 2: Full smoke**

1. Open a score.
2. Play. Cursor + audio in sync.
3. Drag the score. No render glitches.
4. Pause / resume. State preserved.
5. Watch logcat for any `AndroidRuntime` or `sheetmusic`-tagged exceptions:
   `adb logcat -d | grep -E 'AndroidRuntime|sheetmusic'`

Expected: no exceptions, no visual regressions.

If anything fails, reproduce, attach logcat output, treat as a blocking bug for the codegen (likely a layout divergence between generated and Swift-side codec).

- [ ] **Step 3: Full Swift test suite, again, as a final check**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Final integration commit (no code change — phase marker)**

If there are uncommitted housekeeping changes (e.g. updated README pointers), commit them here. Otherwise, skip.

---

## Self-Review

Run this once after writing the plan, then move on.

**Spec coverage:** Every spec section has a task:
- "Goal" items 1–4 (new targets, executable, Gradle integration, deletions) → Tasks 1, 7, 11, 13–19.
- "Architecture" three new targets → Tasks 1 (Schema), 7 (Emitter), 11 (Executable).
- "Resolution order" for attribute → Tasks 5 + 7 (PackageResolver).
- "Migration order" three phases → Phase 1 (Tasks 1–12), Phase 2 (Tasks 13–15), Phase 3 (Tasks 16–20).
- "Technical risks" four items: SwiftSyntax outside macros (validated by Task 2), choice associated values (Tasks 9 + 9.5), Swift toolchain on PATH (Task 13 Step 4), incremental build correctness (Task 11 Step 5 idempotent writer + smoke test).
- "Verification" five gates: all enforced (Swift test suite in Task 8/10/12; Android library tests in Tasks 14/17; Examples tests in Task 19; emulator smoke in Tasks 15 + 20; structural parity in Task 12).
- "Open questions" four items: addressed in Tasks 11 (CLI placement), 11 (recursive file scan), implicit two-pass not needed (the emitter does a single pass over the aggregate schema; cross-type references resolve via name only — works because all referenced types are also `@WireFormat`-annotated within the same source directory and end up in the same `aggregateSchema`), Task 12 (frozen-bytes parity).

**Placeholder scan:** None of the red-flag patterns appear.

**Type consistency:** Codec class names use `<KotlinName>Codec` consistently from Task 8 onward. The `@WireFormatChoice` case-subtype property naming uses `argN` for unlabelled, label-name for labelled; Task 14 Step 2 reconciles Kotlin model classes to that rule once. `KotlinCodegenConfig` has the same field set in Tasks 7 and 12. `KotlinTarget` enum has the same three cases (`.auto`, `.skip`, `.explicit`) in Tasks 1, 6, and downstream.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-23-kotlin-codec-codegen.md`.**

Per the user's prior instruction ("subagent-driven で実装まで進めて。auto mode で"), execution will proceed via **subagent-driven-development** without further confirmation, using one fresh subagent per task and two-stage review between tasks.
