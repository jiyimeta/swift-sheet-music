# 4.35.0: a revealed staff through ScorePageOptions, and the sticky header as ScorePages

Date: 2026-11-11
Status: proposed for review (folino's Windows controller); not released.
Consumers: folino's Windows reader (both), folino's Android reader (the revealed staff, through the same wire).
folino specs: `2026-11-11-windows-hide-empty-staves-caret-design.md` §4, `2026-11-11-windows-horizontal-sticky-pane-design.md` §4.

## 1. `ScorePageOptions.revealedStaff`, carried in `LayoutOptionsWire`

**Why.** `ScoreViewOptions.revealedStaff` (the system holding a host's editing caret draws every staff when "hide empty
staves" would leave the caret's staff out) reaches only a host that builds `ScoreViewOptions` itself — the Apple
`ScoreView`. A portable host lays out through `ScorePages.compute(…, options: ScorePageOptions)` (Windows) or the
Android bridge (`nativeComputeLayout`), and both hand the options over as `LayoutOptionsWire`, which has no such field:
`LayoutBridge.scoreViewOptions(from:wrap:title:)` never sets it. So neither can keep its caret's system whole.

**API.**

- `SheetMusicLayout`: unchanged (`ScoreViewOptions.RevealedStaff` exists).
- `SheetMusicPages`: `public var revealedStaff: ScoreViewOptions.RevealedStaff?` on `ScorePageOptions`, a new trailing
  `init` parameter defaulting to `nil`; `wire()` carries it.
- `SheetMusicBridgeCore`:
  - a new `@WireFormat public struct RevealedStaffWire { partIndex: Int32; staffIndexInPart: Int32; measureIndex: Int32 }`
    (self-contained in `LayoutOptionsWire.swift`, as the Kotlin codegen needs);
  - `public var revealedStaff: RevealedStaffWire?` appended to `LayoutOptionsWire` after `writtenPitch`, defaulting to
    `nil` in the stored property and the `init` — the next implicit tag, nothing reserved or reordered;
  - `LayoutOptionsWire.revealedStaffValue: ScoreViewOptions.RevealedStaff?` (negative indices read as `nil`), and
    `scoreViewOptions(from:wrap:title:)` assigns it to `options.revealedStaff`.

**Compatibility.** Appended optional field with a `nil` default, the shape `spacing: EngravingSpacingWire?` already
has: an old blob decodes with `revealedStaff == nil` and lays out byte for byte as before; the generated Kotlin
`data class LayoutOptionsWire` gains `revealedStaff: RevealedStaffWire? = null`, so every Kotlin host compiles
unchanged; an old reader skips the unknown tag. No handwritten Kotlin model names `LayoutOptionsWire`'s fields (checked:
`writtenPitch`, the last field added, touched none). The layout cache keys on the score handle, not the options, so a
moving caret recomputes, as any options change does.

**Tests.** `LayoutOptionsWireTests`: the field round-trips; a blob encoded without it decodes to `nil`; a negative
index reads as `nil`. `ScorePageOptionsTests`: `wire()` carries it. A bridge test over the two-part fixture with a
staff hidden in its middle system: without the field the system hides the staff, with it (the caret on that staff in
that system) the system draws every staff, and a caret elsewhere opens nothing — the same three cases as the Apple
`ScoreViewOptions.revealedStaff` test, through `LayoutBridge.computePages` and `ScorePages.compute`.

## 2. `ScorePages.stickyHeader(scrollXPt:)`

**Why.** A horizontal host freezes the current clef, key, time signature and part labels at the viewport's leading
edge (MuseScore's continuous-view panel). The synthesis is portable (`LayoutEngine.stickyHeaderSystem`,
`LayoutEngine.measureContexts`, `LayoutDocument.stickyTrailingX`), and Android already gets it as a draw program
(`LayoutBridge.stickyHeaderPage(score:document:scrollXPt:)` → `EncodablePage`). A Windows host cannot: `ScoreSurface`
draws only a `ScorePages`, which is made only by `compute(score:…)`, and its pages are package-internal.

**API.**

- `SheetMusicPages`: `public func stickyHeader(scrollXPt: Double) -> ScorePages?` on `ScorePages`. The one-page
  `ScorePages` of the sticky header for the measure under `scrollXPt` (document points — a host passes the pane's
  trailing edge, `stickyTrailingX`, as the Apple container does), built by `LayoutBridge.stickyHeaderPage` from this
  value's `filteredScore` and `document` (the addressing the document was laid out in). Its `document` is the
  one-system document the pane was drawn from (its `size` is the pane's), its `placement` that document's single page
  at the origin, its options this value's with mode `.horizontal`. `nil` when there are no systems or no measures; a
  scroll past the last measure clamps to the last (the bridge's rule).
- Colors: the pane is drawn as the score is (black on white). MuseScore and the Apple `StickyHeaderView` show it at
  50 % (`invisibleColor()`, #808080 over white); a host lays a 50 % white over its pane, which is the same color
  exactly, so no color parameter is added.

**Compatibility.** Additive (a new method); no wire, no Kotlin, no draw-program change.

**Tests.** `ScorePagesTests` (or a new `ScorePagesStickyHeaderTests`): over a two-part score with a key change, the
header for a measure before and after the change carries that measure's key (its page differs, its document's single
system has the part labels and one clef per staff), its size equals `stickyHeaderSystem`'s, it is `nil` for an empty
document, and a scroll past the end gives the last measure's header.

## 3. Release

One minor, 4.35.0 (both additive in the API; §1 changes the wire by an appended field). Gates per the release rules:
host suite (with `SM_LAYOUT_GOLDEN=1` — no layout coordinates should move), the wasm `js test` locally (portable targets
change), and the Android audio module workflow on the branch (`gh workflow run android-audio.yml --ref <branch>`) for
the regenerated Kotlin codec, before main and the tag. The Windows `ssm` checkout builds `SheetMusicPages` with the
Windows shape (folino's folino-qa run of the consumer).
