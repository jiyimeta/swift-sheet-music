# MSCX `<Harmony>` import + chord-symbol display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode MuseScore `<Harmony>` elements from `.mscx` and render them as chord symbols above the staff (`C`, `Am7`, `F#m7b5/A`, Roman `bIII`), with ASCII `b` / `#` substituted by Bravura SMuFL accidental glyphs.

**Architecture:** New `Harmony` value type lives in `SheetMusicCore`; `MSCXDecoder+Harmony` parses the XML; layout adds a `LayoutHarmony` wrapper that pre-computes mixed text + SMuFL-glyph runs and the resulting width; renderers (both the `ScoreCanvas` GraphicsContext path and the `ScoreLayerBuilder` CALayer path) draw the runs through `ResolvedTextStyle` for the text and `BravuraFont` for the accidental glyphs. Placement reuses the above-staff stacking pipeline that already serves `StaffText` and `RehearsalMark`.

**Tech Stack:** Swift 5.9 / Swift Testing, Foundation `XMLParser`, CoreText, SwiftUI `GraphicsContext`, CALayer.

---

## Spec adaptations (read first)

Two small departures from `docs/superpowers/specs/2026-05-04-mscx-harmony-chord-symbols-design.mdx`:

1. **`SMuFLGlyph` is a namespace of static `Character` constants, not an enum**, so the spec's `case smuflAccidental(SMuFLGlyph)` cannot be written verbatim. We define a four-case enum `HarmonyAccidental` (in `LayoutHarmony.swift`) for the accidentals and map each case to the existing `SMuFLGlyph.accidental*` `Character` constants at draw time. No new cases are added to `SMuFLGlyph`.

2. **`ResolvedTextStyle.resolve` actual signature is `(_ style: TextStyleType, overrides: TextProperties = TextProperties(), metrics: StaffMetrics) -> Resolution`.** The renderer code in this plan uses that real signature — the spec's pseudo-call (`properties:styleType:scoreStyle:`) is informal.

Everything else follows the spec.

---

## File structure

**Create**

- `Sources/SheetMusicCore/Score/Harmony.swift` — the `Harmony` struct + `HarmonyType` / `NoteCase` enums.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Harmony.swift` — `Harmony.decode(_:)`.
- `Sources/SheetMusicLayout/Layout/LayoutHarmony.swift` — `LayoutHarmony`, `HarmonyRun`, `HarmonyAccidental`.
- `Sources/SheetMusicLayout/Layout/HarmonyRendering.swift` — pure run-builder + width measurement (text via CoreText, glyphs via Bravura).
- `Sources/SheetMusicUI/Rendering/HarmonyRenderer.swift` — GraphicsContext draw helper used by `ScoreCanvas`.
- `Tests/SheetMusicTests/Resources/harmony-basic.mscx` — hand-authored MIT test fixture.
- `Tests/SheetMusicTests/HarmonyTests.swift` — decode + substitution + layout suites.
- `Sources/RenderPreviews/HarmonyPreview.swift` — `#Preview` block loading the fixture.

**Modify**

- `Sources/SheetMusicCore/Score/VoiceElement.swift` — add `case harmony(Harmony)` between `.staffText` and `.rehearsalMark`.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffText.swift` — promote `decodeColor`, `decodeOffset`, `plainText(of:)` from `private static` to `static` (file-internal) so `MSCXDecoder+Harmony` can reuse them.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` — add `case "Harmony": ...` adjacent to `StaffText` / `SystemText`.
- `Sources/SheetMusicLayout/Layout/LayoutElement.swift` — add `case harmony(LayoutHarmony)`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift` — shift `.harmony` by `dy`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — emit `.harmony` from the voice loop.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift` — register `.harmony` in `aboveStaffPriority` / `aboveStaffHeight` / `aboveStaffAnchor` / `setAboveStaffOriginY` / `collectAboveStaffEntries`.
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift` — fold harmony width into the chord-segment weight in `aggregatedTickWeights`.
- `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift` — dispatch `.harmony` to `HarmonyRenderer.draw`.
- `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift` — CALayer dispatch arm for `.harmony`.
- `Tests/SheetMusicTests/Resources/LICENSE` — append `harmony-basic.mscx` to the MIT-licensed fixtures section.

---

## Conventions for every task

- TDD: write the failing test first, run it, watch it fail, then implement.
- Build/test commands run from the package root (`/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`):
  - `swift test --filter HarmonyTests` for the new suite.
  - `swift test` to confirm no regressions across the existing 100%-green suite.
  - `swiftlint --quiet Sources Tests` if SwiftLint is installed (optional, must stay 0/0).
- Commit at the end of each task.

---

## Task 1: Core `Harmony` model + `VoiceElement.harmony` case

**Files:**
- Create: `Sources/SheetMusicCore/Score/Harmony.swift`
- Modify: `Sources/SheetMusicCore/Score/VoiceElement.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write the failing test (model shape only)**

Create `Tests/SheetMusicTests/HarmonyTests.swift` with the bare minimum to lock the type's surface:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

@Suite struct HarmonyTests {
    @Test func defaultsAreInert() {
        let h = Harmony(name: "C")
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
        #expect(h.rootCase == .auto)
        #expect(h.bassCase == .auto)
        #expect(h.leftParen == false)
        #expect(h.rightParen == false)
        #expect(h.play == true)
        #expect(h.offsetX == 0)
        #expect(h.offsetY == 0)
        #expect(h.color == nil)
        #expect(h.styleType == .chordSymbolA)
    }

    @Test func styleTypeFollowsHarmonyType() {
        #expect(Harmony(name: "C", harmonyType: .standard).styleType
                == .chordSymbolA)
        #expect(Harmony(name: "I", harmonyType: .roman).styleType
                == .chordSymbolRomanNumeral)
        #expect(Harmony(name: "1", harmonyType: .nashville).styleType
                == .chordSymbolA)
    }

    @Test func voiceElementHarmonyCaseExists() {
        let element: VoiceElement = .harmony(Harmony(name: "C"))
        guard case let .harmony(h) = element else {
            Issue.record("expected .harmony case")
            return
        }
        #expect(h.name == "C")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter HarmonyTests 2>&1 | tail -20`
Expected: build error — `Harmony` is undefined and `VoiceElement` has no `.harmony` case.

- [ ] **Step 3: Create `Sources/SheetMusicCore/Score/Harmony.swift`**

```swift
import Foundation

/// Chord symbol attached to a voice position. Source of truth for
/// rendering is `name`; the TPC/case fields are preserved so future
/// transposition / playback work can use them without re-parsing.
///
/// C++: `mu::engraving::Harmony` (`engraving/dom/harmony.cpp`).
public struct Harmony: Sendable, Equatable {
    /// Display string. Rendered with ASCII `b` / `#` substituted by
    /// Bravura SMuFL accidentals at layout time.
    public var name: String
    public var harmonyType: HarmonyType
    /// Root tonal-pitch-class. `nil` ↔ MuseScore `TPC_INVALID` (-1).
    public var rootTpc: Int?
    public var rootCase: NoteCase
    /// Slash-bass TPC. `nil` ↔ MuseScore `TPC_INVALID` (-1). MSCX
    /// spells the field as `<base>` (historical) — not `<bass>`.
    public var bassTpc: Int?
    public var bassCase: NoteCase
    public var leftParen: Bool
    public var rightParen: Bool
    /// MuseScore preserves a per-symbol playback flag. We keep it
    /// for future MIDI realisation; the default renderer ignores it.
    public var play: Bool
    /// Author-supplied X offset (spatium units).
    public var offsetX: Double
    /// Author-supplied Y offset (spatium units, positive = down).
    public var offsetY: Double
    /// Author-supplied colour (RGBA 0..255). Nil = inherit.
    public var color: ScoreColor?
    /// Per-element font overrides. `nil`-fields inherit from
    /// `styleType`'s row in `TextStyleDefaults`.
    public var properties: TextProperties

    public init(
        name: String,
        harmonyType: HarmonyType = .standard,
        rootTpc: Int? = nil,
        rootCase: NoteCase = .auto,
        bassTpc: Int? = nil,
        bassCase: NoteCase = .auto,
        leftParen: Bool = false,
        rightParen: Bool = false,
        play: Bool = true,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        properties: TextProperties = TextProperties()
    ) {
        self.name = name
        self.harmonyType = harmonyType
        self.rootTpc = rootTpc
        self.rootCase = rootCase
        self.bassTpc = bassTpc
        self.bassCase = bassCase
        self.leftParen = leftParen
        self.rightParen = rightParen
        self.play = play
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.color = color
        self.properties = properties
    }

    /// The `TextStyleType` row this element inherits from. Roman
    /// numerals use Campania (`.chordSymbolRomanNumeral`); Standard
    /// and Nashville share `.chordSymbolA` (Edwin 10 pt).
    public var styleType: TextStyleType {
        switch harmonyType {
        case .standard, .nashville: return .chordSymbolA
        case .roman:                return .chordSymbolRomanNumeral
        }
    }
}

/// MSCX `<harmonyType>` enum (0=Standard / 1=Roman / 2=Nashville).
public enum HarmonyType: String, Sendable, Equatable {
    case standard
    case roman
    case nashville
}

/// MSCX `<rootCase>` / `<baseCase>` enum
/// (0=auto / 1=upper / 2=lower / 3=capitalize).
public enum NoteCase: String, Sendable, Equatable {
    case auto
    case upper
    case lower
    case capitalize
}
```

- [ ] **Step 4: Add `.harmony` case to `VoiceElement`**

Open `Sources/SheetMusicCore/Score/VoiceElement.swift` and insert ONE line between the existing `.staffText` and `.rehearsalMark` cases (around line 30):

```swift
        case staffText(StaffText)
        case harmony(Harmony)
        case rehearsalMark(RehearsalMark)
```

The remainder of the file (extension methods on `VoiceElement`) needs no changes — `tickCount(division:)` only treats `.chord` as timed, and `.harmony` correctly returns `nil`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter HarmonyTests 2>&1 | tail -20`
Expected: 3 tests pass, build succeeds.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `swift test 2>&1 | tail -15`
Expected: all existing tests still pass. The new enum case is additive; `MSCXDecoder+Voice.swift` ignores unknown XML so no decoder updates are needed yet.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicCore/Score/Harmony.swift \
        Sources/SheetMusicCore/Score/VoiceElement.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(core): add Harmony value type and VoiceElement.harmony case"
```

---

## Task 2: Promote shared decoder helpers + add `MSCXDecoder+Harmony`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffText.swift`
- Create: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Harmony.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing decode tests**

Append to `Tests/SheetMusicTests/HarmonyTests.swift` (add `@testable import SheetMusicMSCX` and `@testable import SheetMusicXMLTools` near the existing imports):

```swift
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools

extension HarmonyTests {
    @Test func decodesStandardChordNameAndType() throws {
        let xml = "<Harmony><name>C</name></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
    }

    @Test func decodesSlashChordRootAndBassTpc() throws {
        let xml = """
        <Harmony>
          <name>F#m7b5/A</name>
          <root>20</root>
          <base>17</base>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.name == "F#m7b5/A")
        #expect(h.rootTpc == 20)
        #expect(h.bassTpc == 17)
    }

    @Test func decodesRomanNumeralType() throws {
        let xml = """
        <Harmony>
          <name>bIII</name>
          <harmonyType>1</harmonyType>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.harmonyType == .roman)
        #expect(h.styleType == .chordSymbolRomanNumeral)
    }

    @Test func decodesParentheses() throws {
        let xml = """
        <Harmony>
          <name>Am7</name>
          <leftParen/>
          <rightParen/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.leftParen)
        #expect(h.rightParen)
    }

    @Test func tpcInvalidNormalizesToNil() throws {
        let xml = """
        <Harmony>
          <name>C</name>
          <root>-1</root>
          <base>-1</base>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
    }

    @Test func decodesOffsetAndColor() throws {
        let xml = """
        <Harmony>
          <name>C</name>
          <offset x="0.5" y="-1.2"/>
          <color r="200" g="80" b="40" a="255"/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.offsetX == 0.5)
        #expect(h.offsetY == -1.2)
        #expect(h.color?.red == 200)
        #expect(h.color?.green == 80)
        #expect(h.color?.blue == 40)
    }

    @Test func decodesPlayDefaultsTrue() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8)))
        #expect(h.play == true)
    }

    @Test func decodesPlayFalseFromZero() throws {
        let xml = "<Harmony><name>C</name><play>0</play></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.play == false)
    }

    @Test func missingHarmonyTypeDefaultsToStandard() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8)))
        #expect(h.harmonyType == .standard)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HarmonyTests 2>&1 | tail -10`
Expected: build error — `Harmony.decode(_:)` does not exist.

- [ ] **Step 3: Promote helpers in `MSCXDecoder+StaffText.swift`**

Open `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffText.swift`. Drop the `private` qualifier from `plainText(of:)`, `decodeColor(_:)`, and `decodeOffset(_:)` so they remain `static` but become file/module-internal:

```swift
    static func plainText(of node: XMLTreeNode) -> String {
        var result = node.text
        for child in node.children {
            result += plainText(of: child)
        }
        return result
    }

    static func decodeColor(
        _ node: XMLTreeNode
    ) -> ScoreColor? { /* unchanged */ }

    static func decodeOffset(
        _ node: XMLTreeNode
    ) -> (Double, Double) { /* unchanged */ }
```

Bodies stay identical — only the access modifier changes.

- [ ] **Step 4: Create `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Harmony.swift`**

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Harmony {
    /// Decode a `<Harmony>` element. Mirrors
    /// `TRead::read(Harmony*, ...)` in MuseScore's
    /// `engraving/rw/read410/tread.cpp` (around line 2970).
    /// Permissive — unknown children (`<degree>`, `<extension>`,
    /// `<function>`, `<harmonyVoiceLiteral>`, `<harmonyVoicing>`,
    /// `<harmonyDuration>`) are silently skipped.
    static func decode(_ node: XMLTreeNode) throws -> Harmony {
        let name = node.first("name")
            .map(StaffText.plainText(of:)) ?? ""
        let typeRaw = node.first("harmonyType")?.text ?? "0"
        let harmonyType = decodeHarmonyType(typeRaw)
        let rootTpc = decodeTpc(node.first("root")?.text)
        let bassTpc = decodeTpc(node.first("base")?.text)
        let rootCase = decodeNoteCase(node.first("rootCase")?.text)
        let bassCase = decodeNoteCase(node.first("baseCase")?.text)
        let leftParen = node.first("leftParen") != nil
        let rightParen = node.first("rightParen") != nil
        let play = decodePlay(node.first("play")?.text)
        let color = node.first("color").flatMap(StaffText.decodeColor(_:))
        let offset = node.first("offset")
            .map(StaffText.decodeOffset(_:)) ?? (0, 0)
        let properties = TextProperties.decode(node)
        return Harmony(
            name: name,
            harmonyType: harmonyType,
            rootTpc: rootTpc,
            rootCase: rootCase,
            bassTpc: bassTpc,
            bassCase: bassCase,
            leftParen: leftParen,
            rightParen: rightParen,
            play: play,
            offsetX: offset.0,
            offsetY: offset.1,
            color: color,
            properties: properties
        )
    }

    private static func decodeHarmonyType(_ raw: String) -> HarmonyType {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .roman
        case "2": return .nashville
        default:  return .standard
        }
    }

    private static func decodeNoteCase(_ raw: String?) -> NoteCase {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .upper
        case "2": return .lower
        case "3": return .capitalize
        default:  return .auto
        }
    }

    /// MuseScore writes `TPC_INVALID` (`-1`) when no root / bass is
    /// resolved. Normalise to `nil` so downstream code never does
    /// arithmetic on -1.
    private static func decodeTpc(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              let value = Int(raw)
        else { return nil }
        return value == -1 ? nil : value
    }

    /// `<play>1</play>` / `<play>true</play>` → true. Missing tag
    /// also defaults to true (matches MuseScore's `Harmony` ctor).
    private static func decodePlay(_ raw: String?) -> Bool {
        guard let raw = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return true }
        return raw == "1" || raw == "true"
    }
}
```

- [ ] **Step 5: Run to verify the new tests pass**

Run: `swift test --filter HarmonyTests 2>&1 | tail -20`
Expected: all 12 `HarmonyTests` pass (3 from Task 1 + 9 added here).

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -15`
Expected: all tests pass — promoting the helpers from `private` to `static` (file-internal) does not affect the existing `StaffText.decode` callers.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Harmony.swift \
        Sources/SheetMusicMSCX/Decoders/MSCXDecoder+StaffText.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(mscx): decode <Harmony> via MSCXDecoder+Harmony"
```

---

## Task 3: Wire `Harmony` into the voice decoder switch

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing voice-decode test**

Append to `HarmonyTests.swift`:

```swift
extension HarmonyTests {
    @Test func voiceDecoderRecognizesHarmony() throws {
        let xml = """
        <voice>
          <Harmony><name>Am7</name></Harmony>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 2)
        guard case let .harmony(h) = voice.elements[0] else {
            Issue.record("element 0 is not .harmony")
            return
        }
        #expect(h.name == "Am7")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests/voiceDecoderRecognizesHarmony 2>&1 | tail -10`
Expected: the test fails — `voice.elements.count` is `1` (the `<Harmony>` falls into the `default` arm and is silently dropped).

- [ ] **Step 3: Add the switch arm**

Open `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift` and insert the case adjacent to `StaffText` / `SystemText` (after the `case "SystemText":` block, before `case "RehearsalMark":`):

```swift
            case "Harmony":
                try elements.append(.harmony(Harmony.decode(child)))
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter HarmonyTests 2>&1 | tail -15`
Expected: all `HarmonyTests` pass, including `voiceDecoderRecognizesHarmony`.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(mscx): route <Harmony> through Voice decoder"
```

---

## Task 4: Add hand-authored `harmony-basic.mscx` test fixture

**Files:**
- Create: `Tests/SheetMusicTests/Resources/harmony-basic.mscx`
- Modify: `Tests/SheetMusicTests/Resources/LICENSE`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing fixture-load test**

Append to `HarmonyTests.swift`:

```swift
@testable import SheetMusic

extension HarmonyTests {
    @Test func basicFixtureExposesFourHarmonies() throws {
        let url = Bundle.module.url(
            forResource: "harmony-basic", withExtension: "mscx"
        )
        try #require(url != nil)
        let score = try SheetMusic.loadScore(at: url!)
        // 4 measures, 1 part, 1 staff, 1 voice each — collect
        // every harmony in document order.
        let harmonies: [Harmony] = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap {
                if case let .harmony(h) = $0 { return h } else { return nil }
            }
        #expect(harmonies.count == 5)
        #expect(harmonies.map(\.name)
                == ["C", "Am7", "F#m7b5/A", "bIII", "C"])
        #expect(harmonies[3].harmonyType == .roman)
        // Bar 5's parenthesised C exercises both decode flags.
        #expect(harmonies[4].leftParen)
        #expect(harmonies[4].rightParen)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests/basicFixtureExposesFourHarmonies 2>&1 | tail -10`
Expected: `Bundle.module.url(...)` returns `nil` — the resource is missing.

- [ ] **Step 3: Create `Tests/SheetMusicTests/Resources/harmony-basic.mscx`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="4.40">
  <Score>
    <Division>480</Division>
    <Part id="1">
      <Staff id="1">
        <StaffType group="pitched">
          <name>stdNormal</name>
        </StaffType>
      </Staff>
      <Instrument id="voice">
        <longName>Voice</longName>
        <shortName>Vo.</shortName>
        <trackName>Voice</trackName>
        <Channel>
          <program value="0"/>
        </Channel>
      </Instrument>
    </Part>
    <Staff id="1">
      <Measure>
        <voice>
          <Clef><concertClefType>G</concertClefType></Clef>
          <KeySig><concertKey>0</concertKey></KeySig>
          <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
          <Harmony><name>C</name></Harmony>
          <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
        </voice>
      </Measure>
      <Measure>
        <voice>
          <Harmony><name>Am7</name></Harmony>
          <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
        </voice>
      </Measure>
      <Measure>
        <voice>
          <Harmony><name>F#m7b5/A</name></Harmony>
          <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
        </voice>
      </Measure>
      <Measure>
        <voice>
          <Harmony>
            <name>bIII</name>
            <harmonyType>1</harmonyType>
          </Harmony>
          <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
        </voice>
      </Measure>
      <Measure>
        <voice>
          <Harmony>
            <name>C</name>
            <leftParen/>
            <rightParen/>
          </Harmony>
          <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
        </voice>
      </Measure>
    </Staff>
  </Score>
</museScore>
```

- [ ] **Step 4: Append the MIT note to `Tests/SheetMusicTests/Resources/LICENSE`**

Open `Tests/SheetMusicTests/Resources/LICENSE` and add `harmony-basic.mscx` to the existing MIT-licensed-fixtures section (around line 46, alongside `multiPartMixedStaves.mscx`):

```
The following files are NOT derived from MuseScore's GPL fixtures.
They were hand-authored specifically for the swift-sheet-music test
suite:

  multiPartMixedStaves.mscx
  harmony-basic.mscx
```

- [ ] **Step 5: Verify the resource is bundled**

`Package.swift` already exposes `Tests/SheetMusicTests/Resources` via `.process("Resources")` (or `.copy("Resources")`); no `Package.swift` edit is needed. Re-run:

Run: `swift test --filter HarmonyTests/basicFixtureExposesFourHarmonies 2>&1 | tail -15`
Expected: PASS — 5 harmonies in expected order.

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green.

- [ ] **Step 7: Commit**

```bash
git add Tests/SheetMusicTests/Resources/harmony-basic.mscx \
        Tests/SheetMusicTests/Resources/LICENSE \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "test(harmony): add MIT-licensed harmony-basic.mscx fixture"
```

---

## Task 5: Layout types — `LayoutHarmony`, `HarmonyRun`, `HarmonyAccidental`

**Files:**
- Create: `Sources/SheetMusicLayout/Layout/LayoutHarmony.swift`
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing test for the layout types**

Append to `HarmonyTests.swift`:

```swift
@testable import SheetMusicLayout

extension HarmonyTests {
    @Test func layoutHarmonyTypeShapeCompiles() {
        let runs: [HarmonyRun] = [
            HarmonyRun(
                kind: .text, content: "F",
                advance: 5.0, x: 0
            ),
            HarmonyRun(
                kind: .accidental(.sharp), content: "",
                advance: 4.0, x: 5.0
            ),
        ]
        let lh = LayoutHarmony(
            harmony: Harmony(name: "F#"),
            anchorX: 100, y: -10,
            runs: runs, width: 9.0
        )
        let element: LayoutElement = .harmony(lh)
        guard case let .harmony(unwrapped) = element else {
            Issue.record("expected .harmony case"); return
        }
        #expect(unwrapped.runs.count == 2)
        #expect(unwrapped.width == 9.0)
        #expect(HarmonyAccidental.flat.codepoint
                == SMuFLGlyph.accidentalFlat)
        #expect(HarmonyAccidental.doubleFlat.codepoint
                == SMuFLGlyph.accidentalDoubleFlat)
        #expect(HarmonyAccidental.sharp.codepoint
                == SMuFLGlyph.accidentalSharp)
        #expect(HarmonyAccidental.doubleSharp.codepoint
                == SMuFLGlyph.accidentalDoubleSharp)
    }
}
```

Note: `SMuFLGlyph` lives in `SheetMusicUI/Rendering`, NOT in `SheetMusicLayout`. To keep the layout module self-contained and avoid a circular dep, `HarmonyAccidental.codepoint` returns the SMuFL `Character` directly — duplicate four constants in the layout module rather than reaching into the UI module. The test should compare to literal `Character` values instead. Replace the four `SMuFLGlyph.*` checks with:

```swift
        #expect(HarmonyAccidental.flat.codepoint == "\u{E260}")
        #expect(HarmonyAccidental.doubleFlat.codepoint == "\u{E264}")
        #expect(HarmonyAccidental.sharp.codepoint == "\u{E262}")
        #expect(HarmonyAccidental.doubleSharp.codepoint == "\u{E263}")
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests/layoutHarmonyTypeShapeCompiles 2>&1 | tail -10`
Expected: build error — `LayoutHarmony` / `HarmonyRun` / `HarmonyAccidental` undefined.

- [ ] **Step 3: Create `Sources/SheetMusicLayout/Layout/LayoutHarmony.swift`**

```swift
import CoreGraphics
import SheetMusicCore

/// Pre-laid-out chord symbol. Rendering source of truth: the `runs`
/// array is built once at layout time so the renderer just walks
/// them; wrap / page-break decisions can read `width` without
/// re-measuring text.
@available(macOS 15.0, iOS 16.0, *)
public struct LayoutHarmony: Sendable, Equatable {
    public var harmony: Harmony
    /// Anchor x in system-relative coords (before `harmony.offsetX`
    /// is applied). The anchor is the chord/rest at the same tick.
    public var anchorX: Double
    /// Default y in staff-top-relative coords (before
    /// `harmony.offsetY`). Negative = above the staff top.
    public var y: Double
    public var runs: [HarmonyRun]
    /// Total typeset width across all runs, in points.
    public var width: Double

    public init(
        harmony: Harmony,
        anchorX: Double,
        y: Double,
        runs: [HarmonyRun],
        width: Double
    ) {
        self.harmony = harmony
        self.anchorX = anchorX
        self.y = y
        self.runs = runs
        self.width = width
    }
}

/// One typesetting run inside a `LayoutHarmony`. Either a string
/// drawn in the harmony's text font, or a single SMuFL accidental
/// glyph drawn in Bravura.
@available(macOS 15.0, iOS 16.0, *)
public struct HarmonyRun: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case accidental(HarmonyAccidental)
    }
    public var kind: Kind
    /// Text content for `.text` runs; ignored for `.accidental`.
    public var content: String
    /// Typeset advance in points (just this run).
    public var advance: Double
    /// Origin X relative to the harmony's anchor point, in points.
    public var x: Double

    public init(
        kind: Kind, content: String, advance: Double, x: Double
    ) {
        self.kind = kind
        self.content = content
        self.advance = advance
        self.x = x
    }
}

/// The four accidentals that can appear inside a chord symbol's
/// name. Mapped to Bravura SMuFL codepoints at draw time. Kept in
/// the layout module (not the UI module) so layout-time width
/// measurement and renderer dispatch agree on a single typed enum.
public enum HarmonyAccidental: Sendable, Equatable {
    case flat
    case doubleFlat
    case sharp
    case doubleSharp

    /// SMuFL Bravura codepoint. Mirrors `SMuFLGlyph.accidental*`
    /// in `SheetMusicUI` (kept duplicated to avoid the layout →
    /// UI dependency).
    public var codepoint: Character {
        switch self {
        case .flat:        return "\u{E260}"
        case .doubleFlat:  return "\u{E264}"
        case .sharp:       return "\u{E262}"
        case .doubleSharp: return "\u{E263}"
        }
    }
}
```

- [ ] **Step 4: Add `case harmony(LayoutHarmony)` to `LayoutElement.swift`**

Open `Sources/SheetMusicLayout/Layout/LayoutElement.swift`. Insert the case adjacent to the existing `.staffText` case (around line 68):

```swift
    case staffText(
        text: String,
        origin: CGPoint,
        color: ScoreColor?,
        isSystemText: Bool
    )
    /// Pre-typeset chord symbol with a baked-in run list (text +
    /// SMuFL accidental glyphs) and total width. The placement
    /// and run structure are computed at layout time so renderers
    /// just walk the runs.
    case harmony(LayoutHarmony)
    case fermata(subtype: String, origin: CGPoint)
```

- [ ] **Step 5: Run the test**

Run: `swift test --filter HarmonyTests/layoutHarmonyTypeShapeCompiles 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Run the full suite — but expect non-exhaustive switch errors**

Run: `swift test 2>&1 | tail -25`
Expected: build errors complaining that switch statements over `LayoutElement` (in `LayoutEngine+Translate`, `ScoreCanvas`, `ScoreLayerBuilder+Element`) are no longer exhaustive. Note the file/line of each break — fix them in Steps 7–10.

- [ ] **Step 7: Patch `LayoutEngine+Translate.swift`**

In the existing `switch element` (around the `.staffText` arm at line ~117), insert below `.rehearsalMark`:

```swift
        case let .harmony(lh):
            // Apply per-staff dy to the anchor point. The runs are
            // laid out relative to `anchorX`, so their `x` values
            // are unaffected.
            return .harmony(LayoutHarmony(
                harmony: lh.harmony,
                anchorX: lh.anchorX,
                y: lh.y + Double(dy),
                runs: lh.runs,
                width: lh.width
            ))
```

(Note `y` is `Double`; if `LayoutHarmony.y` is `CGFloat`, drop the `Double()` cast. We chose `Double` for Sendable simplicity in Step 3.)

- [ ] **Step 8: Patch `ScoreCanvas.swift`**

In the `switch element` around line 380 (next to `.staffText`), add a temporary stub so the build passes — the real renderer is wired in Task 11:

```swift
        case .harmony:
            // Wired up in Task 11.
            break
```

- [ ] **Step 9: Patch `ScoreLayerBuilder+Element.swift`**

In the corresponding switch (around line 221), add the same temporary stub — wired in Task 12:

```swift
        case .harmony:
            // Wired up in Task 12.
            break
```

- [ ] **Step 10: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green. The new `.harmony` case is constructible but never produced by the layout engine yet, so it's effectively dormant.

- [ ] **Step 11: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutHarmony.swift \
        Sources/SheetMusicLayout/Layout/LayoutElement.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift \
        Sources/SheetMusicUI/Rendering/ScoreCanvas.swift \
        Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(layout): add LayoutHarmony / HarmonyRun / HarmonyAccidental"
```

---

## Task 6: SMuFL accidental substitution + width measurement

**Files:**
- Create: `Sources/SheetMusicLayout/Layout/HarmonyRendering.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing substitution tests**

Append to `HarmonyTests.swift`:

```swift
extension HarmonyTests {
    @Test func sharpAfterLetterIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#"),
            metrics: StaffMetrics(staffSize: 28)
        )
        // Run 0 = "F" (text), Run 1 = sharp (accidental).
        #expect(runs.count == 2)
        #expect(runs[0].kind == .text)
        #expect(runs[0].content == "F")
        #expect(runs[1].kind == .accidental(.sharp))
    }

    @Test func flatAfterLetterIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "Bb"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "B")
        #expect(runs[1].kind == .accidental(.flat))
    }

    @Test func doubleFlatIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "Bbb"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "B")
        #expect(runs[1].kind == .accidental(.doubleFlat))
    }

    @Test func doubleSharpIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F##"),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].content == "F")
        #expect(runs[1].kind == .accidental(.doubleSharp))
    }

    @Test func slashChordHasMultipleAccidentals() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#m7b5/Ab"),
            metrics: StaffMetrics(staffSize: 28)
        )
        let kinds = runs.map(\.kind)
        // Expected stream: text "F", #, text "m7", flat, text "5/A", flat
        #expect(kinds == [
            .text,
            .accidental(.sharp),
            .text,
            .accidental(.flat),
            .text,
            .accidental(.flat),
        ])
    }

    @Test func romanLeadingFlatIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "bIII", harmonyType: .roman),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].kind == .accidental(.flat))
        #expect(runs[1].content == "III")
    }

    @Test func standardLeadingFlatIsNotSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "bVII", harmonyType: .standard),
            metrics: StaffMetrics(staffSize: 28)
        )
        // No leading accidental for Standard — left as text.
        #expect(runs.count == 1)
        #expect(runs[0].content == "bVII")
    }

    @Test func widthAccumulatesAcrossRuns() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "F#"),
            metrics: StaffMetrics(staffSize: 28)
        )
        let width = HarmonyRendering.width(of: runs)
        // Sum of advances must equal the externally reported width.
        let summed = runs.reduce(0.0) { $0 + $1.advance }
        #expect(width == summed)
        #expect(width > 0)
        // Each successive run's `x` must equal the cumulative advance
        // up to that point.
        var cumulative = 0.0
        for run in runs {
            #expect(run.x == cumulative)
            cumulative += run.advance
        }
    }

    @Test func nashvilleLeadingSharpIsSubstituted() {
        let runs = HarmonyRendering.runs(
            for: Harmony(name: "#1", harmonyType: .nashville),
            metrics: StaffMetrics(staffSize: 28)
        )
        #expect(runs.count == 2)
        #expect(runs[0].kind == .accidental(.sharp))
        #expect(runs[1].content == "1")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests 2>&1 | tail -25`
Expected: build error — `HarmonyRendering` undefined.

- [ ] **Step 3: Create `Sources/SheetMusicLayout/Layout/HarmonyRendering.swift`**

```swift
import CoreGraphics
import CoreText
import Foundation
import SheetMusicCore

/// Pure helpers that turn a `Harmony.name` into a `[HarmonyRun]`
/// list and report the resulting typeset width. Used at layout
/// time so wrap / spacing decisions can consult the width before
/// any rendering happens.
@available(macOS 15.0, iOS 16.0, *)
public enum HarmonyRendering {
    /// Build the run list for `harmony` at the given staff metrics.
    /// Substitution rules (left-to-right scan):
    ///   1. After an alphanumeric character, `b` / `bb` / `#` / `##`
    ///      become flat / double-flat / sharp / double-sharp glyphs.
    ///   2. For `.roman` / `.nashville`, a leading `b` / `#` (index 0)
    ///      is also recognised as an accidental.
    ///   3. Everything else (digits, slashes, parens, letters) stays
    ///      in a text run; consecutive text characters coalesce.
    public static func runs(
        for harmony: Harmony,
        metrics: StaffMetrics
    ) -> [HarmonyRun] {
        let kindedSlices = parseSlices(
            name: harmony.name, harmonyType: harmony.harmonyType
        )
        let textPointSize = textPointSize(
            for: harmony, metrics: metrics
        )
        let glyphPointSize = glyphPointSize(metrics: metrics)
        let textFont = makeFont(
            face: textFace(for: harmony),
            pointSize: textPointSize
        )
        let glyphFont = makeFont(
            face: "Bravura",
            pointSize: glyphPointSize
        )
        var runs: [HarmonyRun] = []
        var cursor: Double = 0
        for slice in kindedSlices {
            let run: HarmonyRun
            switch slice {
            case let .text(s):
                let advance = measure(s, font: textFont)
                run = HarmonyRun(
                    kind: .text, content: s,
                    advance: advance, x: cursor
                )
            case let .accidental(a):
                let advance = measure(
                    String(a.codepoint), font: glyphFont
                )
                run = HarmonyRun(
                    kind: .accidental(a), content: "",
                    advance: advance, x: cursor
                )
            }
            runs.append(run)
            cursor += run.advance
        }
        return runs
    }

    /// Sum of the `advance` values. Equivalent to the rightmost
    /// run's `x + advance`. Provided as a separate helper because
    /// the public `LayoutHarmony.width` field is the contract — a
    /// regression here would silently desynchronise the spacing
    /// engine and the renderer.
    public static func width(of runs: [HarmonyRun]) -> Double {
        runs.reduce(0.0) { $0 + $1.advance }
    }

    // MARK: - Internals

    private enum Slice {
        case text(String)
        case accidental(HarmonyAccidental)
    }

    /// Walks `name` once, emitting Slice values. Consecutive text
    /// characters are merged at append time.
    private static func parseSlices(
        name: String, harmonyType: HarmonyType
    ) -> [Slice] {
        var out: [Slice] = []
        let chars = Array(name)
        var i = 0
        let allowsLeadingAccidental: Bool
        switch harmonyType {
        case .roman, .nashville: allowsLeadingAccidental = true
        case .standard:          allowsLeadingAccidental = false
        }
        while i < chars.count {
            let c = chars[i]
            // Decide whether the current cursor position can start
            // an accidental. After-letter rule: previous emitted
            // character must be alphanumeric; leading rule: i == 0
            // AND the harmony type opted in.
            let canBeAccidental: Bool = {
                if i == 0 { return allowsLeadingAccidental }
                let prev = chars[i - 1]
                return prev.isLetter || prev.isNumber
            }()
            if canBeAccidental,
               let (acc, consumed) = matchAccidental(
                   chars: chars, at: i
               )
            {
                out.append(.accidental(acc))
                i += consumed
                continue
            }
            // Plain text — coalesce into the previous text slice.
            if case let .text(s) = out.last {
                out[out.count - 1] = .text(s + String(c))
            } else {
                out.append(.text(String(c)))
            }
            i += 1
        }
        return out
    }

    /// Try to match an accidental starting at `chars[i]`. Returns
    /// `(accidental, characters consumed)` or `nil` on no match.
    /// Greedy: prefers the 2-char form (`bb`, `##`) over the 1-char.
    private static func matchAccidental(
        chars: [Character], at i: Int
    ) -> (HarmonyAccidental, Int)? {
        let c = chars[i]
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        switch c {
        case "b":
            if next == "b" { return (.doubleFlat, 2) }
            return (.flat, 1)
        case "#":
            if next == "#" { return (.doubleSharp, 2) }
            return (.sharp, 1)
        default:
            return nil
        }
    }

    private static func textPointSize(
        for harmony: Harmony, metrics: StaffMetrics
    ) -> CGFloat {
        let defaults = harmony.properties.resolved(
            against: harmony.styleType
        )
        let referenceSp: CGFloat = 5.0
        if defaults.spatiumDependent {
            return CGFloat(defaults.size) * metrics.sp / referenceSp
        }
        return CGFloat(defaults.size)
    }

    /// SMuFL convention: 1 em = 4 sp. Match `StaffMetrics.glyphFontSize`.
    private static func glyphPointSize(
        metrics: StaffMetrics
    ) -> CGFloat {
        metrics.glyphFontSize
    }

    private static func textFace(for harmony: Harmony) -> String {
        harmony.properties.face
            ?? harmony.styleType.museScoreDefault.face
    }

    private static func makeFont(
        face: String, pointSize: CGFloat
    ) -> CTFont {
        CTFontCreateWithName(face as CFString, pointSize, nil)
    }

    /// CoreText typesetting advance for a string in `font`. Falls
    /// back to the platform system font if `face` is unregistered
    /// (CTFont's cascade list handles this automatically), so the
    /// reported width stays sensible even when Edwin / Campania /
    /// Bravura are missing at test-time.
    private static func measure(
        _ string: String, font: CTFont
    ) -> Double {
        let attr = NSAttributedString(
            string: string,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(
            attr as CFAttributedString
        )
        let typographicBounds = CTLineGetTypographicBounds(
            line, nil, nil, nil
        )
        return Double(typographicBounds)
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter HarmonyTests 2>&1 | tail -30`
Expected: all 9 substitution tests pass. Width values are non-zero (CoreText fallback to system font keeps measurement working without Bravura registered).

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/HarmonyRendering.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(layout): build SMuFL-substituted Harmony run lists"
```

---

## Task 7: Emit `LayoutHarmony` from `LayoutEngine+Placement`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing layout-emit test**

Append to `HarmonyTests.swift`:

```swift
extension HarmonyTests {
    @Test func layoutEmitsHarmonyAboveStaff() throws {
        let url = Bundle.module.url(
            forResource: "harmony-basic", withExtension: "mscx"
        )
        try #require(url != nil)
        let score = try SheetMusic.loadScore(at: url!)
        let metrics = StaffMetrics(staffSize: 28)
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 28,
                contentWidth: 800
            )
        )
        // Walk every system / measure / element looking for the
        // first `.harmony`. Expect it to land at a Y above the
        // staff's top line.
        var found: LayoutHarmony?
        outer: for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    if case let .harmony(lh) = el {
                        found = lh
                        break outer
                    }
                }
            }
        }
        try #require(found != nil)
        // Staff top in absolute system coords sits below `y` (the
        // chord-symbol slot is above the staff).
        // We don't assert exact pixels — just "above the staff".
        // Concrete y depends on `staffMidY - sp * 2.5` translation
        // performed by Placement.
        #expect(found!.y < 0)
        #expect(found!.runs.isEmpty == false)
        #expect(found!.harmony.name == "C")
    }
}
```

(If the actual `LayoutEngine.layout` API differs in argument names, match the existing call sites — see how `LayoutEngineTests.swift` invokes it.)

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests/layoutEmitsHarmonyAboveStaff 2>&1 | tail -10`
Expected: `found` is `nil` because the `Voice.elements` `.harmony` case is silently dropped by the placement switch (`case let .staffText(...)`/etc. arms exist; `.harmony` is unreachable).

- [ ] **Step 3: Add a `harmonyPlacementAbove` constant to `StaffMetrics`**

Open `Sources/SheetMusicLayout/Layout/StaffMetrics.swift`. Append below `spacePerQuarter`:

```swift
    /// Default Y origin for chord symbols, in points (relative to
    /// the staff top). Negative = above the staff. -2.5 sp matches
    /// MuseScore's `Sid::chordSymbolAPlacement = above` with the
    /// default 0.5 sp offset clear of the staff.
    public var harmonyPlacementAbove: CGFloat { sp * -2.5 }
```

- [ ] **Step 4: Add `.harmony` case to the voice loop in `LayoutEngine+Placement.swift`**

In `placeMeasureElements`, find the `for (voiceElemIdx, el) in voice.elements.enumerated()` switch (around line 328). Insert a new arm next to `.staffText` (around line 633):

```swift
                case let .harmony(harmony):
                    // Anchor at the next timed-element column
                    // (or header start while still in the header).
                    inHeader = false
                    let stX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    let runs = HarmonyRendering.runs(
                        for: harmony, metrics: metrics
                    )
                    let width = HarmonyRendering.width(of: runs)
                    // staffMidY → staffTop is `staffMidY - sp * 2`
                    // (5-line staff). Shifting by `harmonyPlacementAbove`
                    // (-2.5 sp) puts the symbol just clear of the top
                    // line. The author's `<offset y>` adds on top.
                    let staffTopLocal = staffMidY - metrics.sp * 2
                    let yLocal = staffTopLocal
                        + metrics.harmonyPlacementAbove
                        + CGFloat(harmony.offsetY) * metrics.sp
                    let anchorX = Double(
                        stX + CGFloat(harmony.offsetX) * metrics.sp
                    )
                    out.append(.harmony(LayoutHarmony(
                        harmony: harmony,
                        anchorX: anchorX,
                        y: Double(yLocal),
                        runs: runs,
                        width: width
                    )))
```

(The first two lines mirror `.staffText` — `inHeader = false` flushes the header phase before the harmony attaches at the chord column.)

- [ ] **Step 5: Run the test**

Run: `swift test --filter HarmonyTests/layoutEmitsHarmonyAboveStaff 2>&1 | tail -15`
Expected: PASS — the layout produces a `.harmony` element with `y < 0` and a non-empty run list.

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green. The new arm is purely additive; existing tests don't construct `.harmony` voice elements.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/StaffMetrics.swift \
        Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(layout): emit LayoutHarmony from voice .harmony case"
```

---

## Task 8: Above-staff stacking — register `.harmony` with autoplace pipeline

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing stacking test**

Append to `HarmonyTests.swift`:

```swift
extension HarmonyTests {
    @Test func multipleHarmoniesAtSameTickStackVertically() {
        // Build a single-measure, single-voice score with two
        // Harmony elements at tick 0, then layout it.
        let measure = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .harmony(Harmony(name: "C")),
            .harmony(Harmony(name: "Am7")),
            .chord(Chord(duration: .whole, notes: [
                Note(pitch: 60, tpc: 14),
            ])),
        ])])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "voice", articulations: [
                InstrumentArticulation(),
            ]),
            staves: [Staff(measures: [measure])]
        )
        let score = Score(division: 480, parts: [part])
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 28, contentWidth: 800
            )
        )
        var harmonies: [LayoutHarmony] = []
        for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    if case let .harmony(lh) = el {
                        harmonies.append(lh)
                    }
                }
            }
        }
        #expect(harmonies.count == 2)
        // Stacking is upward (smaller Y = higher). The second
        // harmony in document order ends up ABOVE the first.
        let ys = harmonies.map(\.y).sorted()
        #expect(ys[0] < ys[1])
        // Vertical clearance ≥ 0 (no exact overlap).
        #expect(abs(harmonies[0].y - harmonies[1].y) > 0.5)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests/multipleHarmoniesAtSameTickStackVertically 2>&1 | tail -15`
Expected: both harmonies have the same Y (the autoplace pipeline doesn't recognise `.harmony` yet).

- [ ] **Step 3: Wire `.harmony` into the autoplace helpers in `LayoutEngine+Extents.swift`**

Open `Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift` and edit four small functions.

In `aboveStaffPriority` (around line 108), add the case:

```swift
        case .harmony:
            return 0  // Closest to the staff (chord symbols hug the staff line).
```

(Existing priorities: 1 = staffText, 2 = rehearsalMark, 3 = tempo. Harmony at 0 sits below them — chord symbols are conventionally closest to the staff.)

In `aboveStaffHeight` (around line 86):

```swift
        case let .harmony(lh):
            // Approximate font height: text is `chordSymbolA` size
            // (10 pt at 5 pt-spatium ≈ 2 sp). Add 0.4 sp gap so
            // adjacent symbols don't touch.
            _ = lh
            return metrics.sp * 2.0
```

In `aboveStaffAnchor` (around line 130):

```swift
        case .harmony:
            // `HarmonyRenderer` anchors at `.leading` (centre Y).
            return .center
```

In `setAboveStaffOriginY` (around line 153):

```swift
        case let .harmony(lh):
            return .harmony(LayoutHarmony(
                harmony: lh.harmony,
                anchorX: lh.anchorX,
                y: Double(y),
                runs: lh.runs,
                width: lh.width
            ))
```

In `collectAboveStaffEntries` (around line 219), extend the `switch el` so `.harmony` contributes a point at `(anchorX, y)`:

```swift
            case let .harmony(lh):
                p = CGPoint(x: CGFloat(lh.anchorX), y: CGFloat(lh.y))
```

(Add this case alongside the existing `.textMark` / `.staffText` / `.rehearsalMark` arms in the local switch.)

- [ ] **Step 4: Run the test**

Run: `swift test --filter HarmonyTests/multipleHarmoniesAtSameTickStackVertically 2>&1 | tail -10`
Expected: PASS — the two harmonies end up at distinct Ys with at least 0.5 pt clearance.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Extents.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(layout): stack chord symbols in above-staff autoplace pipeline"
```

---

## Task 9: Fold harmony width into the chord-segment spacing demand

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`
- Test: `Tests/SheetMusicTests/HarmonyTests.swift`

- [ ] **Step 1: Write failing spacing test**

Append to `HarmonyTests.swift`:

```swift
extension HarmonyTests {
    @Test func wideHarmonyExpandsChordSpacing() {
        // Two single-quarter chords. With a wide chord symbol on
        // the first chord, the gap between the two columns must
        // grow to accommodate it.
        func tickGap(harmonyName: String?) -> CGFloat {
            var elements: [VoiceElement] = [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 2, denominator: 4)),
            ]
            if let name = harmonyName {
                elements.append(.harmony(Harmony(name: name)))
            }
            elements.append(.chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)]
            )))
            elements.append(.chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16)]
            )))
            let part = Part(
                id: "P1",
                instrument: Instrument(id: "voice", articulations: [
                    InstrumentArticulation(),
                ]),
                staves: [Staff(measures: [
                    Measure(voices: [Voice(elements: elements)]),
                ])]
            )
            let score = Score(division: 480, parts: [part])
            let metrics = StaffMetrics(staffSize: 28)
            let header = HeaderSchedule(
                clefX: metrics.sp * 1.0,
                keySigX: metrics.sp * 4.0,
                timeSigX: metrics.sp * 5.0,
                contentStartX: metrics.sp * 8.0
            )
            let cols = LayoutEngine.tickColumns(
                staves: score.parts[0].staves,
                measureIdx: 0,
                metrics: metrics,
                headerSchedule: header,
                width: 600,
                division: 480
            )
            // Tick 0 vs tick 240 (= one quarter at div 480).
            return (cols[240] ?? 0) - (cols[0] ?? 0)
        }
        let withoutHarmony = tickGap(harmonyName: nil)
        let withWideHarmony = tickGap(harmonyName: "F#m7b5/Ab")
        // Wide chord symbol must push tick 240 further right than
        // the bare-chord baseline.
        #expect(withWideHarmony > withoutHarmony)
    }
}
```

(If `HeaderSchedule`'s init signature differs, adapt to what's in `LayoutEngine+Contexts.swift`. The test's intent — that adding a harmony increases the tick-0-to-tick-240 gap — is what matters.)

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter HarmonyTests/wideHarmonyExpandsChordSpacing 2>&1 | tail -10`
Expected: `withoutHarmony == withWideHarmony` (the spacing engine ignores `.harmony`).

- [ ] **Step 3: Add a harmony-width pass to `aggregatedTickWeights`**

Open `Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift`. Inside `aggregatedTickWeights`, modify the per-voice-element loop so that any `.harmony` encountered before the next chord boosts that chord's `weight`:

In the inner `for (idx, el) in voice.elements.enumerated()` loop (around line 271), maintain a running `pendingHarmonyWidth: CGFloat = 0` per voice (initialise above the loop). When you see `.harmony(let h)`, accumulate its measured width:

```swift
                    case let .harmony(harmony):
                        // Harmony attaches to the next timed
                        // element at the current tick. Pre-measure
                        // its width so the chord segment carries
                        // enough demand to host the symbol without
                        // colliding with the next chord.
                        let runs = HarmonyRendering.runs(
                            for: harmony, metrics: metrics
                        )
                        pendingHarmonyWidth = max(
                            pendingHarmonyWidth,
                            CGFloat(HarmonyRendering.width(of: runs))
                                + metrics.sp * 0.5
                        )
```

When a chord/rest case fires, fold `pendingHarmonyWidth` into `w` and reset:

```swift
                    case let .chord(c) where !c.notes.isEmpty:
                        let nextLyrics = nextChordLyrics(
                            in: voice.elements, after: idx
                        )
                        let baseWeight = max(
                            durationWidth(c.duration, metrics: metrics),
                            lyricsPairWidth(
                                currentLyrics: c.lyrics,
                                nextLyrics: nextLyrics,
                                metrics: metrics
                            )
                        )
                        let w = max(baseWeight, pendingHarmonyWidth)
                        pendingHarmonyWidth = 0
                        // ...rest of the existing arm unchanged...
```

Mirror the same `max` + reset for the rest arm:

```swift
                    case let .chord(r):
                        let baseWeight = durationWidth(r.duration, metrics: metrics)
                        let w = max(baseWeight, pendingHarmonyWidth)
                        pendingHarmonyWidth = 0
                        // ...rest of the existing arm unchanged...
```

(Don't reset `pendingHarmonyWidth` in the `default` arm — `.locationShift` and friends shouldn't drop accumulated demand.)

- [ ] **Step 4: Run the test**

Run: `swift test --filter HarmonyTests/wideHarmonyExpandsChordSpacing 2>&1 | tail -10`
Expected: `withWideHarmony > withoutHarmony` — PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -15`
Expected: 100% green. Existing fixtures don't include `<Harmony>`, so the spacing baseline is unchanged for them.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Spacing.swift \
        Tests/SheetMusicTests/HarmonyTests.swift
git commit -m "feat(layout): fold harmony width into chord segment spacing demand"
```

---

## Task 10: SwiftUI `HarmonyRenderer` + `ScoreCanvas` dispatch

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/HarmonyRenderer.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/HarmonyRenderer.swift`**

```swift
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Draws a `LayoutHarmony` into a SwiftUI `GraphicsContext`. Walks
/// the pre-laid-out `runs` list, switching font between the text
/// face (Edwin / Campania) and Bravura per run.
@available(macOS 15.0, iOS 16.0, *)
enum HarmonyRenderer {
    static func draw(
        context: inout GraphicsContext,
        harmony lh: LayoutHarmony,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        guard !lh.runs.isEmpty else { return }
        let style = ResolvedTextStyle.resolve(
            lh.harmony.styleType,
            overrides: lh.harmony.properties,
            metrics: metrics
        )
        let textColor: Color = lh.harmony.color.map(swiftUIColor)
            ?? .primary
        let glyphFont = Font.custom(
            BravuraFont.familyName,
            size: metrics.glyphFontSize
        )
        for run in lh.runs {
            let p = CGPoint(
                x: origin.x + CGFloat(run.x),
                y: origin.y
            )
            switch run.kind {
            case .text:
                let resolved = context.resolve(
                    Text(run.content)
                        .font(style.font)
                        .foregroundColor(textColor))
                context.draw(resolved, at: p, anchor: .leading)
            case let .accidental(acc):
                let resolved = context.resolve(
                    Text(String(acc.codepoint))
                        .font(glyphFont)
                        .foregroundColor(textColor))
                context.draw(resolved, at: p, anchor: .leading)
            }
        }
    }

    private static func swiftUIColor(_ color: ScoreColor) -> Color {
        Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            opacity: Double(color.alpha) / 255
        )
    }
}
```

- [ ] **Step 2: Wire dispatch in `ScoreCanvas.swift`**

Open `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`. Locate the temporary stub added in Task 5 (`case .harmony: break`). Replace it with:

```swift
        case let .harmony(lh):
            let p = shift(CGPoint(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y)
            ))
            HarmonyRenderer.draw(
                context: &context,
                harmony: lh,
                origin: p,
                metrics: metrics
            )
```

- [ ] **Step 3: Build to confirm renderer compiles**

Run: `swift build 2>&1 | tail -15`
Expected: clean build.

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green. Renderer changes don't break any non-visual test; the harmony layout & spacing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/HarmonyRenderer.swift \
        Sources/SheetMusicUI/Rendering/ScoreCanvas.swift
git commit -m "feat(ui): draw chord symbols in ScoreCanvas via HarmonyRenderer"
```

---

## Task 11: CALayer dispatch in `ScoreLayerBuilder+Element`

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`

- [ ] **Step 1: Replace the temporary stub with a CALayer renderer arm**

Open `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`. Find the temporary `case .harmony: break` from Task 5. Replace with:

```swift
        case let .harmony(lh):
            // Per-run dispatch: text runs go through the
            // ResolvedTextStyle path (Edwin/Campania); accidental
            // runs render the SMuFL glyph in Bravura at glyph size.
            let style = ResolvedTextStyle.resolve(
                lh.harmony.styleType,
                overrides: lh.harmony.properties,
                metrics: metrics
            )
            let textColor: CGColor = lh.harmony.color
                .map(scoreColorToCGColor) ?? Self.inkColor
            let bravura = CTFontCreateWithName(
                BravuraFont.familyName as CFString,
                metrics.glyphFontSize, nil
            )
            let originPoint = shift(CGPoint(
                x: CGFloat(lh.anchorX),
                y: CGFloat(lh.y)
            ))
            for run in lh.runs {
                let p = CGPoint(
                    x: originPoint.x + CGFloat(run.x),
                    y: originPoint.y
                )
                switch run.kind {
                case .text:
                    if let layer = textLayer(
                        text: run.content, at: p,
                        size: style.pointSize,
                        italic: style.isItalic,
                        anchor: CGPoint(x: 0, y: 0.5),
                        color: textColor,
                        font: style.ctFont,
                        height: height
                    ) {
                        parent.addSublayer(layer)
                    }
                case let .accidental(acc):
                    if let layer = textLayer(
                        text: String(acc.codepoint), at: p,
                        size: metrics.glyphFontSize,
                        italic: false,
                        anchor: CGPoint(x: 0, y: 0.5),
                        color: textColor,
                        font: bravura,
                        height: height
                    ) {
                        parent.addSublayer(layer)
                    }
                }
            }
```

- [ ] **Step 2: Build & test**

Run: `swift build 2>&1 | tail -15 && swift test 2>&1 | tail -10`
Expected: clean build, 100% green.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
git commit -m "feat(ui): draw chord symbols in CALayer pipeline"
```

---

## Task 12: `#Preview` for visual verification

**Files:**
- Create: `Sources/RenderPreviews/HarmonyPreview.swift`

- [ ] **Step 1: Create `Sources/RenderPreviews/HarmonyPreview.swift`**

(`RenderPreviews` is a macOS-only target — see the existing `Samples.swift`. Mirror that pattern: read fixture from the test resources directory directly via filesystem URL, since this target doesn't depend on the test bundle. Adjust the URL path if needed.)

```swift
#if os(macOS)
import Foundation
import SheetMusic
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Visual preview of `harmony-basic.mscx`. Open this file in Xcode,
/// click the canvas to "Resume", and inspect the chord symbols
/// above each measure. Iterate via `mcp__xcode__RenderPreview`.
@available(macOS 15.0, *)
struct HarmonyPreviewView: View {
    let score: Score

    init() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()       // RenderPreviews/
            .deletingLastPathComponent()       // Sources/
            .deletingLastPathComponent()       // package root
            .appendingPathComponent("Tests/SheetMusicTests/Resources/harmony-basic.mscx")
        do {
            self.score = try SheetMusic.loadScore(at: url)
        } catch {
            self.score = Score(division: 480)
        }
    }

    var body: some View {
        ScoreView(
            score: score,
            options: ScoreViewOptions(staffSize: 28)
        )
        .frame(width: 800, height: 220)
        .padding()
    }
}

@available(macOS 15.0, *)
#Preview("Harmony — basic chord symbols") {
    HarmonyPreviewView()
}
#endif
```

(Adjust the `init()` URL traversal depth if the preview file lives at a different nesting level, or use `Bundle.module` if that target exposes resources. The exact resolution is whatever lets the preview load the fixture from disk.)

- [ ] **Step 2: Verify Xcode is running with the package open**

Per the user's iOS/macOS app development convention (see `~/.claude/CLAUDE.md`), check before rendering:

Run via the harness: `mcp__xcode__XcodeListWindows`
Expected: at least one Xcode window listing the swift-sheet-music package. If not, ask the user to open the package in Xcode and stop here.

- [ ] **Step 3: Render the preview and inspect the snapshot**

Run via the harness:
```
mcp__xcode__RenderPreview ⇒ HarmonyPreviewView
```
Read the resulting PNG. Manually verify each measure's chord symbol:
- Bar 1: plain `C` (Edwin text only).
- Bar 2: `Am7` (text only — no accidentals).
- Bar 3: `F#m7b5/A` — Bravura sharp after `F`, Bravura flat after `b5/`.
- Bar 4: `bIII` — Bravura flat at the start, Campania `III` after.
- Bar 5: `(C)` — parentheses currently render only when present in `name` (the `<leftParen/>` flag is preserved on the model but not yet drawn). Note this as a known follow-up if the bare `C` shows without parens.

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 100% green.

- [ ] **Step 5: Commit**

```bash
git add Sources/RenderPreviews/HarmonyPreview.swift
git commit -m "test(preview): add harmony-basic visual preview"
```

---

## Task 13: Surface `harmony-basic.mscx` in the macOS example sample list

**Files:**
- Modify: `Example/SheetMusicExample/Shared/ScoreLoader.swift` (or wherever the macOS sample list is built)

This is a smoke-check follow-up per the spec, scoped intentionally small.

- [ ] **Step 1: Locate the macOS sample list**

Run: `grep -rn "midi01\|sample\|fixture" Example/SheetMusicExample/macOS/ Example/SheetMusicExample/Shared/ | head -20`
Expected: a single source of truth (likely a `samples` array or `enum`) that enumerates `.mscx` files shown in the sidebar.

- [ ] **Step 2: Add `harmony-basic` to that list**

Add a new sample entry that points at the fixture in `Tests/SheetMusicTests/Resources/harmony-basic.mscx`. The example app already loads files from arbitrary URLs (per the existing sample wiring); reuse whatever pattern the other test fixtures use. If the example already references files from `Tests/SheetMusicTests/Resources/` (it should — `midi01.mscx` is there), copy that pattern verbatim.

- [ ] **Step 3: Regenerate the Xcode project**

```bash
cd Example && xcodegen generate
```
Expected: no errors. The `.xcodeproj` is gitignored.

- [ ] **Step 4: Build the example app for macOS**

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=macOS' \
           -skipPackagePluginValidation build 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Hand off for visual smoke check**

Per the user's preference (`feedback_visual_verify_mac.md` in memory), the user verifies the macOS example app personally — do NOT spawn a UI agent. Tell the user:

> "harmony-basic is wired into SheetMusicExampleMac. Please open the Mac app, select 'harmony-basic' from the sidebar, and confirm the four (or five) chord symbols render above the staff with the expected SMuFL accidentals."

- [ ] **Step 6: Commit**

```bash
git add Example/SheetMusicExample/...   # whichever files actually changed
git commit -m "chore(example): include harmony-basic in macOS sample list"
```

---

## Self-review

**1. Spec coverage** — every spec section maps to a task:

- `Goal` / `Approach summary` → Task 1 (Core), Task 2 (decoder), Task 5 (layout types), Task 6 (substitution), Task 10/11 (renderers).
- `Architecture` data flow → Tasks 1–11 in order.
- `SheetMusicCore additions` (`Harmony`, `HarmonyType`, `NoteCase`, `VoiceElement.harmony`) → Task 1.
- `SheetMusicMSCX additions` (decoder, voice switch, helper promotion) → Tasks 2 + 3.
- `SheetMusicLayout additions` (`LayoutHarmony`, `HarmonyRun`, `LayoutElement.harmony`, `HarmonyRendering`, `harmonyPlacementAbove`, autoplace, spacing) → Tasks 5–9.
- `SheetMusicUI additions` (`HarmonyRenderer`, dispatch arms) → Tasks 10–11.
- `Testing.Fixture` (harmony-basic.mscx, MIT LICENSE entry) → Task 4.
- `Testing.Unit suites` (decode + substitution + layout suites) → Tasks 1, 2, 6, 7, 8.
- `Testing.Visual verification` (`#Preview` block) → Task 12.
- `Final smoke check` (sample list wiring) → Task 13.
- `Recurring pitfalls`:
  - "Leading accidentals are type-sensitive" — covered by tests in Task 6 (`romanLeadingFlatIsSubstituted` + `standardLeadingFlatIsNotSubstituted`).
  - "TPC -1 is invalid" — Task 2 (`tpcInvalidNormalizesToNil`).
  - "harmonyType defaults to .standard" — Task 2 (`missingHarmonyTypeDefaultsToStandard`).
  - "`<base>` not `<bass>`" — Task 2 decoder reads `node.first("base")`.
  - "Run-list pre-computation lives in layout module" — Task 6 puts it in `SheetMusicLayout`.

**2. Placeholder scan** — no TBD / TODO / "fill in details" / "similar to Task N". Every step that changes code shows the code or names the exact line being changed.

**3. Type consistency** — `LayoutHarmony` uses `Double` for `anchorX` / `y` / `width` (Task 5), and every later task that constructs or reads it (Task 7 emit, Task 8 stacking helpers, Task 10/11 renderers) consistently casts via `CGFloat(lh.anchorX)`. `HarmonyAccidental.codepoint: Character` is consumed identically in the layout-time width measurement (Task 6) and both renderers (Tasks 10, 11). `Harmony.styleType` returns `TextStyleType` and is fed unchanged to `ResolvedTextStyle.resolve(_:overrides:metrics:)` in both renderers.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-04-mscx-harmony-chord-symbols.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
