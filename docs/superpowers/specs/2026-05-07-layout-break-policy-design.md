# Layout Break Policy — Design

Date: 2026-05-07

## Summary

Add a display-time option that lets callers ignore the explicit
`<LayoutBreak>line` and `<LayoutBreak>page` markup carried by a
`Measure`. Today these flags unconditionally force a system / page
break in both UI views (`ScoreView`, `PagedScoreView`) and PDF
export. The new option is a tri-state enum on `ScoreViewOptions` so
the same setting flows through layout, pagination, and the visual
indicator overlay.

## Motivation

A score authored in MuseScore frequently embeds explicit line / page
breaks tuned for the original page size and instrumentation. When
the same score is displayed in `swift-sheet-music` at a different
viewport width — or aggregated into a continuous-flow reader — those
authored breaks fight the available width:

- A 4-bar-per-system layout authored for letter paper looks cramped
  on a wider iPad-landscape view because the engine is forced to
  honor breaks that the user can no longer override.
- Continuous (non-paginated) reading modes don't want page breaks at
  all, but `PagedScoreView` currently closes a page on every
  `<LayoutBreak>page`.

The score model already exposes `Measure.lineBreak` /
`Measure.pageBreak`. We just need to gate the consumers (layout
wrapping, page assembly, indicator overlay) on a policy.

## Non-goals

- Editing or stripping the underlying `<LayoutBreak>` elements from
  the score model. The flags remain on `Measure` regardless of
  policy; the policy only controls how they're consumed.
- Adding new break kinds (e.g. section break) — out of scope, the
  current set is line / page only.
- Per-measure or per-staff policy overrides. Policy is document-wide.
- Auto-inferring breaks from text labels / rehearsal marks.
- Changing how the MSCX parser reads `<LayoutBreak>` — read path is
  unchanged.

## Design

### `LayoutBreakPolicy`

New public enum, sibling of `ScoreViewOptions` in
`Sources/SheetMusicLayout/Options/ScoreViewOptions.swift`:

```swift
public enum LayoutBreakPolicy: Sendable, Equatable {
    /// Default — `<LayoutBreak>line` and `<LayoutBreak>page` both
    /// force a new system; `<LayoutBreak>page` additionally closes
    /// the current page. Equivalent to behavior prior to this change.
    case honor

    /// Ignore `<LayoutBreak>line`. `<LayoutBreak>page` still forces
    /// both a system break and a page close (a page break implies a
    /// system break in MuseScore's model — see
    /// `engraving/rendering/score/systemlayout.cpp:262`).
    case ignoreSystemBreaks

    /// Ignore both `<LayoutBreak>line` and `<LayoutBreak>page`. The
    /// engine wraps purely on available width; the paginator only
    /// closes pages on vertical overflow.
    case ignoreAll
}
```

Semantic table:

| policy | `<LayoutBreak>line` → system break | `<LayoutBreak>page` → system break | `<LayoutBreak>page` → page close |
| --- | --- | --- | --- |
| `.honor` | yes | yes | yes |
| `.ignoreSystemBreaks` | no | yes | yes |
| `.ignoreAll` | no | no | no |

### `ScoreViewOptions`

Add one field:

```swift
public var breakPolicy: LayoutBreakPolicy

public init(
    staffSize: CGFloat = 28,
    systemGap: CGFloat = 40,
    wrapToViewWidth: Bool = true,
    includeTitleFrame: Bool = true,
    breakPolicy: LayoutBreakPolicy = .honor
) { … }
```

Default `.honor` keeps every existing call site behavior-compatible.
The struct stays `Sendable & Equatable` (enum cases satisfy both).

### Layout phase

`Sources/SheetMusicLayout/Layout/LayoutEngine+Wrapping.swift::measureForcesLineBreak`
becomes policy-aware:

```swift
static func measureForcesLineBreak(
    at idx: Int, staves: [Staff], policy: LayoutBreakPolicy
) -> Bool {
    guard let s0 = staves.first, idx < s0.measures.count else { return false }
    let m = s0.measures[idx]
    switch policy {
    case .honor:              return m.lineBreak || m.pageBreak
    case .ignoreSystemBreaks: return m.pageBreak
    case .ignoreAll:          return false
    }
}
```

Call sites updated to pass the policy from `context.options.breakPolicy`:

- `LayoutEngine+Wrapping.swift:101` — inside `balancedMeasuresPerSystem`
  (which itself gains a `policy:` parameter and forwards it).
- `LayoutEngine+Packing.swift:228` — inside the system packer loop.

`balancedMeasuresPerSystem` callers (in `LayoutEngine+Packing.swift`)
also forward `context.options.breakPolicy`.

### Pagination phase

Both `paginate` implementations gain a `policy: LayoutBreakPolicy`
parameter and gate the page-close branch:

`Sources/SheetMusicUI/PagedScoreView.swift:118-149`
`Sources/SheetMusicPDF/PDFExporter.swift:200-…`

```swift
if policy != .ignoreAll, system.measures.last?.pageBreak == true {
    pages.append(current); current = []; usedHeight = 0
}
```

(`.ignoreSystemBreaks` still closes the page because, by the
semantic table above, page breaks are still honored under that case.)

Call sites:

- `PagedScoreView.swift:56` — pass `options.breakPolicy`.
- `PDFExporter.swift:105` — pass `options.breakPolicy`.

### Break indicator overlay

`BreakIndicatorOverlay` exists to visualize what the layout is
honoring. When the policy ignores a break kind, showing its
indicator is misleading. The overlay is therefore policy-aware:

- `.honor` — show all line + page indicators (current behavior).
- `.ignoreSystemBreaks` — show page indicators only.
- `.ignoreAll` — overlay shows nothing (the view returns
  `EmptyView`-equivalent / iterates zero indicators).

Add a `policy: LayoutBreakPolicy` initializer parameter on
`BreakIndicatorOverlay` (`Sources/SheetMusicUI/Rendering/BreakIndicatorOverlay.swift:21`)
with default `.honor`, and update the four call sites:

- `Sources/SheetMusicUI/PagedScoreView.swift:98`
- `Sources/SheetMusicUI/ScoreView.swift:148`
- `Sources/SheetMusicUI/ScoreView.swift:198`
- `Sources/SheetMusicPDF/PDFPageView.swift:101`

each forwards `options.breakPolicy`.

### Out of scope (model side)

`Measure.lineBreak` / `Measure.pageBreak` remain on the model
unchanged. The MSCX read path (`MSCXDecoder+Measure.swift`) is
unchanged. PDF import (`PDFImporter+Assemble.swift`) likewise stays
the same — it writes `lineBreak` / `pageBreak` flags into the
imported `Measure`s and the new policy controls only how those
flags are consumed.

## Tests

Swift Testing, in the existing `SheetMusicTests` target.

1. **Layout — `.ignoreAll` drops authored line breaks.**
   Use a fixture (or synthesize a `Score`) with one explicit
   `<LayoutBreak>line` mid-score. Lay out at a width wide enough to
   fit all measures on one system. With `.honor`, expect ≥ 2
   systems; with `.ignoreAll`, expect exactly 1 system.

2. **Layout — `.ignoreSystemBreaks` keeps page-implied system
   breaks.** Same fixture but the break is a `<LayoutBreak>page`.
   Under `.ignoreSystemBreaks`, expect the system break to still
   occur.

3. **Pagination — `.ignoreAll` ignores page breaks.**
   Unit test on `PagedScoreView.paginate` with a hand-built array of
   `LayoutSystem`s where one carries a `pageBreak`. With `.honor`
   the resulting page count is ≥ 2; with `.ignoreAll` it's 1
   (assuming heights fit).

4. **Default behavior unchanged.**
   The existing `MidiExportTests` and any layout snapshot tests
   stay green without modification — `breakPolicy` defaults to
   `.honor`.

No new test fixtures are required; cases 1–3 can use the smallest
existing `.mscx` test resource plus a synthesized variant.

## Migration

- `ScoreViewOptions` gains a defaulted parameter — source-compatible
  for all existing initializers.
- `measureForcesLineBreak`, `balancedMeasuresPerSystem`, and both
  `paginate` functions gain a required `policy:` argument. These are
  internal / SPI-level (no public consumers outside this package
  besides `paginate`, which is `public static` on `PDFExporter` and
  `PagedScoreView`). The `paginate` overloads gain a defaulted
  `policy: LayoutBreakPolicy = .honor` so external callers stay
  source-compatible.
- `BreakIndicatorOverlay`'s new `policy:` parameter defaults to
  `.honor`.

## Risks

- The `.ignoreSystemBreaks` case has a subtle invariant: page
  breaks still imply system breaks. The doc comment on the enum
  case and the semantic table in this spec are the canonical
  reference; the `measureForcesLineBreak` switch encodes it.
- `BreakIndicatorOverlay` callers in PDF export may render
  differently when the policy is non-default, which is intended but
  worth verifying via a manual PDF render of a scored fixture under
  each policy.
