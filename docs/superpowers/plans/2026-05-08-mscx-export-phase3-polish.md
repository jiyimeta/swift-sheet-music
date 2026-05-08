# MSCX Export — Phase 3 Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MSCX encoder emit a `<Style>` block that omits fields equal to MuseScore defaults, and round-trip cross-measure spanner `<fractions>` offsets that today are silently dropped.

**Architecture:** Two independent, additive changes. Part A rewrites `MSCXEncoder+Style.swift` to gate every per-field append on `value != defaultValue`, sourcing defaults from the existing `ScoreStyle.museScoreDefaults`. Part B adds an optional `nextFractionsOffset: Fraction?` field on `Spanner` and wires the decoder/encoder for the `<next><location><fractions>` element MuseScore emits when a spanner ends mid-measure. Decoder defaults already overlay onto `museScoreDefaults`, so elided fields round-trip back to the same values; spanners gain a new optional field with default `nil`, source-compatible with existing call sites.

**Tech Stack:** Swift 5.9+, Swift Package Manager, Swift Testing (`@Test`/`#expect`), `XMLTreeNode`/`XMLTreeParser`/`XMLTreeSerializer` from `SheetMusicXMLTools`. No new dependencies.

**Branch:** `feature/mscx-export` (continues — no new branch). 37 commits ahead of `main` at start.

**Spec:** `docs/superpowers/specs/2026-05-08-mscx-export-phase3-polish-design.md`

---

## File Structure

**Modified:**
- `Sources/SheetMusicCore/Score/Spanner.swift` — add `nextFractionsOffset: Fraction?` stored property + initializer param (default `nil`).
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift` — read `<next><location><fractions>` text into `nextFractionsOffset`.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift` — emit `<next>` wrapper when either `nextMeasuresOffset != 0` or `nextFractionsOffset != nil`; inner `<location>` carries `<fractions>` then `<measures>`, each gated.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift` — replace unconditional `children.append(...)` with `emitIfNotDefault` calls referencing `ScoreStyle.museScoreDefaults`. Spatium stays unconditional. Even-side header/footer fields suppressed entirely when `oddEvenDifferent == false`.

**Created:**
- `Tests/SheetMusicTests/MSCXEncoderStyleCompactnessTests.swift` — Style emission compactness suite.
- `Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift` — spanner `<fractions>` round-trip suite.

**Untouched (no changes intended):**
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Style.swift` — already overlays defaults; gated emission relies on this behaviour.
- All other encoder/decoder files. All existing tests must remain green (currently 710).

---

## Task 1: Spanner core — add `nextFractionsOffset`

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Spanner.swift`

- [ ] **Step 1.1: Read current Spanner.swift** to confirm baseline before editing.

Run: `cat Sources/SheetMusicCore/Score/Spanner.swift`

- [ ] **Step 1.2: Add the new optional field and initializer parameter.**

Replace the body of `public struct Spanner` so it reads:

```swift
public struct Spanner: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case volta = "Volta"
        case slur = "Slur"
        case hairpin = "HairPin"
        case pedal = "Pedal"
        case ottava = "Ottava"
        case textLine = "TextLine"
        case glissando = "Glissando"
        case other
    }

    public var kind: Kind
    public var rawType: String // original "type" attribute
    public var nextMeasuresOffset: Int // distance to the spanner end in measures
    /// MuseScore `<next><location><fractions>N/D</fractions></location></next>`
    /// inside a `<Spanner>`. Optional because most cross-measure
    /// spanners only emit `<measures>` (whole-measure offsets); the
    /// non-nil case is spanners that end mid-measure.
    public var nextFractionsOffset: Fraction?
    public var voltaEndings: [Int] // for Volta: the take-numbers (1, 2, …)
    /// MuseScore `<visible>0</visible>` flag. When false the spanner
    /// is hidden — layout omits it entirely (no glyphs, no reserved
    /// space). Playback / MIDI continue to honour the spanner.
    public var visible: Bool

    public init(
        kind: Kind,
        rawType: String,
        nextMeasuresOffset: Int = 0,
        nextFractionsOffset: Fraction? = nil,
        voltaEndings: [Int] = [],
        visible: Bool = true
    ) {
        self.kind = kind
        self.rawType = rawType
        self.nextMeasuresOffset = nextMeasuresOffset
        self.nextFractionsOffset = nextFractionsOffset
        self.voltaEndings = voltaEndings
        self.visible = visible
    }
}
```

The new parameter is positioned after `nextMeasuresOffset` and before `voltaEndings` so it slots in next to its sibling location field. All existing call sites use keyword arguments or rely on defaults, so adding a defaulted parameter is source-compatible. `Fraction` already conforms to `Hashable` (which implies `Equatable`), so `Spanner: Equatable` synthesis still works with an `Optional<Fraction>` member.

- [ ] **Step 1.3: Build to confirm source compatibility.**

Run: `swift build`
Expected: succeeds with no errors. Any build failure here means an unexpected positional call site exists — find and fix by switching to keyword args before continuing.

- [ ] **Step 1.4: Commit.**

```bash
git add Sources/SheetMusicCore/Score/Spanner.swift
git commit -m "feat(core): add Spanner.nextFractionsOffset"
```

---

## Task 2: Spanner decoder — read `<fractions>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift`
- Test: `Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift` (new — created here, finished in Task 4)

- [ ] **Step 2.1: Write the failing test for parsing `<fractions>`.**

Create `Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for the `<next><location><fractions>` element
/// that MuseScore emits when a spanner ends mid-measure. Phase 1/2
/// silently dropped this; Phase 3 preserves it via
/// `Spanner.nextFractionsOffset`.
@Suite("MSCXEncoder spanner fractions")
struct MSCXEncoderSpannerFractionsTests {
    /// Decode a single `<Spanner>` element from an inline XML literal.
    private func decodeSpanner(_ xml: String) throws -> Spanner {
        let bytes = Data(xml.utf8)
        let root = try XMLTreeParser.parse(bytes)
        return try Spanner.decode(#require(root.first("Spanner")))
    }

    @Test("Decoder reads <fractions> alongside <measures>")
    func decodeFractionsAndMeasures() throws {
        let xml = """
        <root>
          <Spanner type="HairPin">
            <HairPin/>
            <next>
              <location>
                <fractions>1/4</fractions>
                <measures>1</measures>
              </location>
            </next>
          </Spanner>
        </root>
        """
        let spanner = try decodeSpanner(xml)
        #expect(spanner.nextFractionsOffset == Fraction(numerator: 1, denominator: 4))
        #expect(spanner.nextMeasuresOffset == 1)
    }

    @Test("Decoder leaves nextFractionsOffset nil when <fractions> absent")
    func decodeMeasuresOnlyKeepsFractionsNil() throws {
        let xml = """
        <root>
          <Spanner type="Volta">
            <Volta><endings>1</endings></Volta>
            <next>
              <location>
                <measures>2</measures>
              </location>
            </next>
          </Spanner>
        </root>
        """
        let spanner = try decodeSpanner(xml)
        #expect(spanner.nextFractionsOffset == nil)
        #expect(spanner.nextMeasuresOffset == 2)
    }
}
```

- [ ] **Step 2.2: Run the new tests to verify they fail.**

Run: `swift test --filter MSCXEncoderSpannerFractionsTests`
Expected: `decodeFractionsAndMeasures` fails (`nextFractionsOffset` is `nil`, not `Fraction(1,4)`); `decodeMeasuresOnlyKeepsFractionsNil` may already pass.

- [ ] **Step 2.3: Update the decoder.**

Replace the body of `Spanner.decode` in `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift` with:

```swift
extension Spanner {
    static func decode(_ node: XMLTreeNode) throws -> Spanner {
        let raw = node.attributes["type"] ?? ""
        let kind = Kind(rawValue: raw) ?? .other

        var voltaEndings: [Int] = []
        if let voltaNode = node.first("Volta") {
            let endingsText = voltaNode.first("endings")?.text ?? ""
            voltaEndings = endingsText
                .split(whereSeparator: { ", ".contains($0) })
                .compactMap { Int($0) }
        }

        let nextLocation = node.first("next")?.first("location")
        let nextMeasures = Int(nextLocation?.first("measures")?.text ?? "0") ?? 0
        let nextFractions = nextLocation?.first("fractions")?.text
            .flatMap { Fraction(mscxString: $0) }

        return Spanner(
            kind: kind,
            rawType: raw,
            nextMeasuresOffset: nextMeasures,
            nextFractionsOffset: nextFractions,
            voltaEndings: voltaEndings,
            visible: decodeVisible(node)
        )
    }

    /// MuseScore writes a spanner as a *pair* of `<Spanner>` elements
    /// — the begin-side carries the subtype payload (`<Pedal>`,
    /// `<HairPin>`, `<Volta>`, ...) plus a `<next>` location to the
    /// end tick; the end-side is a placeholder with only a `<prev>`
    /// location pointing back. The end-side has no own glyph and
    /// would otherwise emit a duplicate zero-length anchor at the
    /// end tick — treat it as hidden so the layout filter drops it.
    ///
    /// On the begin-side, MuseScore stores `<visible>0</visible>` on
    /// the inner subtype child (not on the `<Spanner>` wrapper). We
    /// honour either location and treat any `0` as hidden.
    private static func decodeVisible(_ node: XMLTreeNode) -> Bool {
        if (node.first("visible")?.text ?? "1") == "0" { return false }
        var hasPayload = false
        for child in node.children
            where child.name != "next" && child.name != "prev"
        {
            hasPayload = true
            if child.first("visible")?.text == "0" { return false }
        }
        return hasPayload
    }
}
```

The change extracts the `<location>` node once and reads both `<measures>` and `<fractions>` from it. `Fraction.init?(mscxString:)` already exists in `SheetMusicCore/Score/Fraction.swift:17` and parses `"N/D"` text.

- [ ] **Step 2.4: Run the new tests to verify they pass.**

Run: `swift test --filter MSCXEncoderSpannerFractionsTests`
Expected: both decoder tests pass.

- [ ] **Step 2.5: Run the existing spanner suite to confirm no regression.**

Run: `swift test --filter MSCXEncoderSpannersTests`
Expected: every test still passes (decoder still produces `nextMeasuresOffset` correctly; new field defaults to `nil` for fixtures with no `<fractions>`).

- [ ] **Step 2.6: Commit.**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift \
        Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift
git commit -m "feat(mscx): decode spanner <next><location><fractions>"
```

---

## Task 3: Spanner encoder — emit `<fractions>` and gate `<measures>`

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift`
- Test: `Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift` (extend)

- [ ] **Step 3.1: Add the failing encode round-trip tests.**

Append the following test cases to `Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift` inside the existing `@Suite` struct:

```swift
    /// Round-trip: encode → reparse → compare.
    private func roundTrip(_ spanner: Spanner) throws -> Spanner {
        let xml = spanner.encode()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Spanner.decode(#require(reparsed.first("Spanner")))
    }

    @Test("Encoder emits <fractions> before <measures>")
    func encoderEmitsFractionsBeforeMeasures() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 1,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4)
        )
        let xml = spanner.encode()
        let location = try #require(
            xml.first("next")?.first("location"))
        let names = location.children.map(\.name)
        #expect(names == ["fractions", "measures"])
        #expect(location.first("fractions")?.text == "1/4")
        #expect(location.first("measures")?.text == "1")
    }

    @Test("Round-trip preserves nextFractionsOffset alongside measures")
    func roundTripPreservesBothOffsets() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 2,
            nextFractionsOffset: Fraction(numerator: 3, denominator: 8)
        )
        let decoded = try roundTrip(spanner)
        #expect(decoded.nextMeasuresOffset == 2)
        #expect(decoded.nextFractionsOffset == Fraction(numerator: 3, denominator: 8))
    }

    @Test("Round-trip preserves nextFractionsOffset with measures = 0")
    func roundTripFractionsOnly() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 2)
        )
        let decoded = try roundTrip(spanner)
        #expect(decoded.nextMeasuresOffset == 0)
        #expect(decoded.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
    }

    @Test("Round-trip preserves measures-only spanner (fractions stays nil)")
    func roundTripMeasuresOnly() throws {
        let spanner = Spanner(
            kind: .volta,
            rawType: "Volta",
            nextMeasuresOffset: 1,
            voltaEndings: [1]
        )
        let decoded = try roundTrip(spanner)
        #expect(decoded.nextMeasuresOffset == 1)
        #expect(decoded.nextFractionsOffset == nil)
    }
```

- [ ] **Step 3.2: Run the new tests to verify they fail.**

Run: `swift test --filter MSCXEncoderSpannerFractionsTests`
Expected: the four new encoder tests fail — current encoder ignores `nextFractionsOffset` entirely, so `<fractions>` is never emitted and the round-trip drops it.

- [ ] **Step 3.3: Update the encoder.**

Replace the body of `MSCXEncoder+Spanner.swift` with:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Spanner {
    /// Build a `<Spanner type="X">` element. MuseScore writes spanners
    /// as a *pair* — a begin-side carrying the subtype payload (e.g.
    /// `<Volta>`, `<HairPin/>`, `<Slur/>`) plus a `<next>` location to
    /// the end tick, and an end-side placeholder with only `<prev>`.
    ///
    /// We dispatch on `visible`: a begin-side preserves the payload
    /// (and Volta endings / measures + fractions offsets), an
    /// end-side emits just `<prev/>` so the parser recovers
    /// `visible == false`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if visible {
            children.append(payloadElement())
            if let next = nextLocationElement() {
                children.append(next)
            }
        } else {
            children.append(XMLTreeNode(name: "prev"))
        }
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": rawType],
            children: children
        )
    }

    /// The begin-side payload child. MuseScore names this child after
    /// the type — `<Volta>…</Volta>`, `<Slur/>`, `<HairPin/>`, etc.
    /// Volta carries `<endings>` (comma-joined ending numbers); other
    /// kinds are emitted as empty placeholders, since the only fields
    /// the decoder recovers from them are positional.
    private func payloadElement() -> XMLTreeNode {
        if kind == .volta, !voltaEndings.isEmpty {
            let endingsText = voltaEndings.map(String.init).joined(separator: ", ")
            return XMLTreeNode(name: rawType, children: [
                XMLTreeNode(name: "endings", text: endingsText),
            ])
        }
        return XMLTreeNode(name: rawType)
    }

    /// `<next><location>…</location></next>`. Returns nil when both
    /// offsets are at their defaults (no end-side anchor needed).
    /// Element order inside `<location>`: `<fractions>` then
    /// `<measures>`, mirroring MuseScore's writer
    /// (`engraving/types/location.cpp::Location::write`).
    private func nextLocationElement() -> XMLTreeNode? {
        var locationChildren: [XMLTreeNode] = []
        if let frac = nextFractionsOffset {
            locationChildren.append(XMLTreeNode(
                name: "fractions",
                text: "\(frac.numerator)/\(frac.denominator)"))
        }
        if nextMeasuresOffset != 0 {
            locationChildren.append(XMLTreeNode(
                name: "measures",
                text: String(nextMeasuresOffset)))
        }
        guard !locationChildren.isEmpty else { return nil }
        return XMLTreeNode(name: "next", children: [
            XMLTreeNode(name: "location", children: locationChildren),
        ])
    }
}
```

`Fraction` has no `mscxEncoded`/`description` accessor that produces `"N/D"`, so format inline. Order matches MuseScore's `Location::write` (fractions first).

- [ ] **Step 3.4: Run the new tests to verify they pass.**

Run: `swift test --filter MSCXEncoderSpannerFractionsTests`
Expected: all six tests in the suite pass.

- [ ] **Step 3.5: Run the full existing spanner suite.**

Run: `swift test --filter MSCXEncoderSpannersTests`
Expected: still 100% green — `nextLocationElement` returns the same shape as before whenever `nextFractionsOffset == nil`.

- [ ] **Step 3.6: Run the full test suite to catch any cross-suite regression.**

Run: `swift test`
Expected: 710 + 6 new tests = 716 (or more) pass; 0 failures.

- [ ] **Step 3.7: Commit.**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift \
        Tests/SheetMusicTests/MSCXEncoderSpannerFractionsTests.swift
git commit -m "feat(mscx): encode spanner <next><location><fractions>"
```

---

## Task 4: Style encoder — skip-if-default emission

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`
- Test: `Tests/SheetMusicTests/MSCXEncoderStyleCompactnessTests.swift` (new)

- [ ] **Step 4.1: Write the failing compactness tests.**

Create `Tests/SheetMusicTests/MSCXEncoderStyleCompactnessTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Phase 3 polish: encoder elides `<Style>` fields that equal
/// MuseScore's documented defaults so re-encoded scores stay close to
/// MuseScore Studio's terse output. Decoder already overlays
/// `ScoreStyle.museScoreDefaults`, so elided fields round-trip back
/// to the same value.
@Suite("MSCXEncoder Style compactness")
struct MSCXEncoderStyleCompactnessTests {
    /// Encode a Score, reparse the bytes, and return the inner
    /// `<Style>` element so individual children can be inspected.
    private func encodedStyleNode(_ score: Score) throws -> XMLTreeNode {
        let bytes = try MSCXEncoder.encode(score)
        let root = try XMLTreeParser.parse(bytes)
        let museScore = try #require(root.first("museScore"))
        let scoreNode = try #require(museScore.first("Score"))
        return try #require(scoreNode.first("Style"))
    }

    @Test("Default ScoreStyle emits only <spatium>")
    func defaultStyleEmitsOnlySpatium() throws {
        let score = Score(division: 480, style: .museScoreDefaults)
        let style = try encodedStyleNode(score)
        let names = style.children.map(\.name)
        #expect(names == ["spatium"])
    }

    @Test("Overriding pageWidth emits only spatium + pageWidth")
    func selectiveOverrideEmitsOnlyChangedField() throws {
        var s = ScoreStyle.museScoreDefaults
        s.pageLayout.width = 12.0
        let score = Score(division: 480, style: s)
        let style = try encodedStyleNode(score)
        let names = style.children.map(\.name)
        #expect(Set(names) == Set(["spatium", "pageWidth"]))
        #expect(style.first("pageWidth")?.text == "12.0")
    }

    @Test("Header.oddEvenDifferent == false suppresses evenHeader* fields")
    func defaultHeaderOmitsEvenSideWhenSingleSided() throws {
        var s = ScoreStyle.museScoreDefaults
        // Default header has oddEvenDifferent = true; flip it off and
        // change odd.left so the header block isn't *entirely* default.
        s.pageChrome.header.oddEvenDifferent = false
        s.pageChrome.header.odd = TextRow(left: "L", center: "", right: "")
        let score = Score(division: 480, style: s)
        let style = try encodedStyleNode(score)
        let names = Set(style.children.map(\.name))
        #expect(!names.contains("evenHeaderL"))
        #expect(!names.contains("evenHeaderC"))
        #expect(!names.contains("evenHeaderR"))
        #expect(names.contains("oddHeaderL"))
        #expect(names.contains("headerOddEven"))
    }

    @Test("Header.oddEvenDifferent == true re-enables evenHeader* gating")
    func evenHeaderEmittedWhenDifferentAndNonDefault() throws {
        var s = ScoreStyle.museScoreDefaults
        s.pageChrome.header.even = TextRow(left: "X", center: "", right: "")
        let score = Score(division: 480, style: s)
        let style = try encodedStyleNode(score)
        #expect(style.first("evenHeaderL")?.text == "X")
        // evenHeaderC / evenHeaderR are still default ("") and stay elided.
        #expect(style.first("evenHeaderC") == nil)
        #expect(style.first("evenHeaderR") == nil)
    }

    @Test("Default style still round-trips through parse")
    func defaultStyleRoundTrip() throws {
        let original = Score(division: 480, style: .museScoreDefaults)
        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)
        #expect(reparsed.style == ScoreStyle.museScoreDefaults)
    }
}
```

- [ ] **Step 4.2: Run the new tests to verify they fail.**

Run: `swift test --filter MSCXEncoderStyleCompactnessTests`
Expected: the first four tests fail (today's encoder emits ~30+ children unconditionally, including `pageWidth`, `evenHeaderL`, etc.). `defaultStyleRoundTrip` should already pass — it only proves we don't break round-trip.

- [ ] **Step 4.3: Rewrite `MSCXEncoder+Style.swift` with gated emission.**

Replace the entire contents of `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift` with:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreStyle {
    /// Build the `<Style>` block. Emits page geometry, spatium, and
    /// the page-level chrome (header / footer / page numbers) in the
    /// same field order MuseScore writes — see
    /// `engraving/style/styledef.cpp`. Each per-field child is gated
    /// on `value != ScoreStyle.museScoreDefaults.<field>` so the
    /// emitted XML matches MuseScore Studio's terse output. Spatium
    /// is always emitted (MuseScore's writer also always anchors
    /// it). The decoder overlays the same defaults, so elided fields
    /// round-trip back to the same value.
    func encode() -> XMLTreeNode {
        let defaults = ScoreStyle.museScoreDefaults
        var children: [XMLTreeNode] = []
        appendPageLayout(pageLayout, defaults: defaults.pageLayout, into: &children)
        // Spatium is unconditionally emitted: MuseScore Studio always
        // writes a `<spatium>` anchor, and downstream readers expect
        // it as the canonical place to discover engraving units.
        children.append(double("spatium", spatium))
        appendHeader(
            pageChrome.header,
            defaults: defaults.pageChrome.header,
            into: &children
        )
        appendFooter(
            pageChrome.footer,
            defaults: defaults.pageChrome.footer,
            into: &children
        )
        appendPageNumber(
            pageChrome.pageNumber,
            defaults: defaults.pageChrome.pageNumber,
            into: &children
        )
        return XMLTreeNode(name: "Style", children: children)
    }
}

private func appendPageLayout(
    _ layout: PageLayout,
    defaults d: PageLayout,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("pageWidth", layout.width, default: d.width, double, into: &children)
    emitIfNotDefault("pageHeight", layout.height, default: d.height, double, into: &children)
    emitIfNotDefault("pagePrintableWidth", layout.printableWidth, default: d.printableWidth, double, into: &children)
    emitIfNotDefault("pageOddTopMargin", layout.oddTopMargin, default: d.oddTopMargin, double, into: &children)
    emitIfNotDefault("pageOddBottomMargin", layout.oddBottomMargin, default: d.oddBottomMargin, double, into: &children)
    emitIfNotDefault("pageOddLeftMargin", layout.oddLeftMargin, default: d.oddLeftMargin, double, into: &children)
    emitIfNotDefault("pageEvenTopMargin", layout.evenTopMargin, default: d.evenTopMargin, double, into: &children)
    emitIfNotDefault("pageEvenBottomMargin", layout.evenBottomMargin, default: d.evenBottomMargin, double, into: &children)
    emitIfNotDefault("pageEvenLeftMargin", layout.evenLeftMargin, default: d.evenLeftMargin, double, into: &children)
    emitIfNotDefault("pageTwosided", layout.twosided, default: d.twosided, bool, into: &children)
}

private func appendHeader(
    _ header: HeaderFooter,
    defaults d: HeaderFooter,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("showHeader", header.enabled, default: d.enabled, bool, into: &children)
    emitIfNotDefault("headerFirstPage", header.showOnFirstPage, default: d.showOnFirstPage, bool, into: &children)
    emitIfNotDefault("headerOddEven", header.oddEvenDifferent, default: d.oddEvenDifferent, bool, into: &children)
    if header.oddEvenDifferent {
        // Even-side fields are dead state when oddEvenDifferent is
        // false — MuseScore omits them entirely in that mode.
        emitIfNotDefault("evenHeaderL", header.even.left, default: d.even.left, text, into: &children)
        emitIfNotDefault("evenHeaderC", header.even.center, default: d.even.center, text, into: &children)
        emitIfNotDefault("evenHeaderR", header.even.right, default: d.even.right, text, into: &children)
    }
    emitIfNotDefault("oddHeaderL", header.odd.left, default: d.odd.left, text, into: &children)
    emitIfNotDefault("oddHeaderC", header.odd.center, default: d.odd.center, text, into: &children)
    emitIfNotDefault("oddHeaderR", header.odd.right, default: d.odd.right, text, into: &children)
    emitIfNotDefault("headerFontFace", header.fontFace, default: d.fontFace, text, into: &children)
    emitIfNotDefault("headerFontSize", header.fontSize, default: d.fontSize, double, into: &children)
    emitIfNotDefault("headerFontStyle", header.fontStyle.rawValue, default: d.fontStyle.rawValue, int, into: &children)
}

private func appendFooter(
    _ footer: HeaderFooter,
    defaults d: HeaderFooter,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("showFooter", footer.enabled, default: d.enabled, bool, into: &children)
    emitIfNotDefault("footerFirstPage", footer.showOnFirstPage, default: d.showOnFirstPage, bool, into: &children)
    emitIfNotDefault("footerOddEven", footer.oddEvenDifferent, default: d.oddEvenDifferent, bool, into: &children)
    if footer.oddEvenDifferent {
        emitIfNotDefault("evenFooterL", footer.even.left, default: d.even.left, text, into: &children)
        emitIfNotDefault("evenFooterC", footer.even.center, default: d.even.center, text, into: &children)
        emitIfNotDefault("evenFooterR", footer.even.right, default: d.even.right, text, into: &children)
    }
    emitIfNotDefault("oddFooterL", footer.odd.left, default: d.odd.left, text, into: &children)
    emitIfNotDefault("oddFooterC", footer.odd.center, default: d.odd.center, text, into: &children)
    emitIfNotDefault("oddFooterR", footer.odd.right, default: d.odd.right, text, into: &children)
    emitIfNotDefault("footerFontFace", footer.fontFace, default: d.fontFace, text, into: &children)
    emitIfNotDefault("footerFontSize", footer.fontSize, default: d.fontSize, double, into: &children)
    emitIfNotDefault("footerFontStyle", footer.fontStyle.rawValue, default: d.fontStyle.rawValue, int, into: &children)
}

private func appendPageNumber(
    _ pn: PageNumberStyle,
    defaults d: PageNumberStyle,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("showPageNumber", pn.enabled, default: d.enabled, bool, into: &children)
    emitIfNotDefault("showPageNumberOne", pn.showOnFirstPage, default: d.showOnFirstPage, bool, into: &children)
    emitIfNotDefault("pageNumberOddEven", pn.oddEvenDifferent, default: d.oddEvenDifferent, bool, into: &children)
    emitIfNotDefault("pageNumberFontFace", pn.fontFace, default: d.fontFace, text, into: &children)
    emitIfNotDefault("pageNumberFontSize", pn.fontSize, default: d.fontSize, double, into: &children)
}

/// Append `formatter(name, value)` only when `value != defaultValue`.
/// Centralises the skip-if-default rule so each per-field call site
/// reads as a single line.
private func emitIfNotDefault<T: Equatable>(
    _ name: String,
    _ value: T,
    default defaultValue: T,
    _ formatter: (String, T) -> XMLTreeNode,
    into children: inout [XMLTreeNode]
) {
    guard value != defaultValue else { return }
    children.append(formatter(name, value))
}

private func double(_ name: String, _ value: Double) -> XMLTreeNode {
    // Swift's default `String(Double)` emits the shortest decimal
    // that re-parses back to the same Double, so round-trip equality
    // holds for arbitrary page-layout values; `%g`'s 6-digit default
    // would clip A3 dimensions like 11.6929… to 11.6929.
    XMLTreeNode(name: name, text: String(value))
}

private func int(_ name: String, _ value: Int) -> XMLTreeNode {
    XMLTreeNode(name: name, text: String(value))
}

private func bool(_ name: String, _ value: Bool) -> XMLTreeNode {
    XMLTreeNode(name: name, text: value ? "1" : "0")
}

private func text(_ name: String, _ value: String) -> XMLTreeNode {
    XMLTreeNode(name: name, text: value)
}
```

Notes:
- Each `emitIfNotDefault` call passes the existing per-type formatter as the trailing argument. The closure type `(String, T) -> XMLTreeNode` matches each formatter's signature.
- Field emission order matches the original file exactly so any non-default field appears in the same position as before.
- The even-side `if header.oddEvenDifferent { … }` guard runs around the even-side block. When the flag itself is the only non-default field, `headerOddEven`/`footerOddEven` is still emitted via the same gated rule, so the flip survives round-trip.

- [ ] **Step 4.4: Run the new compactness tests.**

Run: `swift test --filter MSCXEncoderStyleCompactnessTests`
Expected: all five tests pass.

- [ ] **Step 4.5: Run the existing Style suite to confirm round-trip fidelity.**

Run: `swift test --filter MSCXEncoderStyleTests`
Expected: every test passes — `MSCXEncoderStyleTests` checks parse-after-encode equality, which is unaffected by gated emission since the decoder overlays the same defaults.

- [ ] **Step 4.6: Run the full Style + RoundTrip + remaining suites.**

Run: `swift test --filter "MSCXEncoder|MSCXRoundTrip|MSCXStyleTests|MSCXParser"`
Expected: all suites pass.

- [ ] **Step 4.7: Run the full test suite.**

Run: `swift test`
Expected: 716+ tests pass; 0 failures. If anything fails, the most likely cause is a fixture whose encoded `<Style>` was previously verified by element-count or string-equality — fix the fixture or the test before continuing, do not weaken `emitIfNotDefault`.

- [ ] **Step 4.8: Optional lint pass.**

Run: `swiftlint --quiet Sources Tests` (only if `swiftlint` is on `$PATH`).
Expected: 0 warnings/errors. Project policy is 0 lint findings.

- [ ] **Step 4.9: Commit.**

```bash
git add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift \
        Tests/SheetMusicTests/MSCXEncoderStyleCompactnessTests.swift
git commit -m "feat(mscx): skip-if-default <Style> emission"
```

---

## Task 5: Final verification

**Files:** none modified.

- [ ] **Step 5.1: Re-run the full test suite from a clean state.**

Run: `swift test`
Expected: every test passes; the `--filter` runs in earlier tasks must agree with this aggregate.

- [ ] **Step 5.2: Confirm no unrelated changes are staged.**

Run: `git status`
Expected: working tree clean (every change already committed in Tasks 1–4).

- [ ] **Step 5.3: Inspect the spec checklist.**

Spec goals (re-read `docs/superpowers/specs/2026-05-08-mscx-export-phase3-polish-design.md` "Goals" section):
- "`<Style>` block significantly more compact" → covered by Task 4 (`defaultStyleEmitsOnlySpatium`).
- "Cross-measure spanners with `<fractions>` survive round-trip" → covered by Task 3 (`roundTripPreservesBothOffsets`, `roundTripFractionsOnly`).

If both rows hold, the plan is complete.

---

## Definition of Done

- All five suites in this plan pass: `MSCXEncoderSpannerFractionsTests`, `MSCXEncoderStyleCompactnessTests`, plus the unaffected `MSCXEncoderSpannersTests`, `MSCXEncoderStyleTests`, `MSCXRoundTripTests`.
- `swift test` reports 0 failures across the whole package (716+ tests).
- Four commits on `feature/mscx-export`, in order: `feat(core): add Spanner.nextFractionsOffset`, `feat(mscx): decode spanner <next><location><fractions>`, `feat(mscx): encode spanner <next><location><fractions>`, `feat(mscx): skip-if-default <Style> emission`.
- No changes outside the files listed in **File Structure**. No new dependencies. No fixture additions under `Tests/SheetMusicTests/Resources/`.
