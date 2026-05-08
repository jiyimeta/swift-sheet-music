# MSCX / MSCZ Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Score → .mscx XML → .mscz` export, with the `midi01` fixture round-tripping (parse → encode → re-parse) to a `Score` equal to the original under `==`.

**Architecture:** Mirror the existing decoder split: each `Score` element type gets its own `MSCXEncoder+<Type>.swift` extension that returns an `XMLTreeNode`. A new `XMLTreeSerializer` in `SheetMusicXMLTools` turns the root node into UTF-8 XML bytes. `MSCXEncoder` is the public façade; `MSCZWriter` and `SheetMusic` gain high-level overloads. Byte-level identity with MuseScore Studio is **not** the contract — semantic round-trip through this library's own parser is.

**Tech Stack:** Swift 6.2, Foundation, ZIPFoundation (already used by `MSCZWriter`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-05-07-mscx-export-design.md`

---

## File Structure

**New (Phase 1):**
- `Sources/SheetMusicXMLTools/XMLTreeSerializer.swift` — `XMLTreeNode → Data`
- `Sources/SheetMusicMSCX/MSCXEncoder.swift` — public façade
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Clef.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift` — shared helper used by Chord encoder
- `Tests/SheetMusicTests/Helpers/MSCXFixtureLoader.swift` — `.mscx` fixture URL/Data loader
- `Tests/SheetMusicTests/XMLTreeSerializerTests.swift`
- `Tests/SheetMusicTests/MSCXEncoderTests.swift` — element-level round-trips (small Score values)
- `Tests/SheetMusicTests/MSCXRoundTripTests.swift` — `midi01.mscx` round-trip (the contract)

**Modified:**
- `Sources/SheetMusicXMLTools/XMLTreeNode.swift` — add `public init`
- `Sources/SheetMusicMSCX/MSCZWriter.swift` — add `write(score:)` overloads
- `Sources/SheetMusic/SheetMusic.swift` — add `exportMSCX` / `exportMSCZ` façade methods

---

## Conventions for this plan

- All shell commands assume **CWD = `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.worktrees/mscx-export`** (the feature worktree). Run `cd` once at start of session if starting fresh; otherwise rely on the working directory persisting across `Bash` calls.
- Tests use Swift Testing (`@Test`, `#expect`) — not XCTest. New imports: `import Testing`.
- Test target uses `@testable import` on each sub-library — re-exports do NOT transitively grant `@testable` access.
- Run unit tests with `swift test --filter <SuiteName>` for fast iteration; full `swift test` is run before commits that touch shared types.
- Commit on `feature/mscx-export` only. Do not push.
- 300-line SwiftLint cap on each new file. None of the encoder files come close.
- One responsibility per file (CLAUDE.md). No "MSCXEncoder+Helpers.swift" catch-alls.

---

### Task 1: Add `public init` to `XMLTreeNode`

The decoder side never needed it (parser builds nodes inside `SheetMusicXMLTools`); the encoder side does because encoders live in `SheetMusicMSCX` and construct `XMLTreeNode` values from outside the module.

**Files:**
- Modify: `Sources/SheetMusicXMLTools/XMLTreeNode.swift`

- [ ] **Step 1: Open the file and add a public initializer**

Add a `public init` directly below the stored properties, before the `first(_:)` method:

```swift
public init(
    name: String,
    attributes: [String: String] = [:],
    text: String = "",
    children: [XMLTreeNode] = []
) {
    self.name = name
    self.attributes = attributes
    self.text = text
    self.children = children
}
```

- [ ] **Step 2: Build to confirm**

```bash
swift build
```
Expected: succeeds, no warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicXMLTools/XMLTreeNode.swift
git commit -m "$(cat <<'EOF'
feat(xml): expose public initializer on XMLTreeNode

Prepares the type for use as a builder by encoders living outside
SheetMusicXMLTools.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Implement `XMLTreeSerializer` (with focused unit tests)

Single new file in `SheetMusicXMLTools`. Public API:
```swift
public enum XMLTreeSerializer {
    public static func serialize(_ root: XMLTreeNode) -> Data
}
```

Output rules:
- UTF-8 with prolog `<?xml version="1.0" encoding="UTF-8"?>\n`
- 2-space indent per nesting level
- Self-close empty elements (`<foo/>`) when `text.isEmpty && children.isEmpty`
- Elements with text but no children render inline: `<name>text</name>`
- Elements with children render block-style with the closing tag at the parent's indent level
- Attributes: each as ` key="value"`, in **sorted key order** for stable output
- Escape in text: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`
- Escape in attribute values: same as text plus `"` → `&quot;`
- Trailing newline at end of document

**Files:**
- Create: `Sources/SheetMusicXMLTools/XMLTreeSerializer.swift`
- Test: `Tests/SheetMusicTests/XMLTreeSerializerTests.swift`

- [ ] **Step 1: Write failing tests first**

Create `Tests/SheetMusicTests/XMLTreeSerializerTests.swift`:

```swift
import Foundation
@testable import SheetMusicXMLTools
import Testing

@Suite("XMLTreeSerializer")
struct XMLTreeSerializerTests {
    private func serialize(_ node: XMLTreeNode) -> String {
        String(data: XMLTreeSerializer.serialize(node), encoding: .utf8) ?? ""
    }

    @Test("self-closes empty leaves")
    func selfClosesEmptyLeaves() {
        let node = XMLTreeNode(name: "root", children: [
            XMLTreeNode(name: "empty"),
        ])
        let xml = serialize(node)
        #expect(xml.contains("<empty/>"))
    }

    @Test("inlines elements with text")
    func inlinesText() {
        let node = XMLTreeNode(name: "root", children: [
            XMLTreeNode(name: "value", text: "42"),
        ])
        let xml = serialize(node)
        #expect(xml.contains("<value>42</value>"))
    }

    @Test("escapes XML metacharacters in text")
    func escapesTextMetachars() {
        let node = XMLTreeNode(name: "t", text: "a < b & c > d")
        let xml = serialize(node)
        #expect(xml.contains("a &lt; b &amp; c &gt; d"))
    }

    @Test("escapes quote in attribute values")
    func escapesAttrQuote() {
        let node = XMLTreeNode(
            name: "t",
            attributes: ["msg": "say \"hi\""]
        )
        let xml = serialize(node)
        #expect(xml.contains("msg=\"say &quot;hi&quot;\""))
    }

    @Test("attributes appear in sorted key order")
    func attrSortStable() {
        let node = XMLTreeNode(
            name: "t",
            attributes: ["b": "2", "a": "1", "c": "3"]
        )
        let xml = serialize(node)
        let line = xml.split(separator: "\n").first(where: { $0.contains("<t ") })
        #expect(line?.contains("a=\"1\" b=\"2\" c=\"3\"") == true)
    }

    @Test("emits XML prolog")
    func prologPresent() {
        let xml = serialize(XMLTreeNode(name: "root"))
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
    }

    @Test("round-trips through XMLTreeParser")
    func roundTripsViaParser() throws {
        let original = XMLTreeNode(
            name: "root",
            attributes: ["v": "1"],
            children: [
                XMLTreeNode(name: "a", text: "hello"),
                XMLTreeNode(name: "b", children: [
                    XMLTreeNode(name: "c", text: "x"),
                ]),
                XMLTreeNode(name: "empty"),
            ]
        )
        let bytes = XMLTreeSerializer.serialize(original)
        let reparsed = try XMLTreeParser.parse(bytes)
        #expect(reparsed == original)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter XMLTreeSerializerTests
```
Expected: FAIL — `XMLTreeSerializer` is undefined.

- [ ] **Step 3: Implement `XMLTreeSerializer`**

Create `Sources/SheetMusicXMLTools/XMLTreeSerializer.swift`:

```swift
import Foundation

/// Serializes an `XMLTreeNode` tree to UTF-8 XML bytes.
///
/// Output is intentionally simple: 2-space indent, attributes in
/// sorted key order, self-closed empty leaves, standard prolog.
/// Byte-level parity with MuseScore Studio's writer is a non-goal —
/// the contract is that re-parsing the output via `XMLTreeParser`
/// reproduces the input tree.
public enum XMLTreeSerializer {
    public static func serialize(_ root: XMLTreeNode) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        write(root, indent: 0, into: &out)
        return Data(out.utf8)
    }

    private static func write(
        _ node: XMLTreeNode, indent depth: Int, into out: inout String
    ) {
        let pad = String(repeating: "  ", count: depth)
        let attrs = renderAttributes(node.attributes)
        let isEmpty = node.text.isEmpty && node.children.isEmpty
        if isEmpty {
            out += "\(pad)<\(node.name)\(attrs)/>\n"
            return
        }
        if node.children.isEmpty {
            out += "\(pad)<\(node.name)\(attrs)>\(escapeText(node.text))</\(node.name)>\n"
            return
        }
        out += "\(pad)<\(node.name)\(attrs)>\n"
        if !node.text.isEmpty {
            out += "\(pad)  \(escapeText(node.text))\n"
        }
        for child in node.children {
            write(child, indent: depth + 1, into: &out)
        }
        out += "\(pad)</\(node.name)>\n"
    }

    private static func renderAttributes(_ attrs: [String: String]) -> String {
        guard !attrs.isEmpty else { return "" }
        var parts = ""
        for key in attrs.keys.sorted() {
            let value = attrs[key] ?? ""
            parts += " \(key)=\"\(escapeAttribute(value))\""
        }
        return parts
    }

    private static func escapeText(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            default: r.append(ch)
            }
        }
        return r
    }

    private static func escapeAttribute(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.append(ch)
            }
        }
        return r
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter XMLTreeSerializerTests
```
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicXMLTools/XMLTreeSerializer.swift Tests/SheetMusicTests/XMLTreeSerializerTests.swift
git commit -m "$(cat <<'EOF'
feat(xml): add XMLTreeSerializer

Reverse of XMLTreeParser. Round-trips XMLTreeNode through bytes via
2-space indent, sorted attributes, self-closed empty leaves, and
standard XML escaping. Byte parity with MuseScore Studio is a
non-goal; the parser-round-trip property is what callers depend on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `MSCXFixtureLoader` test helper

A small loader that mirrors `MusicXMLFixtureLoader` so tests can pull `.mscx` fixtures by name. Useful in MSCXEncoderTests (small fixtures) and MSCXRoundTripTests (`midi01.mscx`).

**Files:**
- Create: `Tests/SheetMusicTests/Helpers/MSCXFixtureLoader.swift`

- [ ] **Step 1: Create the helper**

```swift
import Foundation
import Testing

/// Loads `.mscx` / `.mscz` test fixtures from
/// `Tests/SheetMusicTests/Resources/`.
///
/// The on-disk files are GPL-3.0 copies of MuseScore's own test
/// fixtures (see `Tests/SheetMusicTests/Resources/LICENSE`). They live
/// only in the test target and are not shipped in any library product.
enum MSCXFixtureLoader {
    static func mscxData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "mscx"),
            "fixture mscx not bundled: \(name).mscx"
        )
        return try Data(contentsOf: url)
    }

    static func msczData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "mscz"),
            "fixture mscz not bundled: \(name).mscz"
        )
        return try Data(contentsOf: url)
    }
}
```

- [ ] **Step 2: Build to confirm**

```bash
swift build
```
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/Helpers/MSCXFixtureLoader.swift
git commit -m "$(cat <<'EOF'
test(mscx): add MSCXFixtureLoader helper

Mirrors MusicXMLFixtureLoader for upcoming encoder round-trip tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Encoder skeleton — `MSCXEncoder` façade + Score root + Division + metaTags

First end-to-end vertical: a `Score` carrying only `division` and a couple of `metaTags` round-trips through encode → parse. Establishes the `MSCXEncoder.encode(_:)` API surface.

**Files:**
- Create: `Sources/SheetMusicMSCX/MSCXEncoder.swift`
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`
- Test: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/MSCXEncoderTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("MSCXEncoder")
struct MSCXEncoderTests {
    @Test("minimal Score round-trips division and metaTags")
    func minimalScoreRoundTrip() throws {
        let original = Score(
            division: 480,
            metaTags: ["composer": "Bach", "workTitle": "Invention"]
        )

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.division == 480)
        #expect(reparsed.metaTags == original.metaTags)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter MSCXEncoderTests
```
Expected: FAIL — `MSCXEncoder` is undefined.

- [ ] **Step 3: Create the façade**

`Sources/SheetMusicMSCX/MSCXEncoder.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Public façade that turns a `Score` into `.mscx` XML bytes.
///
/// Reverse of `MSCXParser.parse`. The contract is a **semantic**
/// round-trip: re-parsing the output via `MSCXParser` yields a `Score`
/// equal to the input under `==`. Byte-level parity with MuseScore
/// Studio's writer is not a goal.
public enum MSCXEncoder {
    /// Serialize a `Score` to `.mscx` XML bytes.
    public static func encode(_ score: Score) throws -> Data {
        let root = score.encode()
        return XMLTreeSerializer.serialize(root)
    }

    /// Serialize a `Score` and write the resulting `.mscx` to a file URL.
    public static func encode(_ score: Score, to url: URL) throws {
        let bytes = try encode(score)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
}
```

- [ ] **Step 4: Create the Score-level encoder**

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    /// Build the `<museScore><Score>…</Score></museScore>` root.
    func encode() -> XMLTreeNode {
        var scoreChildren: [XMLTreeNode] = []
        scoreChildren.append(XMLTreeNode(
            name: "Division", text: String(division)
        ))
        // metaTags are emitted in sorted key order for stable output.
        for key in metaTags.keys.sorted() {
            scoreChildren.append(XMLTreeNode(
                name: "metaTag",
                attributes: ["name": key],
                text: metaTags[key] ?? ""
            ))
        }
        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": "4.60"],
            children: [
                XMLTreeNode(name: "Score", children: scoreChildren),
            ]
        )
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXEncoder.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): MSCXEncoder skeleton with Score-root + metaTags

Establishes Score → .mscx XML pipeline: MSCXEncoder.encode(_:) builds
the root <museScore><Score> document via per-type encoder extensions,
then serializes through XMLTreeSerializer. First round-trip exercises
Division and metaTags only; subsequent tasks layer in Style, Parts,
Staves, etc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Encode `<Style>` (spatium subset)

The `Score.style` field carries `ScoreStyle` whose `spatium` round-trips to/from `<Style><spatium>1.75</spatium></Style>`. Page layout / chrome are not in midi01 — defer to Phase 2; encoder emits only spatium.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift` (insert `<Style>` after `<Division>`)
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift` (add test)

- [ ] **Step 1: Add a failing test**

Append to `MSCXEncoderTests.swift`:

```swift
@Test("Score round-trips custom spatium")
func spatiumRoundTrip() throws {
    var style = ScoreStyle.museScoreDefaults
    style.spatium = 1.5
    let original = Score(division: 480, style: style)

    let bytes = try MSCXEncoder.encode(original)
    let reparsed = try MSCXParser.parse(bytes)

    #expect(reparsed.style.spatium == 1.5)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests/spatiumRoundTrip
```
Expected: FAIL — Score encoder doesn't emit `<Style>`.

- [ ] **Step 3: Add the Style encoder**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreStyle {
    /// Build the `<Style>` block. Phase 1 emits only `<spatium>`;
    /// page-layout / chrome encoding lives in a follow-up spec.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Style",
            children: [
                XMLTreeNode(
                    name: "spatium",
                    text: String(format: "%g", spatium)
                ),
            ]
        )
    }
}
```

`%g` strips trailing zeros (so `1.75` stays `1.75`, `1.5` stays `1.5`); the parser parses both forms identically.

- [ ] **Step 4: Wire Style into Score encoder**

In `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift`, replace the `scoreChildren` build-up block with:

```swift
var scoreChildren: [XMLTreeNode] = []
scoreChildren.append(XMLTreeNode(
    name: "Division", text: String(division)
))
scoreChildren.append(style.encode())
// metaTags are emitted in sorted key order for stable output.
for key in metaTags.keys.sorted() {
    scoreChildren.append(XMLTreeNode(
        name: "metaTag",
        attributes: ["name": key],
        text: metaTags[key] ?? ""
    ))
}
```

- [ ] **Step 5: Run all encoder tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Style.spatium

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Encode `Note` + `Accidental`

Standalone encoder that produces a `<Note><pitch><tpc>` block, optionally with an `<Accidental><subtype>` child. midi01 uses `accidentalSharp`; encoder must round-trip every `Accidental` case.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `MSCXEncoderTests.swift`:

```swift
@Test("Note encodes pitch + tpc and round-trips")
func noteRoundTrip() throws {
    let note = Note(pitch: 60, tpc: 14)
    let xml = note.encode()
    // re-parse via the full pipeline
    let document = XMLTreeNode(name: "root", children: [xml])
    let bytes = XMLTreeSerializer.serialize(document)
    let reparsed = try XMLTreeParser.parse(bytes)
    let noteNode = try #require(reparsed.first("Note"))
    let decoded = try Note.decode(noteNode)
    #expect(decoded == note)
}

@Test("Note round-trips every Accidental case")
func accidentalRoundTrip() throws {
    let cases: [Accidental] = [.sharp, .flat, .natural, .doubleSharp, .doubleFlat]
    for acc in cases {
        let note = Note(pitch: 61, tpc: 21, accidental: acc)
        let document = XMLTreeNode(name: "root", children: [note.encode()])
        let bytes = XMLTreeSerializer.serialize(document)
        let reparsed = try XMLTreeParser.parse(bytes)
        let decoded = try Note.decode(#require(reparsed.first("Note")))
        #expect(decoded.accidental == acc, "accidental \(acc) failed to round-trip")
    }
}
```

These tests reach into `XMLTreeParser` and the existing `Note.decode(_:)` (already internal in `SheetMusicMSCX`) — both are accessible because `SheetMusicMSCX` and `SheetMusicXMLTools` are both `@testable import`ed.

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests
```
Expected: FAIL — `Note.encode()` undefined.

- [ ] **Step 3: Implement the Note encoder**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Note {
    /// Build a `<Note>` element. Phase 1 emits pitch / tpc /
    /// optional accidental / optional headType. Tie / glissando
    /// spanners and lyrics live on the chord and are not round-tripped
    /// in the midi01 vertical slice.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let accidental {
            children.append(XMLTreeNode(
                name: "Accidental",
                children: [
                    XMLTreeNode(
                        name: "subtype",
                        text: accidental.mscxSubtype
                    ),
                ]
            ))
        }
        children.append(XMLTreeNode(name: "pitch", text: String(pitch)))
        children.append(XMLTreeNode(name: "tpc", text: String(tpc)))
        if let headType {
            children.append(XMLTreeNode(name: "head", text: headType))
        }
        return XMLTreeNode(name: "Note", children: children)
    }
}

extension Accidental {
    /// Mirror of `Accidental.init?(mscxSubtype:)` — exhaustive.
    var mscxSubtype: String {
        switch self {
        case .sharp: return "accidentalSharp"
        case .flat: return "accidentalFlat"
        case .natural: return "accidentalNatural"
        case .doubleSharp: return "accidentalDoubleSharp"
        case .doubleFlat: return "accidentalDoubleFlat"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Note (pitch, tpc, accidental, head)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Encode `NoteDuration` (helper)

Shared helper used by `Chord` (and later `Rest`) encoders. Maps:
- `.whole` … `.twoFiftySixth` → `<durationType>{name}</durationType>`
- `.fraction(f)` → `<durationType>measure</durationType>` + `<duration>N/D</duration>`

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add a failing test**

Append:

```swift
@Test("NoteDuration appends durationType for named cases")
func durationTypeNamed() {
    var children: [XMLTreeNode] = []
    NoteDuration.quarter.appendDurationXML(to: &children)
    #expect(children.count == 1)
    #expect(children[0].name == "durationType")
    #expect(children[0].text == "quarter")
}

@Test("NoteDuration appends durationType=measure + duration for fractions")
func durationTypeFraction() {
    var children: [XMLTreeNode] = []
    NoteDuration.fraction(.init(numerator: 3, denominator: 8))
        .appendDurationXML(to: &children)
    #expect(children.count == 2)
    #expect(children[0].name == "durationType")
    #expect(children[0].text == "measure")
    #expect(children[1].name == "duration")
    #expect(children[1].text == "3/8")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter MSCXEncoderTests
```
Expected: FAIL.

- [ ] **Step 3: Implement the helper**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension NoteDuration {
    /// MuseScore `<durationType>` text for the named cases.
    /// Inverse of `init?(mscxName:)`. `.fraction` returns nil — the
    /// caller emits `measure` + `<duration>` instead.
    var mscxName: String? {
        switch self {
        case .whole: return "whole"
        case .half: return "half"
        case .quarter: return "quarter"
        case .eighth: return "eighth"
        case .sixteenth: return "16th"
        case .thirtySecond: return "32nd"
        case .sixtyFourth: return "64th"
        case .oneTwentyEighth: return "128th"
        case .twoFiftySixth: return "256th"
        case .fraction: return nil
        }
    }

    /// Append `<durationType>` (and `<duration>` for fractions)
    /// children to `children`. Used by Chord and Rest encoders.
    func appendDurationXML(to children: inout [XMLTreeNode]) {
        if let name = mscxName {
            children.append(XMLTreeNode(name: "durationType", text: name))
            return
        }
        // fraction: emit `measure` durationType + concrete fraction
        if case let .fraction(f) = self {
            children.append(XMLTreeNode(
                name: "durationType", text: "measure"
            ))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)"
            ))
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+NoteDuration.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode NoteDuration

Reverse of NoteDuration.init?(mscxName:). Fractions emit as
durationType=measure + <duration>N/D</duration>, matching the
parser's full-measure-rest path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Encode `Chord`

A `<Chord>` is `<durationType>` + zero or more `<Note>`. Rests (notes-empty chords) are emitted as `<Rest>` instead — handled here so Voice doesn't need a dispatch.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
@Test("Chord round-trips through Chord.decode")
func chordRoundTrip() throws {
    let chord = Chord(
        duration: .quarter,
        notes: ChordNotes([Note(pitch: 60, tpc: 14)])
    )
    let xml = chord.encodeAsChord()
    let document = XMLTreeNode(name: "root", children: [xml])
    let bytes = XMLTreeSerializer.serialize(document)
    let reparsed = try XMLTreeParser.parse(bytes)
    let decoded = try Chord.decode(#require(reparsed.first("Chord")))
    #expect(decoded == chord)
}

@Test("rest chord emits as <Rest>")
func restEmitsAsRestElement() {
    let rest = Chord(duration: .quarter, notes: [])
    let xml = rest.encodeAsRest()
    #expect(xml.name == "Rest")
    #expect(xml.first("durationType")?.text == "quarter")
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter MSCXEncoderTests
```
Expected: FAIL.

- [ ] **Step 3: Implement the Chord encoder**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// Encode as a `<Chord>` (notes-bearing). Caller must guarantee
    /// `notes.isEmpty == false`; voice-level dispatch routes empty
    /// chords through `encodeAsRest()` instead.
    func encodeAsChord() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        for note in notes {
            children.append(note.encode())
        }
        return XMLTreeNode(name: "Chord", children: children)
    }

    /// Encode as a `<Rest>` (notes-empty representation).
    func encodeAsRest() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        return XMLTreeNode(name: "Rest", children: children)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Chord (and rest representation)

Empty chords emit <Rest>; non-empty emit <Chord>+<Note>s. Voice-level
dispatch in the next task picks based on Chord.notes.isEmpty.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Encode `KeySignature`, `TimeSignature`, `Clef`

Three small encoders — each is one or two leaf children. Tested together in one round-trip test through their decoders.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift`
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Clef.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
@Test("KeySignature, TimeSignature, Clef round-trip")
func staticElementsRoundTrip() throws {
    func roundTripParse<T>(_ node: XMLTreeNode, name: String, _ decode: (XMLTreeNode) throws -> T) throws -> T {
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [node])
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        return try decode(#require(reparsed.first(name)))
    }

    let key = KeySignature(concertKey: 1)
    let decKey = try roundTripParse(key.encode(), name: "KeySig", KeySignature.decode)
    #expect(decKey == key)

    let time = TimeSignature(numerator: 4, denominator: 4)
    let decTime = try roundTripParse(time.encode(), name: "TimeSig", TimeSignature.decode)
    #expect(decTime == time)

    let clef = Clef(concertClefType: "G")
    let decClef = try roundTripParse(clef.encode(), name: "Clef", Clef.decode)
    #expect(decClef == clef)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests/staticElementsRoundTrip
```
Expected: FAIL — encoders undefined.

- [ ] **Step 3: Implement the three encoders**

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension KeySignature {
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "KeySig",
            children: [
                XMLTreeNode(name: "concertKey", text: String(concertKey)),
            ]
        )
    }
}
```

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension TimeSignature {
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "TimeSig",
            children: [
                XMLTreeNode(name: "sigN", text: String(numerator)),
                XMLTreeNode(name: "sigD", text: String(denominator)),
            ]
        )
    }
}
```

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Clef.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Clef {
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "concertClefType", text: concertClefType),
        ]
        if let transposingClefType {
            children.append(XMLTreeNode(
                name: "transposingClefType", text: transposingClefType
            ))
        }
        return XMLTreeNode(name: "Clef", children: children)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Clef.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode KeySig, TimeSig, Clef

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Encode `Voice`

A `<voice>` element wrapping a sequence of children. Phase-1 dispatch handles only the `VoiceElement` cases that midi01 uses: `.chord`, `.keySignature`, `.timeSignature`, `.clef`. Other cases trap with a `fatalError("not yet supported in Phase 1")` — they are added in Phase 2 and Phase 1 callers don't trigger them.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
@Test("Voice round-trips KeySig + TimeSig + two chords")
func voiceRoundTrip() throws {
    let original = Voice(elements: [
        .keySignature(KeySignature(concertKey: 1)),
        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
    ])
    let xml = original.encode()
    let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
    let reparsed = try XMLTreeParser.parse(bytes)
    let decoded = try Voice.decode(#require(reparsed.first("voice")))
    #expect(decoded == original)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests/voiceRoundTrip
```
Expected: FAIL.

- [ ] **Step 3: Implement Voice encoder**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Build the `<voice>` element. Phase 1 supports the element
    /// kinds present in `midi01.mscx`: chords (with rests as
    /// notes-empty chords), key/time/clef changes. Other cases
    /// (Tempo, Dynamic, Spanner, Harmony, …) are added in follow-up
    /// specs and trap here with a clear message until then.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        for element in elements {
            switch element {
            case let .chord(chord):
                children.append(chord.notes.isEmpty
                    ? chord.encodeAsRest()
                    : chord.encodeAsChord())
            case let .keySignature(key):
                children.append(key.encode())
            case let .timeSignature(time):
                children.append(time.encode())
            case let .clef(clef):
                children.append(clef.encode())
            case .barLine, .tempo, .dynamic, .spanner,
                 .measureRepeat, .fermata, .staffText, .harmony,
                 .rehearsalMark, .locationShift:
                fatalError(
                    "VoiceElement \(element) not yet supported by " +
                    "MSCXEncoder Phase 1 — see " +
                    "docs/superpowers/specs/2026-05-07-mscx-export-design.md"
                )
            }
        }
        // Tuplets are not exercised by midi01; encoding them is a
        // Phase-2 concern (requires <Tuplet> + <endTuplet> markers
        // interleaved with the elements).
        return XMLTreeNode(name: "voice", children: children)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Voice (Phase 1 element subset)

Handles the element kinds midi01 exercises: chords (incl rests as
empty chords), KeySig, TimeSig, Clef. Other VoiceElement cases trap
until follow-up specs add them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Encode `Measure`

A `<Measure>` wraps one `<voice>` per `Voice`. Phase 1 emits the voices only; repeats / markers / jumps / layout breaks are not in midi01 and are handled in Phase 2.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
@Test("Measure round-trips a single voice")
func measureRoundTrip() throws {
    let voice = Voice(elements: [
        .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
    ])
    let measure = Measure(voices: [voice])

    let xml = measure.encode()
    let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
    let reparsed = try XMLTreeParser.parse(bytes)
    let decoded = try Measure.decode(#require(reparsed.first("Measure")))
    #expect(decoded == measure)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests/measureRoundTrip
```
Expected: FAIL.

- [ ] **Step 3: Implement Measure encoder**

Create `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Measure {
    /// Build the `<Measure>` element. Phase 1 emits voices only.
    /// startRepeat / endRepeatCount / markers / jumps / layout breaks
    /// land in follow-up specs (none present in midi01).
    func encode() -> XMLTreeNode {
        let voiceNodes = voices.map { $0.encode() }
        return XMLTreeNode(name: "Measure", children: voiceNodes)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Measure (voices only, Phase 1)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Encode `InstrumentArticulation` and `InstrumentChannel`

Small leaf encoders. midi01 has 11 articulations (1 default + 10 named) and 1 channel with `<program value="52"/>`. The channel encoder also emits `<controller>` entries for non-default volume/pan/reverb/chorus/bank — but only when they differ from the struct's default values, so a Score round-tripped from midi01 (all defaults) emits no controllers.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentArticulation.swift`
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
@Test("InstrumentArticulation default + named round-trip")
func articulationRoundTrip() throws {
    let cases = [
        InstrumentArticulation(name: nil, velocity: 100, gateTime: 100),
        InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 50),
    ]
    for art in cases {
        let xml = art.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let decoded = try InstrumentArticulation.decode(#require(reparsed.first("Articulation")))
        #expect(decoded == art)
    }
}

@Test("InstrumentChannel program-only round-trip matches default fields")
func channelProgramRoundTrip() throws {
    let original = InstrumentChannel(program: 52)
    let xml = original.encode()
    let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
    let reparsed = try XMLTreeParser.parse(bytes)
    let decoded = try InstrumentChannel.decode(#require(reparsed.first("Channel")))
    #expect(decoded == original)
}

@Test("InstrumentChannel non-default volume emits controller and round-trips")
func channelNonDefaultControllerRoundTrip() throws {
    var channel = InstrumentChannel(program: 0)
    channel.volume = 80
    channel.pan = 30
    let xml = channel.encode()
    let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
    let reparsed = try XMLTreeParser.parse(bytes)
    let decoded = try InstrumentChannel.decode(#require(reparsed.first("Channel")))
    #expect(decoded.volume == 80)
    #expect(decoded.pan == 30)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests
```
Expected: FAIL.

- [ ] **Step 3: Implement encoders**

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentArticulation.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension InstrumentArticulation {
    func encode() -> XMLTreeNode {
        var attrs: [String: String] = [:]
        if let name { attrs["name"] = name }
        return XMLTreeNode(
            name: "Articulation",
            attributes: attrs,
            children: [
                XMLTreeNode(name: "velocity", text: String(velocity)),
                XMLTreeNode(name: "gateTime", text: String(gateTime)),
            ]
        )
    }
}
```

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension InstrumentChannel {
    /// Build the `<Channel>` element.
    ///
    /// MuseScore's parser fills missing CC values from the
    /// `InstrumentChannel()` defaults (volume=100, pan=64, reverb=0,
    /// chorus=0, bank=0). To stay faithful to the parsed-then-encoded
    /// round-trip, we emit `<controller>` entries only when the
    /// current value differs from those defaults, so a value parsed
    /// from a fixture without explicit controllers re-encodes to the
    /// same shape.
    func encode() -> XMLTreeNode {
        let defaults = InstrumentChannel()
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(
            name: "program",
            attributes: ["value": String(program)]
        ))
        if let midiChannel {
            children.append(XMLTreeNode(
                name: "midiChannel", text: String(midiChannel)
            ))
        }
        if let midiPort {
            children.append(XMLTreeNode(
                name: "midiPort", text: String(midiPort)
            ))
        }
        if volume != defaults.volume {
            children.append(controllerNode(ctrl: 7, value: volume))
        }
        if pan != defaults.pan {
            children.append(controllerNode(ctrl: 10, value: pan))
        }
        if bank != defaults.bank {
            children.append(controllerNode(ctrl: 32, value: bank))
        }
        if reverb != defaults.reverb {
            children.append(controllerNode(ctrl: 91, value: reverb))
        }
        if chorus != defaults.chorus {
            children.append(controllerNode(ctrl: 93, value: chorus))
        }
        var attrs: [String: String] = [:]
        if let name { attrs["name"] = name }
        return XMLTreeNode(name: "Channel", attributes: attrs, children: children)
    }

    private func controllerNode(ctrl: Int, value: Int) -> XMLTreeNode {
        XMLTreeNode(
            name: "controller",
            attributes: ["ctrl": String(ctrl), "value": String(value)]
        )
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentArticulation.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode InstrumentArticulation + InstrumentChannel

Channel emits controller entries only when CC values differ from the
struct defaults so round-tripping a parsed-then-encoded score with
no explicit controllers stays clean.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Encode `Instrument`

Wraps everything in Task 12 plus longName/shortName/trackName/min-max pitches/articulations/channels.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
@Test("Instrument round-trip with articulations + channel")
func instrumentRoundTrip() throws {
    let original = Instrument(
        id: "voice",
        longName: "Voice",
        shortName: "Vo.",
        trackName: "Voice",
        minPitchPlayable: 38,
        maxPitchPlayable: 84,
        minPitchAmateur: 41,
        maxPitchAmateur: 79,
        articulations: [
            InstrumentArticulation(),
            InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 50),
        ],
        channels: [InstrumentChannel(program: 52)]
    )
    let xml = original.encode()
    let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
    let reparsed = try XMLTreeParser.parse(bytes)
    let decoded = try Instrument.decode(#require(reparsed.first("Instrument")))
    #expect(decoded == original)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests/instrumentRoundTrip
```
Expected: FAIL.

- [ ] **Step 3: Implement Instrument encoder**

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Instrument {
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let longName {
            children.append(XMLTreeNode(name: "longName", text: longName))
        }
        if let shortName {
            children.append(XMLTreeNode(name: "shortName", text: shortName))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        if let v = minPitchPlayable {
            children.append(XMLTreeNode(name: "minPitchP", text: String(v)))
        }
        if let v = maxPitchPlayable {
            children.append(XMLTreeNode(name: "maxPitchP", text: String(v)))
        }
        if let v = minPitchAmateur {
            children.append(XMLTreeNode(name: "minPitchA", text: String(v)))
        }
        if let v = maxPitchAmateur {
            children.append(XMLTreeNode(name: "maxPitchA", text: String(v)))
        }
        if useDrumset {
            children.append(XMLTreeNode(name: "useDrumset", text: "1"))
        }
        for pitch in drumLineMap.keys.sorted() {
            children.append(XMLTreeNode(
                name: "Drum",
                attributes: ["pitch": String(pitch)],
                children: [
                    XMLTreeNode(name: "line", text: String(drumLineMap[pitch] ?? 0)),
                ]
            ))
        }
        for art in articulations {
            children.append(art.encode())
        }
        for chan in channels {
            children.append(chan.encode())
        }
        return XMLTreeNode(
            name: "Instrument",
            attributes: ["id": id],
            children: children
        )
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Instrument

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Encode `Part` (declaration only) + top-level `Staff`

The mscx file format splits a Part into two regions:
1. **`<Part id="N">`** — the declaration: `<Staff>` (StaffType + bracket info), `<trackName>`, `<Instrument>`.
2. **Top-level `<Staff id="N">`** — the body: `<Measure>` chain.

The `Score.parts[i].staves[j]` model collapses these. The encoder splits them back: emits each Part's declaration block, plus one top-level `<Staff id="N">` block per staff. Staff IDs are synthesized as `"<partID>:<staffIndex>"` if the original Score didn't carry them — but for the round-trip case the parser drops the IDs entirely, so we generate fresh sequential IDs. The crucial property is consistency: the declaration's id matches the body's id.

**Files:**
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift`
- Create: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`
- Modify: `Tests/SheetMusicTests/MSCXEncoderTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
@Test("Single-staff Part round-trips through encode + parse")
func partWithStaffRoundTrip() throws {
    let staff = Staff(
        staffType: "stdNormal",
        group: "pitched",
        defaultClefType: nil,
        measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
            ])]),
        ]
    )
    let part = Part(
        id: "1",
        trackName: "Voice",
        instrument: Instrument(id: "voice"),
        staves: [staff]
    )
    let original = Score(division: 480, parts: [part])

    let bytes = try MSCXEncoder.encode(original)
    let reparsed = try MSCXParser.parse(bytes)

    #expect(reparsed.parts.count == 1)
    #expect(reparsed.parts[0] == part)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXEncoderTests/partWithStaffRoundTrip
```
Expected: FAIL — Score-level encoder doesn't yet emit Parts or top-level Staves.

- [ ] **Step 3: Implement the Staff encoder**

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Encode the per-Part `<Staff>` declaration block — staff type,
    /// bracket information, default clef. Measures are emitted by
    /// `encodeTopLevel(staffID:)` separately.
    func encodeDeclaration(staffID: String) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(
            name: "StaffType",
            attributes: ["group": group],
            children: [
                XMLTreeNode(name: "name", text: staffType),
            ]
        ))
        if let defaultClefType {
            children.append(XMLTreeNode(
                name: "defaultClef", text: defaultClefType
            ))
        }
        for bracket in brackets {
            var bracketAttrs: [String: String] = [
                "type": String(bracket.type.rawValue),
                "span": String(bracket.span),
                "col": String(bracket.column),
            ]
            if !bracket.visible { bracketAttrs["visible"] = "0" }
            children.append(XMLTreeNode(
                name: "bracket", attributes: bracketAttrs
            ))
        }
        return XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: children
        )
    }

    /// Encode the top-level `<Staff id="N">` block carrying measures.
    func encodeTopLevel(staffID: String) -> XMLTreeNode {
        XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: measures.map { $0.encode() }
        )
    }
}
```

- [ ] **Step 4: Implement the Part encoder**

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    /// Build the `<Part id="...">` declaration block. The
    /// per-staff IDs passed in here must match the IDs used when
    /// emitting the top-level `<Staff id="...">` blocks at
    /// `Score.encode()` (otherwise the round-trip parser fails to
    /// pair declarations with bodies).
    func encodeDeclaration(staffIDs: [String]) -> XMLTreeNode {
        precondition(staffIDs.count == staves.count,
                     "staffIDs must match staves count")
        var children: [XMLTreeNode] = []
        for (staff, id) in zip(staves, staffIDs) {
            children.append(staff.encodeDeclaration(staffID: id))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        children.append(instrument.encode())
        return XMLTreeNode(
            name: "Part",
            attributes: ["id": id],
            children: children
        )
    }
}
```

- [ ] **Step 5: Wire Parts + top-level Staves into Score encoder**

Replace the body of `Score.encode()` in `MSCXEncoder+Score.swift` with:

```swift
func encode() -> XMLTreeNode {
    var scoreChildren: [XMLTreeNode] = []
    scoreChildren.append(XMLTreeNode(
        name: "Division", text: String(division)
    ))
    scoreChildren.append(style.encode())
    for key in metaTags.keys.sorted() {
        scoreChildren.append(XMLTreeNode(
            name: "metaTag",
            attributes: ["name": key],
            text: metaTags[key] ?? ""
        ))
    }

    // Synthesize stable per-staff IDs. Decoder pairs declared <Staff>
    // entries with top-level <Staff id="N"> bodies by id, so the
    // declaration and body must agree. Encoding `partID-staffIndex`
    // yields globally-unique strings even with multiple parts.
    var allStaffIDs: [(part: Part, ids: [String])] = []
    for part in parts {
        let ids = part.staves.indices.map { "\(part.id)-\($0)" }
        allStaffIDs.append((part, ids))
    }
    for (part, ids) in allStaffIDs {
        scoreChildren.append(part.encodeDeclaration(staffIDs: ids))
    }
    for (part, ids) in allStaffIDs {
        for (staff, id) in zip(part.staves, ids) {
            scoreChildren.append(staff.encodeTopLevel(staffID: id))
        }
    }

    return XMLTreeNode(
        name: "museScore",
        attributes: ["version": "4.60"],
        children: [
            XMLTreeNode(name: "Score", children: scoreChildren),
        ]
    )
}
```

- [ ] **Step 6: Run tests**

```bash
swift test --filter MSCXEncoderTests
```
Expected: PASS for all encoder tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift \
        Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift \
        Tests/SheetMusicTests/MSCXEncoderTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): encode Part declaration + top-level Staff bodies

The mscx format splits a Part into a declaration block (StaffType,
trackName, Instrument) and one top-level <Staff id="N"> per staff
holding the measure chain. The Score encoder synthesizes stable
"<partID>-<staffIndex>" IDs to bind declarations to bodies.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: midi01 round-trip integration test

The contract. Parse the actual `midi01.mscx` fixture, encode the resulting `Score`, re-parse, assert `==`.

**Files:**
- Create: `Tests/SheetMusicTests/MSCXRoundTripTests.swift`

- [ ] **Step 1: Write the round-trip test**

`Tests/SheetMusicTests/MSCXRoundTripTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("MSCX round-trip")
struct MSCXRoundTripTests {
    @Test("midi01.mscx parse → encode → parse preserves Score equality")
    func midi01RoundTrip() throws {
        let originalData = try MSCXFixtureLoader.mscxData("midi01")
        let original = try MSCXParser.parse(originalData)

        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)

        #expect(roundTripped == original)
    }
}
```

- [ ] **Step 2: Run the round-trip test**

```bash
swift test --filter MSCXRoundTripTests
```
Expected: PASS. If it fails, the failure message names the differing field — drop into a debugger or print `dump(original)` vs `dump(roundTripped)` to localize. Most likely culprits: a field the parser captures that we forgot to encode (check Instrument fields vs midi01 fixture lines).

- [ ] **Step 3: Run the full test suite to catch regressions**

```bash
swift test
```
Expected: all suites pass. The test count grows by the new XMLTreeSerializer / MSCXEncoder / MSCXRoundTrip suites.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/MSCXRoundTripTests.swift
git commit -m "$(cat <<'EOF'
test(mscx): midi01 round-trips through MSCXEncoder

The Phase 1 contract: parse midi01.mscx, encode the resulting Score,
re-parse the bytes, expect Equatable equality.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: `MSCZWriter.write(score:)` overload + round-trip test

Reuse the existing low-level `MSCZWriter.write(mscxData:)` by serialising the Score first.

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCZWriter.swift`
- Modify: `Tests/SheetMusicTests/MSCXRoundTripTests.swift`

- [ ] **Step 1: Add a failing test**

Append to `MSCXRoundTripTests.swift`:

```swift
@Test("midi01 round-trips through MSCZWriter.write(score:) → MSCZReader")
func midi01MSCZRoundTrip() throws {
    let originalData = try MSCXFixtureLoader.mscxData("midi01")
    let original = try MSCXParser.parse(originalData)

    let mscz = try MSCZWriter.write(score: original)
    let roundTripped = try MSCZReader.parse(mscz)

    #expect(roundTripped == original)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXRoundTripTests/midi01MSCZRoundTrip
```
Expected: FAIL — `MSCZWriter.write(score:)` undefined.

- [ ] **Step 3: Implement the high-level overloads**

Append to `Sources/SheetMusicMSCX/MSCZWriter.swift` (after the existing `write(mscxData:to:)` method, before `validate(mainFileName:)`):

```swift
    /// Serialize a `Score` to `.mscx` and package the result as
    /// `.mscz` bytes.
    public static func write(
        score: Score, mainFileName: String = "score.mscx"
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    /// Serialize a `Score` to `.mscx` and write the resulting
    /// `.mscz` to a file URL.
    public static func write(
        score: Score, to url: URL, mainFileName: String = "score.mscx"
    ) throws {
        let bytes = try write(score: score, mainFileName: mainFileName)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXRoundTripTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCZWriter.swift \
        Tests/SheetMusicTests/MSCXRoundTripTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): MSCZWriter.write(score:) overload

Score → .mscx (via MSCXEncoder) → .mscz packaging. The midi01
fixture round-trips through the full MSCZ pipeline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 17: `SheetMusic` façade methods

Mirror existing `loadScore` / `saveMSCZ` style — add `exportMSCX` and `exportMSCZ`.

**Files:**
- Modify: `Sources/SheetMusic/SheetMusic.swift`
- Modify: `Tests/SheetMusicTests/MSCXRoundTripTests.swift`

- [ ] **Step 1: Add a failing test**

Append to `MSCXRoundTripTests.swift`:

```swift
@Test("SheetMusic.exportMSCX writes a parseable file")
func facadeExportMSCX() throws {
    let originalData = try MSCXFixtureLoader.mscxData("midi01")
    let original = try MSCXParser.parse(originalData)

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".mscx")
    try SheetMusic.exportMSCX(original, to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let roundTripped = try SheetMusic.loadScore(mscxURL: tmp)
    #expect(roundTripped == original)
}

@Test("SheetMusic.exportMSCZ writes a parseable archive")
func facadeExportMSCZ() throws {
    let originalData = try MSCXFixtureLoader.mscxData("midi01")
    let original = try MSCXParser.parse(originalData)

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".mscz")
    try SheetMusic.exportMSCZ(original, to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let roundTripped = try SheetMusic.loadScore(msczURL: tmp)
    #expect(roundTripped == original)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MSCXRoundTripTests
```
Expected: FAIL — `exportMSCX` / `exportMSCZ` undefined.

- [ ] **Step 3: Add façade methods**

Append to the `public enum SheetMusic` body in `Sources/SheetMusic/SheetMusic.swift` (place after `saveMSCZ(mscxData:to:)`):

```swift
    /// Serialize a `Score` to `.mscx` and write the result to a file URL.
    public static func exportMSCX(_ score: Score, to url: URL) throws {
        try MSCXEncoder.encode(score, to: url)
    }

    /// Serialize a `Score` to `.mscz` and write the result to a file URL.
    public static func exportMSCZ(_ score: Score, to url: URL) throws {
        try MSCZWriter.write(score: score, to: url)
    }
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MSCXRoundTripTests
```
Expected: PASS.

- [ ] **Step 5: Run the full suite**

```bash
swift test
```
Expected: 100% green. Lint check:

```bash
swiftlint --quiet Sources Tests
```
Expected: 0 warnings/errors. (Skip if SwiftLint isn't installed locally — CI catches it.)

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusic/SheetMusic.swift \
        Tests/SheetMusicTests/MSCXRoundTripTests.swift
git commit -m "$(cat <<'EOF'
feat(mscx): SheetMusic.exportMSCX / exportMSCZ façade

Closes the symmetric loop: import via SheetMusic.loadScore, mutate,
write back via SheetMusic.exportMSCX / exportMSCZ.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 18: Update README to advertise the new export

Three small edits in `README.md`:

1. The opening paragraph (lines 3–6) currently mentions only MIDI export. Add MSCX export.
2. The library table row for `SheetMusicMSCX` (line 19) hides the new write capability behind a generic phrase.
3. Add a round-trip usage snippet to the "Example" section (around line 70).

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the opening paragraph**

Replace this line at line 3–6:

```
A Swift package for working with engraved music notation: parsing
MuseScore (`.mscx`) score files, modelling them as Swift value types, and
exporting them to Standard MIDI Files. Built from scratch in Swift, with
no direct runtime dependency on the MuseScore application.
```

With:

```
A Swift package for working with engraved music notation: parsing
MuseScore (`.mscx` / `.mscz`) score files, modelling them as Swift value
types, and exporting them back to MuseScore format or to Standard MIDI
Files. Built from scratch in Swift, with no direct runtime dependency
on the MuseScore application.
```

- [ ] **Step 2: Update the library table row at line 19**

Replace:

```
| `SheetMusicMSCX` | MuseScore file I/O: `.mscx` parsing and `.mscz` read/write (main score only). |
```

With:

```
| `SheetMusicMSCX` | MuseScore file I/O: `.mscx` / `.mscz` read and write (main score only). |
```

- [ ] **Step 3: Add a round-trip example after the "Example" snippet**

Just below the existing snippet ending at the `try midi.write(to: someOutputMIDIURL)` line (currently line 69), insert a new paragraph + code block:

```markdown
Round-trip a score back to MuseScore format after editing the model:

\`\`\`swift
let score = try SheetMusic.loadScore(mscxURL: input)
// … mutate `score` …
try SheetMusic.exportMSCX(score, to: outputMSCX)
// or, packaged as a .mscz archive:
try SheetMusic.exportMSCZ(score, to: outputMSCZ)
\`\`\`
```

(In the actual README, use real triple-backticks — the escapes here are only to embed a fenced block inside this plan document.)

- [ ] **Step 4: Sanity-check the diff**

```bash
git diff README.md
```
Expected: three localized hunks — the opening paragraph, the table row, and the inserted example block. No other changes.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: advertise SheetMusic.exportMSCX / exportMSCZ in README

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

Run from inside the worktree:

```bash
swift build
swift test
git log --oneline main..HEAD
```

Expected:
- `swift build` succeeds
- `swift test` passes 100%
- `git log` shows the chain of commits from Task 1 through Task 18 on `feature/mscx-export`

---

## Self-review notes (preserved for posterity)

- **Spec coverage**: All Phase-1 elements listed in the spec's encoder file table are implemented (Score, Style, Part, Staff, Instrument, Measure, Voice, Chord, Note, Rest-as-empty-Chord, KeySig, TimeSig, Clef). Tempo / Misc-helpers are absent because midi01 doesn't exercise them; they belong in Phase 2 alongside other VoiceElement cases that the Voice encoder currently traps on.
- **Type consistency**: All encoders expose a method named `encode()` returning `XMLTreeNode`; the special cases (`encodeAsChord` / `encodeAsRest` on Chord, `encodeDeclaration(staffIDs:)` / `encodeTopLevel(staffID:)` on Part / Staff) are explicitly named to disambiguate the two sites that consume them.
- **Out of scope reminders**: Tuplets, Spanners (ties/glissandos at the chord/note level), MeasureRepeat, Dynamics, Tempo, Harmony, RehearsalMark, StaffText, Fermata, BarLine, Markers, Jumps, LayoutBreaks, ScoreFrame (titleFrame), pageLayout / pageChrome — all deferred. The Voice encoder traps on these to make accidental reach-out from a richer Score loud rather than silent.
