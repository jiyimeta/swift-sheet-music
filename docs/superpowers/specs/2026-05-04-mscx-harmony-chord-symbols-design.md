# MSCX `<Harmony>` import + chord-symbol display

## Goal

Decode MuseScore `<Harmony>` elements from `.mscx` and render them as
chord symbols above the staff, matching MuseScore's default visual
output closely enough that a user familiar with MuseScore would
recognise the layout.

Scope: **display + structural data preservation**. Out of scope:
playback (MIDI realisation), transposition, edit/selection, ChordList
font tweaks (sub/superscripted quality), polychord divider lines,
fret diagrams.

## Approach summary

`<Harmony>` is added to the existing voice-attached element pipeline
the same way `<StaffText>` and `<RehearsalMark>` were. A new
`Harmony` value type lives in `SheetMusicCore`, a `MSCXDecoder+Harmony`
extension parses it, the layout engine treats it as an above-staff
text-like element, and a new `HarmonyRenderer` draws it through the
existing `ResolvedTextStyle` path with one twist: ASCII `b` / `#`
inside the chord name are substituted with Bravura SMuFL accidental
glyphs at layout time, so the output mixes Edwin (or Campania for
Roman numerals) text runs with Bravura glyph runs.

Rendering source of truth is the `<name>` string. `rootTpc`,
`bassTpc`, `*Case`, `harmonyType`, and parenthesis flags are kept on
the model for future transposition and polychord work but are not
consulted by the default renderer beyond picking the text style row
and recognising Roman-numeral leading accidentals.

## Architecture

```
.mscx <Harmony>
   │
   ▼  MSCXDecoder+Harmony.swift                         (new)
SheetMusicCore: Harmony struct                          (new)
   │       └─ HarmonyType, NoteCase enums also new
   │
   ▼  VoiceElement.harmony(Harmony) — new case
   │
   ▼  MSCXDecoder+Voice.swift   case "Harmony": ...     (added line)
   │
   ▼  LayoutEngine: above-staff column packing
   │       └─ LayoutHarmony pre-computes run list +
   │          width via SMuFL accidental substitution
   │
   ▼  SheetMusicUI: HarmonyRenderer.swift               (new)
        ├─ ResolvedTextStyle resolves face/size/style
        └─ Renders mixed runs (text + Bravura glyphs)
```

## SheetMusicCore additions

`Sources/SheetMusicCore/Score/Harmony.swift` (new):

```swift
public struct Harmony: Sendable, Equatable {
    public var name: String
    public var harmonyType: HarmonyType
    public var rootTpc: Int?       // nil ↔ MuseScore TPC_INVALID (-1)
    public var rootCase: NoteCase
    public var bassTpc: Int?
    public var bassCase: NoteCase
    public var leftParen: Bool
    public var rightParen: Bool
    public var play: Bool          // preserved for future MIDI use
    public var offsetX: Double
    public var offsetY: Double
    public var color: ScoreColor?
    public var properties: TextProperties

    public var styleType: TextStyleType {
        switch harmonyType {
        case .standard, .nashville: return .chordSymbolA
        case .roman:                return .chordSymbolRomanNumeral
        }
    }
}

public enum HarmonyType: String, Sendable, Equatable {
    case standard, roman, nashville
}

public enum NoteCase: String, Sendable, Equatable {
    case auto, upper, lower, capitalize
}
```

`Sources/SheetMusicCore/Score/VoiceElement.swift` adds:

```swift
case harmony(Harmony)
```

placed between `.staffText` and `.rehearsalMark` for readability.

## SheetMusicMSCX additions

`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Harmony.swift` (new) —
mirrors `TRead::read(Harmony*, ...)` (`rw/read410/tread.cpp:2970`).
Recognises:

| MSCX element | Harmony field |
|---|---|
| `<name>` | `name` (recursive plain-text concat, like StaffText) |
| `<harmonyType>` | `harmonyType` (0=Standard / 1=Roman / 2=Nashville) |
| `<root>` | `rootTpc` (`-1` → `nil`) |
| `<rootCase>` | `rootCase` (0=auto / 1=upper / 2=lower / 3=capitalize) |
| `<base>` | `bassTpc` (`-1` → `nil`) |
| `<baseCase>` | `bassCase` |
| `<leftParen/>` / `<rightParen/>` | `leftParen` / `rightParen` |
| `<play>` | `play` (`"1"`/`"true"` → true; default true) |
| `<offset x= y=>` | `offsetX` / `offsetY` |
| `<color>` | `color` |
| `<face>` / `<size>` / `<bold>` / `<italic>` / etc. | `properties` via `TextProperties.decode` |

Silently skipped: `<degree>`, `<extension>`, `<function>`,
`<harmonyVoiceLiteral>`, `<harmonyVoicing>`, `<harmonyDuration>`. They
are out-of-scope for this iteration; the decoder is permissive on
purpose so future work can promote them without revisiting fixtures.

The private helpers `decodeColor`, `decodeOffset`, and `plainText(of:)`
currently live as `private static` on `MSCXDecoder+StaffText`. Promote
them to `internal` (still file-scoped to the decoder module) so
`MSCXDecoder+Harmony` calls them directly. No new shared file.

`MSCXDecoder+Voice.swift` gains one case in the switch:

```swift
case "Harmony":
    try elements.append(.harmony(Harmony.decode(child)))
```

placed adjacent to the `StaffText` / `SystemText` cases.

## SheetMusicLayout additions

`Sources/SheetMusicLayout/Layout/LayoutHarmony.swift` (new):

```swift
public struct LayoutHarmony: Sendable, Equatable {
    public var harmony: Harmony
    public var anchorX: Double            // system-relative, before offsetX
    public var y: Double                  // staff-top-relative
    public var runs: [HarmonyRun]
    public var width: Double
}

public struct HarmonyRun: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case smuflAccidental(SMuFLGlyph)
    }
    public var kind: Kind
    public var content: String            // for .text
    public var advance: Double
    public var x: Double                  // origin X relative to anchor
}
```

`LayoutElement.swift` gains `case harmony(LayoutHarmony)`.

### Placement rules

- **Attach staff**: the staff containing the originating voice
  (mirrors `StaffText`).
- **Default placement**: above the staff. New constant on
  `StaffMetrics` — `harmonyPlacementAbove: Double = -2.5` (sp) —
  used as the Y origin.
- **Vertical stack at same tick**: multiple `Harmony` elements at the
  same anchor stack downward in document order. (MuseScore's true
  polychord stacks above split into above/below; out of scope here.)
- **Author offsets**: `offsetX` and `offsetY` (sp) are added to the
  resolved anchor.
- **Width contribution**: `LayoutEngine+Spacing` adds
  `width + 0.5 sp` to the right-spacing demand of the anchor
  chord/rest segment, so adjacent harmonies do not collide.
- **System extent**: `LayoutEngine+Extents` reports the harmony's
  vertical span (≈ `fontSize × 1.2 sp`) into the system top extent so
  systems with chord symbols leave headroom.

### LayoutEngine touch points

- `LayoutEngine+Translate.swift` — emit `LayoutHarmony` from
  `VoiceElement.harmony`.
- `LayoutEngine+Placement.swift` — share the above-staff column with
  rehearsal marks / staff texts.
- `LayoutEngine+Extents.swift` — include harmony height in the
  system top extent.
- `LayoutEngine+Spacing.swift` — fold `width` into the anchor segment
  spacing demand.

### SMuFL accidental substitution

`Sources/SheetMusicLayout/Layout/HarmonyRendering.swift` (new) — pure
helper used at layout time to turn `name` into `[HarmonyRun]`.

Substitution rules (left-to-right scan over `name`):

1. After an alphanumeric character, `b`, `bb`, `#`, `##` are
   recognised as accidentals — emit a `smuflAccidental` run for
   `accidentalFlat` (U+E260), `accidentalDoubleFlat` (U+E264),
   `accidentalSharp` (U+E262), or `accidentalDoubleSharp` (U+E263)
   respectively.
2. When `harmony.harmonyType` is `.roman` or `.nashville`, a leading
   `b` or `#` (i.e. at index 0, before any letter) is also treated
   as an accidental — covers `bIII`, `#vi`, `b5`, `#1`. For
   `.standard`, leading `b`/`#` is left as text (rare in practice;
   ambiguous with mistyped root names).
3. Any other character — including `/`, `(`, `)`, digits, letters,
   and stray punctuation — is appended to a text run.
4. Runs are coalesced: consecutive text characters form one
   `HarmonyRun(kind: .text)`; each accidental gets its own glyph run.

Run widths are measured against the resolved text font (text runs)
and the Bravura font (glyph runs); cumulative `x` offsets are filled
in the same pass. The total cumulative advance becomes
`LayoutHarmony.width`.

`SMuFLGlyph` gains the four accidental cases above (currently the
type already enumerates other glyph cases).

## SheetMusicUI additions

`Sources/SheetMusicUI/Rendering/HarmonyRenderer.swift` (new) —
parallels `StaffTextRenderer.swift`. Per-run dispatch:

```swift
@MainActor
struct HarmonyRenderer {
    static func draw(
        _ h: LayoutHarmony,
        in ctx: GraphicsContext,
        origin: CGPoint,
        spatium: Double,
        style: ResolvedTextStyle
    ) {
        let textFont = style.swiftUIFont(spatium: spatium)
        let smuflFont = SheetMusicFonts.bravuraFont(
            sizePt: style.sizePt(spatium: spatium)
        )
        let color = h.harmony.color.map(Color.init(scoreColor:))
                  ?? style.color
        for run in h.runs {
            let p = CGPoint(x: origin.x + run.x, y: origin.y)
            switch run.kind {
            case .text:
                ctx.draw(
                    Text(run.content)
                        .font(textFont).foregroundColor(color),
                    at: p, anchor: .leading
                )
            case .smuflAccidental(let glyph):
                ctx.drawGlyph(
                    glyph, font: smuflFont, color: color, at: p
                )
            }
        }
    }
}
```

`ScoreLayerBuilder+Element.swift` adds the dispatch arm for
`LayoutElement.harmony`:

```swift
case .harmony(let lh):
    let style = ResolvedTextStyle.resolve(
        properties: lh.harmony.properties,
        styleType: lh.harmony.styleType,
        scoreStyle: scoreStyle
    )
    HarmonyRenderer.draw(
        lh, in: ctx,
        origin: systemOrigin
            .applying(staffOffset)
            .offsetBy(
                dx: lh.anchorX + lh.harmony.offsetX * sp,
                dy: lh.y + lh.harmony.offsetY * sp
            ),
        spatium: sp,
        style: style
    )
```

Selection / hit-test is intentionally **not** wired in this
iteration. `ScoreLayerBuilder+Selection.swift` is unchanged. Editing
chord symbols is a future task.

## Testing

### Fixture

`Tests/SheetMusicTests/Resources/harmony-basic.mscx` — a 4-bar /
1-staff / 4/4 score with one chord symbol per bar:

| Bar | name | harmonyType | Notes |
|---|---|---|---|
| 1 | `C` | standard | plain root, no accidental, no parens |
| 2 | `Am7` | standard | quality + extension |
| 3 | `F#m7b5/A` | standard | sharp + flat + slash chord |
| 4 | `bIII` | roman | leading accidental for Roman numeral |

Add a fifth bar (or augment bar 2) carrying `<leftParen/>` and
`<rightParen/>` so parenthesis decode is covered.

License: hand-written, MIT. Append a one-line note to
`Tests/SheetMusicTests/Resources/LICENSE` distinguishing
self-authored `harmony-*.mscx` (MIT) from the upstream MuseScore
fixtures (GPL-3.0).

### Unit suites

`Tests/SheetMusicTests/HarmonyTests.swift`:

- **`Harmony decode`**
  - `standardChord_nameAndType` — `name == "C"`, `harmonyType == .standard`
  - `slashChord_rootAndBassTpcDecoded` — both TPCs present
  - `romanNumeral_typeIsRoman`
  - `parentheses_decoded`
  - `tpcInvalid_normalizedToNil` — `<root>-1</root>` → `rootTpc == nil`
- **`Harmony SMuFL substitution`**
  - `sharpAfterLetter_substituted` — `"F#"` → `[text "F", glyph ♯]`
  - `flatAfterLetter_substituted`
  - `doubleFlat_substituted`
  - `slashChord_multipleAccidentalsSubstituted` — `"F#m7b5/Ab"`
  - `romanLeadingFlat_substituted` — `"bIII"` (Roman) →
    `[glyph ♭, text "III"]`
  - `standardLeadingFlat_notSubstituted` — `"bVII"` (Standard) →
    `[text "bVII"]`
- **`Harmony layout`**
  - `placedAboveStaff` — Y is negative (above staff top)
  - `multipleHarmoniesAtSameTick_stackVertically`
  - `systemTopExtent_includesHarmonyHeight`

### Visual verification

A `#Preview` block in `Sources/RenderPreviews/HarmonyPreview.swift`
loads `harmony-basic.mscx` into `ScoreView`. Iterate via
`mcp__xcode__RenderPreview` (Xcode must be running with the package
open).

Final smoke check: add `harmony-basic.mscx` to the
`SheetMusicExampleMac` sample list. Tracked as a follow-up step in
the implementation plan, not a deliverable of this spec.

## Recurring pitfalls / non-obvious calls

- **Leading accidentals are type-sensitive.** Standard chord names
  starting with `b`/`#` (rare, almost always typo) are left alone;
  Roman/Nashville names commonly start with one and need the
  substitution. Tests cover both.
- **TPC -1 is "invalid", not "C-flat-flat".** Normalise to `nil` at
  decode time so consumers don't accidentally arithmetic on -1.
- **`harmonyType` defaults to `.standard` even when `<harmonyType>`
  is missing.** That matches MuseScore's `Harmony` constructor
  default. The decoder must not throw if the tag is absent.
- **`<base>` (not `<bass>`) is the slash-bass tag.** MuseScore's XML
  uses the historical spelling; don't typo-fix.
- **Run-list pre-computation lives in the layout module, not the UI
  module.** Wrap / page-break decisions need the width before
  drawing, and font measurement is a layout-time concern; the
  renderer just consumes the precomputed runs.

## Out of scope (deliberate)

- MIDI playback of chord symbols (the C scope from brainstorming).
- Transposition (TPC fields are stored but not used).
- Polychord divider lines and ChordList sub/superscript rendering.
- `<degree>` / `<extension>` decoding.
- Edit / selection / hit-test on harmony elements.
- MusicXML harmony import (separate spec — `<harmony>` lives at
  measure level, not voice level).
- Writing `.mscx` (the project does not implement MSCX export).
