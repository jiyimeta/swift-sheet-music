# PDF page layout: reproduce MuseScore page size, margins, spatium, headers/footers

Date: 2026-04-27

## Goal

When `PDFExporter` writes a `Score` to PDF, reproduce the page-level
chrome that MuseScore would have used:

1. Page geometry — page size, per-side margins (with two-sided
   alternation).
2. Staff scaling — spatium-driven staff size.
3. Headers, footers, and page numbers — six text slots per spread
   (header L/C/R + footer L/C/R, with separate odd/even sides),
   on/off and first-page toggles, font size + alignment, and the
   meta-tag macro substitution language MuseScore embeds in those
   strings (`$P` page number, `$T` work title, `$:tag:` arbitrary
   metaTag, etc.).

All values come from the `<Style>` block of the source `.mscx`;
missing values fall back to MuseScore's documented defaults.

The goal is: "open the same `.mscx` in MuseScore and in this PDF
exporter, get the same paper, same margins, same staff size at 1×,
and the same page-number / copyright / header chrome."

## Non-goals

- `<systemBreak>` / `<pageBreak>` honoring inside measures
- The on-screen viewer modes (vertical / horizontal / paged) consuming
  `score.style`. They keep their current explicit `staffSize` knob.
  Reason: MuseScore's default spatium of 1.75 mm is ~5 pt at 72 DPI —
  too small for a comfortable on-screen 1× preview. Pulling it through
  to the viewer would make screens tiny without solving anything the
  user has asked for.
- Style values other than the eleven page / spatium tags listed below.
  All other `<Style>` children continue to be silently ignored, in line
  with the existing permissive-parser convention.
- A user-facing scale / zoom override on `PDFExporter`. MuseScore does
  not have one; the file is the file. Preview-time pinch zoom is
  already handled by the example app via `pdfScale`.

## Background — what MuseScore stores

Confirmed against the `MuseScore/` submodule (read460 reader) and
against the `testArpeggio.mscx` fixture:

| XML tag                          | Type | Unit | Default              |
|----------------------------------|------|------|----------------------|
| `pageWidth`                      | real | inches | 210 / 25.4 ≈ 8.2677 (A4) |
| `pageHeight`                     | real | inches | 297 / 25.4 ≈ 11.6929 |
| `pagePrintableWidth`             | real | inches | 180 / 25.4 ≈ 7.0866 |
| `pageOddLeftMargin`              | real | inches | 15 / 25.4 ≈ 0.5906 |
| `pageOddTopMargin`               | real | inches | 15 / 25.4 |
| `pageOddBottomMargin`            | real | inches | 15 / 25.4 |
| `pageEvenLeftMargin`             | real | inches | 15 / 25.4 |
| `pageEvenTopMargin`              | real | inches | 15 / 25.4 |
| `pageEvenBottomMargin`           | real | inches | 15 / 25.4 |
| `pageTwosided`                   | bool | —    | true |
| `Spatium` (or `spatium`)         | real | mm   | 1.75 |

References:
- `MuseScore/src/engraving/style/styledef.cpp:41-50, 775` — defaults
- `MuseScore/src/engraving/style/style.cpp:120-156, 385-386` — read path
  (note the special-case for `Spatium` / `spatium` that multiplies by
  `DPMM`; we keep the value in mm and convert at output time instead)
- `MuseScore/src/engraving/dom/page.cpp:177-209` — margin accessors,
  including the `rm()` derivation
  `rm = (pageWidth - pagePrintableWidth) - lm`

The right margin is **not stored** — it is always derived from
`pageWidth - pagePrintableWidth - leftMargin`.

Two-sided rule (`Page::tm/bm/lm`):
- `pageTwosided = true`: odd pages use `pageOdd*Margin`,
  even pages use `pageEven*Margin`. Page numbering is 1-based;
  page 1 is odd.
- `pageTwosided = false`: every page uses `pageOdd*Margin`,
  the even values are unused.

## Design

### Layer 1 — `SheetMusicCore` data model

Add a `ScoreStyle` value type. Storage units mirror MuseScore's native
units so callers see the same numbers MuseScore writes — there are no
surprise conversions on round-trip and the comparison with MuseScore
test fixtures is direct.

```swift
/// Subset of MuseScore's `<Style>` block that affects engraving
/// dimensions. Currently covers page geometry and spatium; future
/// work may extend this to text-style defaults, etc.
public struct ScoreStyle: Sendable, Equatable {
    /// Staff space in **millimetres**. C++: `Sid::spatium`.
    /// MuseScore default 1.75 mm.
    public var spatium: Double
    public var pageLayout: PageLayout

    public static let museScoreDefaults = ScoreStyle(
        spatium: 1.75,
        pageLayout: .museScoreA4)
}

/// Paper size and per-edge margins, in MuseScore's native units.
/// All linear values are **inches**. Booleans / counts are unitless.
public struct PageLayout: Sendable, Equatable {
    public var width: Double            // C++: Sid::pageWidth
    public var height: Double           // C++: Sid::pageHeight
    public var printableWidth: Double   // C++: Sid::pagePrintableWidth
    public var oddTopMargin: Double
    public var oddBottomMargin: Double
    public var oddLeftMargin: Double
    public var evenTopMargin: Double
    public var evenBottomMargin: Double
    public var evenLeftMargin: Double
    public var twosided: Bool

    /// Derived per `Page::rm` — right margin is not stored.
    public var oddRightMargin: Double {
        width - printableWidth - oddLeftMargin
    }
    public var evenRightMargin: Double {
        width - printableWidth - evenLeftMargin
    }

    public static let museScoreA4 = PageLayout(
        width: 210.0 / 25.4,
        height: 297.0 / 25.4,
        printableWidth: 180.0 / 25.4,
        oddTopMargin: 15.0 / 25.4,
        oddBottomMargin: 15.0 / 25.4,
        oddLeftMargin: 15.0 / 25.4,
        evenTopMargin: 15.0 / 25.4,
        evenBottomMargin: 15.0 / 25.4,
        evenLeftMargin: 15.0 / 25.4,
        twosided: true)
}

/// Page-level chrome — headers, footers, and the standalone page
/// number renderer that pre-4.4 MuseScore conflated with the header.
/// All linear values are **points** at the score's spatium; the
/// pageNumber font size is in points (it is `…FontSpatiumDependent
/// = false` in styledef.cpp:1589).
public struct PageChrome: Sendable, Equatable {
    public var header: HeaderFooter
    public var footer: HeaderFooter
    public var pageNumber: PageNumberStyle

    public static let museScoreDefaults = PageChrome(
        header: .museScoreDefaultHeader,
        footer: .museScoreDefaultFooter,
        pageNumber: .museScoreDefaultPageNumber)
}

public struct HeaderFooter: Sendable, Equatable {
    public var enabled: Bool             // showHeader / showFooter
    public var showOnFirstPage: Bool     // headerFirstPage / footerFirstPage
    public var oddEvenDifferent: Bool    // headerOddEven / footerOddEven
    public var even: TextRow             // ignored when oddEvenDifferent == false
    public var odd: TextRow
    public var fontFace: String          // "Edwin" — see Risks for fallback
    public var fontSize: Double          // points (default 9)
    public var fontStyle: FontStyleSet   // bold / italic / underline mask

    public static let museScoreDefaultHeader = HeaderFooter(
        enabled: true,
        showOnFirstPage: false,
        oddEvenDifferent: true,
        even: TextRow(left: "$p", center: "", right: ""),
        odd:  TextRow(left: "",   center: "", right: "$p"),
        fontFace: "Edwin",
        fontSize: 9,
        fontStyle: [])
    public static let museScoreDefaultFooter = HeaderFooter(
        enabled: true,
        showOnFirstPage: true,
        oddEvenDifferent: true,
        even: TextRow(left: "", center: "$C", right: ""),
        odd:  TextRow(left: "", center: "$C", right: ""),
        fontFace: "Edwin",
        fontSize: 9,
        fontStyle: [])
}

public struct TextRow: Sendable, Equatable {
    public var left: String
    public var center: String
    public var right: String
}

public struct PageNumberStyle: Sendable, Equatable {
    public var enabled: Bool             // showPageNumber
    public var showOnFirstPage: Bool     // showPageNumberOne
    public var oddEvenDifferent: Bool    // pageNumberOddEven (cosmetic only —
                                         // currently controls H/F slot
                                         // selection; kept for completeness)
    public var fontFace: String
    public var fontSize: Double          // points (default 11)

    public static let museScoreDefaultPageNumber = PageNumberStyle(
        enabled: true,
        showOnFirstPage: false,
        oddEvenDifferent: true,
        fontFace: "Edwin",
        fontSize: 11)
}

public struct FontStyleSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold      = FontStyleSet(rawValue: 1 << 0)
    public static let italic    = FontStyleSet(rawValue: 1 << 1)
    public static let underline = FontStyleSet(rawValue: 1 << 2)
    // Mirrors MuseScore's FontStyle bitmask (mscore.h).
}
```

`Score` gains:

```swift
public var style: ScoreStyle
```

with default `.museScoreDefaults` so existing call sites and tests that
construct `Score(...)` directly continue to compile and behave
identically. `ScoreStyle.museScoreDefaults` includes
`pageChrome: PageChrome.museScoreDefaults`.

### Layer 2 — `SheetMusicMSCX` parser

New file `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Style.swift`.

Walk `<Score><Style>` once, gathering the recognised tags. Anything
unrecognised (`<lastSystemFillLimit>`, text-style overrides for
non-page items, etc.) is silently ignored — same convention as the
existing voice parser.

Recognised tags fall into three groups:

1. **Page geometry / spatium** — the eleven tags listed in
   "Background — what MuseScore stores".
2. **Header / footer text + on-off / first-page** — `showHeader`,
   `showFooter`, `headerFirstPage`, `footerFirstPage`,
   `headerOddEven`, `footerOddEven`, `evenHeaderL/C/R`,
   `oddHeaderL/C/R`, `evenFooterL/C/R`, `oddFooterL/C/R`.
3. **Header / footer font + page-number style** —
   `headerFontFace`, `headerFontSize`, `headerFontStyle`,
   `footerFontFace`, `footerFontSize`, `footerFontStyle`,
   `showPageNumber`, `showPageNumberOne`, `pageNumberOddEven`,
   `pageNumberFontFace`, `pageNumberFontSize`.

Both `<Spatium>` (capital — what MuseScore writes today) and
`<spatium>` (lowercase — present in some older files; documented in
`style.cpp:386`) are accepted.

Update `MSCXDecoder+Score.swift` to call this decoder when `<Style>` is
present and assign the result to `Score.style`. When `<Style>` is
absent or empty, `Score.style` defaults to `.museScoreDefaults`.

### Layer 3 — `SheetMusicPDF` exporter

`PDFExporter.Options` is restructured. The current API has a single
`pageSize: CGSize`, a scalar `margin: CGFloat`, and `staffSize: CGFloat`
all defaulting to letter / 36 / 14 — which silently overrides whatever
the score declared. The new API makes "use what the score says" the
default and keeps explicit overrides as opt-in.

```swift
public struct Options: Sendable {
    public enum PageGeometry: Sendable {
        /// Use `score.style.pageLayout`. Default.
        case fromScore
        /// Override with explicit values, in **points**.
        case explicit(EngravingPage)
    }
    public enum StaffSize: Sendable {
        /// Use `4 × score.style.spatium`, converted mm → points.
        /// Default.
        case fromScore
        /// Override with explicit spatium in points.
        /// (One staff space = N points.)
        case explicit(CGFloat)
    }

    public var page: PageGeometry
    public var staffSize: StaffSize
    public var systemGap: CGFloat
    public var title: String?
    public var author: String?

    public init(
        page: PageGeometry = .fromScore,
        staffSize: StaffSize = .fromScore,
        systemGap: CGFloat = 16,
        title: String? = nil,
        author: String? = nil
    ) { ... }
}

/// Page geometry expressed in **points** (Core Graphics units) —
/// already converted from MuseScore's mixed inch/mm storage.
public struct EngravingPage: Sendable {
    public var size: CGSize
    public var oddMargins: NSDirectionalEdgeInsets
    public var evenMargins: NSDirectionalEdgeInsets
    public var twosided: Bool

    /// 8.5" × 11", uniform 36pt margins, twosided=false. Useful for
    /// callers that want a quick override without thinking in
    /// MuseScore units.
    public static let usLetter = EngravingPage(
        size: CGSize(width: 612, height: 792),
        oddMargins: NSDirectionalEdgeInsets(
            top: 36, leading: 36, bottom: 36, trailing: 36),
        evenMargins: NSDirectionalEdgeInsets(
            top: 36, leading: 36, bottom: 36, trailing: 36),
        twosided: false)
    /// MuseScore's default A4 with 15mm margins, twosided=true.
    /// Equivalent to resolving `PageLayout.museScoreA4`.
    public static let a4 = EngravingPage.from(.museScoreA4)
}
```

Conversion helpers (private to `SheetMusicPDF`):

- inches → points: `× 72`
- mm → points: `× 72 / 25.4`
- staff size in points = `4 × spatium_mm × 72 / 25.4`
  (≈ 19.84 pt at MuseScore's default 1.75 mm)

### Layer 4 — pagination

`PDFExporter.paginate` currently takes `(systems, pageSize, margin)` and
treats the page as having a single uniform margin on all sides. It is
replaced by a version that takes the resolved `EngravingPage`. The
function tracks page index internally (1-based, page 1 is odd) and
selects the active margin set per page:

- `twosided = true`: page N uses `oddMargins` if N is odd, else
  `evenMargins`.
- `twosided = false`: every page uses `oddMargins`. (`evenMargins`
  is ignored when resolving from a `PageLayout` whose
  `pageTwosided` is false; the `EngravingPage` initializer can copy
  odd into even in that case to make the struct safe to inspect.)

The "fits on this page" check consults the active margin set, so the
usable height can differ between odd and even pages.

`PDFPageView` is updated from `(margin: CGFloat)` to a per-edge inset
(`leadingMargin`, `topMargin` are what it actually needs to know to
position the system block — trailing/bottom only constrain pagination,
not drawing). Page-index awareness is pushed to the caller (the
exporter / the example app's preview), which already knows whether
each page is odd or even.

The existing public `paginate(systems:pageSize:margin:)` overload is
retained as a thin shim that constructs a uniform `EngravingPage` and
calls the new core. The example app's `pdfPreviewContent` keeps
working without immediate rewrites.

### Layer 5 — example app (iOS + macOS)

Both `Example/SheetMusicExample/ContentView.swift::pdfPreview` (iOS)
and `Example/SheetMusicExample/macOS/ContentViewMac.swift::pdfPreview`
(macOS) currently hardcode:

```swift
let pageSize = PDFExporter.Options.usLetter
let margin: CGFloat = 36
let pdfStaffSize: CGFloat = 14
```

These three lines go away in both files. The preview asks
`PDFExporter` to resolve the score's defaults and uses the resolved
values to drive both the on-screen layout and the per-page rectangles,
so the preview is a truthful proxy for the file the share button
produces.

The macOS share path at `ContentViewMac.swift:247` (`PDFExporter.export
(score:, options: PDFExporter.Options(...))`) is updated to the new
`Options` initializer signature; default values match what the preview
shows.

Existing on-screen modes (vertical / horizontal / paged) are
unchanged — they keep their `@State staffSize: CGFloat = 14` because
that's a display-only knob.

### Layer 6 — header / footer / page-number rendering

A new `PageChromeRenderer` (in `SheetMusicPDF`) draws header, footer,
and page-number text into the margin area of each PDF page.

**Where the chrome lives.** Headers sit inside the top margin,
footers inside the bottom margin. Specifically:

- Header baseline = page top + `headerOffset` (currently elided —
  see Risks). The first pass just centres the row vertically inside
  the top margin region: `y_baseline = topMargin / 2 + ascent / 2`.
- Footer baseline = page bottom − `bottomMargin / 2 + descent / 2`.
- Horizontal positions: `left` aligned to `leadingMargin`, `right`
  aligned to `pageWidth - trailingMargin`, `center` aligned to the
  midpoint of `[leadingMargin, pageWidth - trailingMargin]`.

Position selection per page:

- If `header.enabled == false`: skip header entirely.
- If page is page 1 and `header.showOnFirstPage == false`: skip.
- Else select the row: `header.oddEvenDifferent ? (isOdd ? odd
  : even) : odd`. (`oddEvenDifferent == false` means use the odd
  fields uniformly; matches MuseScore's UI which greys out the
  even fields in that mode.)
- Symmetric rules for footer (`footer.showOnFirstPage` defaults to
  `true`, so the footer's `$C` copyright shows on page 1 by
  default).

Page numbers are not drawn separately — they are emitted via the
`$P` / `$p` / `$N` macros inside header/footer text. The
`PageNumberStyle` block tells us what font to use **for the
page-number macros specifically**, mirroring MuseScore's pre-/post-4.4
convention where page numbers had their own font separable from the
surrounding header text. We honor this only at the granularity "if the
expanded fragment is purely a page-number macro, use
`pageNumberFontSize` / `pageNumberFontFace`; otherwise use the
header/footer font". Inline mixed formatting (text + page number in
the same row) is out of scope; the surrounding font is used.

**Macro substitution.** New file
`Sources/SheetMusicPDF/PageChromeMacroExpander.swift` ports the
`replaceTextMacros` switch from
`engraving/rendering/score/headerfooterlayout.cpp:246-407`. Implemented
macros (in priority order — the first batch is needed for the typical
score, the rest are easy add-ons):

| Macro | Meaning | Notes |
|-------|---------|-------|
| `$P`  | Page number, all pages | always |
| `$p`  | Page number, skip page 1 | |
| `$N`  | Page number, only when total > 1 | |
| `$n`  | Total pages | |
| `$T`  | `metaTag("workTitle")` | (not in MuseScore — see Risks) |
| `$C`  | Copyright (first page only) | falls back to `metaTag("copyright")` |
| `$c`  | Copyright (all pages) | |
| `$:tag:` | Arbitrary metaTag lookup | greedy until next `:` |
| `$$`  | Literal `$` | |

Deferred (these resolve to empty string for now and can be added
later without API changes): `$i $I $f $F $d $D $m $M $v $r`. The
deferred macros either need filesystem / build metadata that isn't
useful in our exporter context (file mtime, MuseScore version) or
need part-name plumbing that doesn't exist yet.

> **Aside on `$T`.** MuseScore itself does not have a `$T` macro —
> users write `$:workTitle:` instead. We list `$T` as a convenience
> alias because the title is by far the most-asked-for substitution
> and shaving the verbosity is friendly. It's a deliberate
> divergence; documented in `PageChromeMacroExpander`.

**Font handling.** MuseScore's default font is `Edwin` (bundled with
the app). We do not bundle Edwin. The renderer asks Core Text for
the requested face name and, if not found, falls back to a system
serif (`NSFont.preferredFont(forTextStyle: .body)` on macOS, the
equivalent on iOS). The risk this introduces (small ascent / descent
drift versus MuseScore's pixel output) is documented in Risks; this
is acceptable for a first pass.

**Drawing pipeline.** `PageChromeRenderer` is invoked from
`PDFExporter.export` after the systems are drawn for a given page:

```swift
PageChromeRenderer.draw(
    chrome: resolvedChrome,
    pageIndex: idx,                 // 0-based
    pageCount: pages.count,
    page: resolvedEngravingPage,
    metaTags: score.metaTags,
    into: pdfContext)
```

The renderer uses `CTLine` (`CTLineCreateWithAttributedString` →
`CTLineDraw`) for measurement + drawing. This avoids dragging
SwiftUI's `Text` into a non-SwiftUI context and keeps the chrome
purely Core Graphics.

The on-screen `PDFPageView` (SwiftUI) gets a parallel
`PageChromeView` overlay so the example app's preview matches the
exported file. Both renderers share `PageChromeMacroExpander` and
the position math via a small `ResolvedChromeRow` value type
(`text`, `align`, `font`, `baselineY`).

## Tests

New file: `Tests/SheetMusicTests/MSCXStyleTests.swift`.

1. `parsesAllPageGeometryTags` — load `testArpeggio.mscx`, assert each
   field of `score.style.pageLayout` and `score.style.spatium` equals
   the literal value in the XML (within 1e-6).
2. `defaultsWhenStyleAbsent` — synthesize a minimal `.mscx` with no
   `<Style>` block; assert `score.style == .museScoreDefaults`.
3. `defaultsWhenStyleHasOnlySpatium` — use the existing repo-root
   `test.mscx` shape (only `<spatium>1.75</spatium>`); assert spatium
   equals 1.75 and page layout equals `.museScoreA4`.
4. `acceptsLowercaseSpatium` — round-trip a fixture using
   `<spatium>` instead of `<Spatium>`; assert the value is read.
5. `parsesHeaderFooterText` — synthetic fixture exercising all six
   text slots (`evenHeaderL`, `oddHeaderL`, etc.) plus the on/off and
   first-page toggles; assert each lands in the right
   `HeaderFooter.even/odd` field.
6. `parsesPageNumberStyle` — fixture overriding
   `showPageNumberOne` and `pageNumberFontSize`; assert override.

New file: `Tests/SheetMusicTests/PDFExporterPageLayoutTests.swift`.

7. `mediaBoxMatchesScorePageSize` — export `testArpeggio.mscx` with
   default options; reparse the resulting PDF; assert the page 1
   MediaBox equals (8.26771 × 72, 11.6929 × 72) within 0.01pt.
8. `oddPageUsesOddMargins` — same fixture; assert the leading edge of
   the first system on page 1 equals
   `pageLayout.oddLeftMargin × 72`.
9. `evenPageMirrorsWhenTwosided` — pick a fixture that produces ≥ 2
   pages at MuseScore-default spatium (`testArpeggio.mscx` is the
   first candidate to check at implementation time; if it fits on one
   page, fall back to constructing a synthetic `Score` with enough
   measures to overflow). Assert page 2's leading-edge offset uses
   `evenLeftMargin`. Then construct the same score with
   `style.pageLayout.twosided = false` and assert page 2 reverts to
   `oddLeftMargin`.
10. `staffSizeFollowsSpatium` — export with default `.fromScore`;
    verify via the same `Resolved` struct used internally
    (`PDFExporter.resolve(options:score:)` — exposed `internal` for
    tests via `@testable import`) that `staffSize ≈ 4 × spatium_mm ×
    72 / 25.4`.

New file: `Tests/SheetMusicTests/PageChromeMacroTests.swift`.

11. `expandsBasicPageMacros` — table-driven test over `$P`, `$p`,
    `$N`, `$n`, `$$`. Inputs include explicit page index and total
    page count; outputs are the literal expanded strings.
12. `expandsMetaTagMacros` — `$T`, `$C`, `$c`, `$:movementTitle:`
    expand from a synthetic `metaTags` dictionary; missing tags
    expand to empty string.
13. `firstPageOnlyAndSkipFirstPage` — assert `$C` is empty after
    page 1 and `$p` is empty on page 1.

New file: `Tests/SheetMusicTests/PDFExporterPageChromeTests.swift`.

14. `pageNumberInDefaultRightHeader` — export a 2-page synthetic
    score; reparse PDF; extract text on page 2 (PDFKit
    `page.string`); assert "2" appears (came from the default
    `oddHeaderR = "$p"` substitution).
15. `headerFooterDisabledViaStyle` — fixture overriding
    `<showHeader>0</showHeader>` and `<showFooter>0</showFooter>`;
    assert the rendered PDF page text contains no chrome.
16. `firstPageHeaderHiddenWhenHeaderFirstPageFalse` — default
    behaviour: page 1 has no `$p` (because it would print "0" if
    naïvely substituted, MuseScore omits it). With
    `<headerFirstPage>1</headerFirstPage>` overridden, page 1 still
    prints "1" via `$P` (test the non-`$p` variant).

The PDF-introspection tests use `PDFKit` (`PDFDocument`,
`PDFPage.bounds(for: .mediaBox)`, `PDFPage.string`); the leading-edge
tests check the geometry the exporter computes directly rather than
rasterising and hunting pixels.

## Backwards compatibility

- `Score`'s memberwise initializer gains a defaulted `style:` parameter
  at the end. All existing call sites compile unchanged.
- `PDFExporter.Options.init` becomes source-incompatible for callers
  that passed `pageSize:` / `margin:` / `staffSize:` positionally. The
  three legacy presets `Options.usLetter` / `Options.a4` are migrated
  to `EngravingPage.usLetter` / `EngravingPage.a4`. The example app
  call site is updated as part of the PR.
- `PDFExporter.paginate(systems:pageSize:margin:)` is retained as an
  overload that wraps the new core with a uniform-margin
  `EngravingPage` so external callers (if any) continue to compile.

## Risks

- **MuseScore's right-margin derivation drifts.** If a fixture has
  `pagePrintableWidth + 2 × leftMargin > pageWidth`, the derived right
  margin goes negative. We treat that as "the file is what it is" and
  let it produce a negative inset — visually the system runs off the
  page edge, mirroring MuseScore's behavior. We do not clamp.
- **`<Spatium>` capitalization.** The current repo-root fixture uses
  lowercase. Both forms must be accepted; tests cover both.
- **Existing tests that build `Score` directly.** None currently set
  `style:`, but several construct fixtures with explicit `division /
  parts / staves` parameters. The defaulted parameter at the end of
  the initializer means they keep compiling.
- **Edwin font is not bundled.** MuseScore renders all chrome in its
  bundled "Edwin" font. We fall back to the system serif when Edwin
  is unavailable — pixel-identical chrome is therefore not promised.
  Acceptable for a first pass; bundling Edwin would shift this from
  a libraries problem to a licensing-and-distribution problem.
- **`headerOffset` / `footerOffset` ignored on first pass.** MuseScore
  exposes a `<headerOffset x y>` adjustment that nudges the chrome
  inside the margin region. We render at the centre of the margin
  band as a fixed rule. Honoring `headerOffset` is mechanical follow-
  up work; fixtures that lean on this will shift by a few points.
- **`$T` is a private convenience macro.** MuseScore expects users
  to write `$:workTitle:`. Documenting our `$T` extension prevents
  user surprise.
- **Inline mixed page-number formatting.** A header string like
  `Page $P of $n` containing both regular text and a page-number
  macro draws the entire string in the header font (not the
  `pageNumberFont`). MuseScore renders this with mixed fragments. We
  accept this divergence — implementing per-fragment font switching
  inside `CTLine` adds a layer of attributed-string assembly that
  isn't justified for the typical case ("$P" alone in a slot).
