# PDF mode: playback cursor, auto-scroll, tap-to-seek

Status: design (2026-04-28)
Scope: example app only (`Example/SheetMusicExample`). No library
changes to `SheetMusicPDF` / `SheetMusicUI` / `SheetMusicAudio`.

## Goal

Bring the iOS example's **PDF preview mode** to feature parity with
its vertical / horizontal modes for live playback:

- A blue translucent **playback cursor** on the active chord/rest,
  drawn on whichever page contains it.
- **Auto-scroll** during playback. PDF mode's scroll view is
  bi-directional, so:
  - Horizontal: bring the active **page** into view when it scrolls
    off the side.
  - Vertical: at zoom levels where the page is taller than the
    viewport, bring the active **system** into view.
- **Tap-to-seek**: tapping a note / rest while playing seeks the
  audio engine to that item; tapping while paused/stopped sets the
  selection (and triggers preview playback) — same handler as
  vertical/horizontal modes.

The macOS variant is out of scope for this spec (it currently has no
PDF preview mode).

## Non-goals

- No changes to `PDFExporter` output. The exported PDF stays
  cursor-free and tap-inert; this is a preview-only enhancement.
- No new public library API. Everything is composed inside the
  example.
- No new hit-test pipeline. We reuse `ScoreHitTester(document:)`
  with the existing `pdfDoc`.
- No "follow as you scroll" inverse behavior. Auto-scroll is
  cursor → viewport, not viewport → cursor.

## Current architecture (recap)

`Example/SheetMusicExample/ContentView.swift`:

- `pdfPreview(score:)` resolves engraving page geometry via
  `PDFExporter.resolve` and lays out a `LayoutDocument` (`pdfDoc`)
  + page batches (`pdfPages: [PDFExporter.PageBatch]`).
- `pdfPreviewContent(...)` renders an `HStack` of `PDFPageView`s
  inside a `ScrollView([.horizontal, .vertical])`. Pinch-to-zoom
  is split: visual `scaleEffect(pdfGestureScale)` during the
  gesture, committed `pdfScale` (drives `PDFPageView.renderScale`)
  on gesture end.
- No `playbackCursor` is passed; no `onChange(of: currentCursor)`
  hook; no tap gesture.

Vertical/horizontal precedents (`AutoScroll.swift`, `ContentView`):

- `LayoutDocument.cursorFrame(for:in:)` already returns a doc-coord
  cursor rect that spans the system's full staff range.
- `LayoutDocument.systemIndex(forMeasureIndex:)` finds the system
  that owns a measure.
- Per-row anchors (`VerticalSystemAnchors`, `HorizontalMeasureAnchors`)
  emit live frames via `PreferenceKey`s in a named coord space, and
  expose `.id(...)` ids for `ScrollViewReader.scrollTo`.
- `autoScroll(...)` only scrolls when the active row is *not*
  fully visible (frame-based check; `paddedAnchor` keeps an 8 sp
  inset on the leading edge after the scroll lands).

## Design

### Coordinate model

The on-screen PDF preview composes three coord spaces:

1. **Doc coords** (the `LayoutDocument`): origin at top-left of
   page 1's content area; `cursorFrame.minY ≥ 0`. Pages cover
   `[pageStartY, pageStartY + usableHeight]`.
2. **Page-local** (inside one `PDFPageView`'s frame): doc → page is
   `(x + margins.leading, y - pageStartY + margins.top)`.
3. **`pdfScroll`** (the named coord space we'll add to the outer
   `ScrollView`): page-local times the active scale (committed
   `pdfScale` outside a pinch, `pdfScale * pdfGestureScale` during
   one), plus the page's offset in the HStack.

Cursor rendering and auto-scroll only need (1) and (2): the
overlay sits inside `PDFPageView`'s frame so `scaleEffect` on the
ancestor scales both the page Canvas and the cursor uniformly.
Auto-scroll uses (3) for the visibility check, sourced from
`GeometryReader.frame(in: .named("pdfScroll"))`.

### Cursor overlay

Add a sibling overlay to `PDFPageView` inside `pdfPreviewContent`'s
`ForEach`. The overlay is a SwiftUI view (kept inside the example
app, not the library) that:

- Takes `cursor: ScoreCursor?`, `doc: LayoutDocument`, `score: Score`,
  `pageStartY: CGFloat`, `usableHeight: CGFloat`,
  `margins: PageMargins`, `pageSize: CGSize`.
- Calls `doc.cursorFrame(for: cursor, in: score)`. If `nil`, or the
  frame's Y span doesn't intersect `[pageStartY, pageStartY +
  usableHeight]`, render `EmptyView`.
- Otherwise builds a `Rectangle` at
  `(x: frame.minX + margins.leading,
    y: frame.minY - pageStartY + margins.top)`
  with `frame.size`. Same fill (`Color.blue.opacity(0.15)`) as
  `PlaybackCursorView`. `allowsHitTesting(false)`.

It sits in the same `VStack` slot as `PDFPageView` via a `ZStack`,
sized to `pageSize` (same frame as the Canvas) so the parent
`scaleEffect` handles zoom uniformly. We don't reuse
`PlaybackCursorView` directly because (a) it draws in unscaled doc
coords with no page-Y offset, and (b) its `allowsHitTesting(false)`
needs to compose with our new tap gesture; an in-example helper
keeps that wiring local.

### Auto-scroll

Add `ScrollViewReader { proxy in ... }` around the existing
`ScrollView([.horizontal, .vertical])` and name its coord space
`"pdfScroll"`.

**Horizontal axis (page-level).** Tag each page's column with
`.id(PDFPageAnchorID(pageIndex: idx))`. Use a `PreferenceKey` keyed
by page index → CGRect to track each page's live frame in
`"pdfScroll"`. On cursor change:

1. Find the active page: smallest `idx` whose `pages[idx]`
   contains a system with the cursor's measure (linear scan of
   `pages.systems.measures.measureIndex`).
2. If the page's X span is fully inside the viewport's X span,
   no-op (same `isFullyVisible` rule as vertical/horizontal).
3. Otherwise `proxy.scrollTo(PDFPageAnchorID(pageIndex: idx),
   anchor: paddedAnchor(...horizontal))`.

**Vertical axis (system-within-page, only when zoomed).** When the
content height exceeds the viewport, do the same dance for the
cursor's system within the active page:

1. Tag each system on each page with
   `.id(PDFSystemAnchorID(pageIndex: p, systemIndexInPage: s))`,
   sized to the system's staff range and emitted via a sibling
   `PreferenceKey` (per-system frame in `"pdfScroll"`).
2. On cursor change, after handling horizontal: if the active
   system's Y span isn't fully visible, scroll vertically with
   `paddedAnchor` and `.center`-ish horizontal (we keep the
   horizontal target unchanged).

`scrollTo` only allows one anchor per call. We sequence them:
horizontal first inside the same `withAnimation` block; then
vertical in a second `scrollTo` if needed. SwiftUI coalesces
back-to-back `scrollTo`s on the same proxy into a single animation.

The visibility-based no-op rule means the user's manual scroll
position is preserved as long as the cursor stays in view —
mirrors vertical/horizontal mode's UX.

### Tap-to-seek

Wrap each page's Canvas in `.onTapGesture { location in ... }`.
The gesture fires in the page's local space. Convert to doc coords:

```
docX = location.x - margins.leading
docY = location.y - margins.top + pageStartY
```

Pass `(docX, docY)` to `ScoreHitTester(document: pdfDoc).hitTest(at:)`.
Forward the result to the **existing** `handleTap` in `ContentView`
— that already encodes the seek-on-play / select-on-pause / preview
behavior. Net change: rename or factor `handleTap` so it can take
either a `LayoutDocument` parameter (already does) and accept a
pre-resolved `CGPoint` in doc coords.

`MagnificationGesture` + `onTapGesture` co-exist on iOS without an
explicit `.simultaneousGesture` — taps don't fire mid-pinch
because the magnification gesture wins, which is the behavior we
want (no accidental seeks during pinch).

### State plumbing summary

New `@State`s in `ContentView`:

- `pdfPageFrames: [Int: CGRect]` — page index → frame in `pdfScroll`
- `pdfSystemFrames: [PDFSystemAnchorID: CGRect]` — system → frame in
  `pdfScroll`

New types in `Example/SheetMusicExample/AutoScroll.swift` (extend
the existing file rather than adding a new one — this is the
established home for example-side anchor scaffolding):

- `struct PDFPageAnchorID: Hashable { let pageIndex: Int }`
- `struct PDFSystemAnchorID: Hashable { let pageIndex: Int; let
  systemIndexInPage: Int }`
- `PDFPageFramesKey: PreferenceKey`
- `PDFSystemFramesKey: PreferenceKey`

New view in `Example/SheetMusicExample/`:

- `PDFCursorOverlay.swift` — the per-page cursor overlay described
  above. Local to the example because the doc → page-local
  translation is preview-specific.

### Toggle / disable conditions

The auto-scroll & tap handlers no-op when `pdfDoc == nil` (initial
load) or when the cursor's measure index isn't found in any page
(stale cursor after a score swap). Mirrors the existing guards in
`autoScroll(...)`.

## Edge cases

- **Cursor crosses a page break mid-system.** Can't happen:
  `paginate` never splits a system, so any cursor frame's Y span
  fits inside exactly one page's `[pageStartY, pageStartY +
  usableHeight]` interval.
- **Cursor straddles when system overruns its page** (the rare
  too-tall-system case handled by `paginate`'s "spill" rule).
  The cursor draws on its *home* page (the one whose
  `pageStartY ≤ frame.minY`), even if its bottom edge visually
  extends past the page footer. Same behavior as the printed PDF
  shows for the system itself.
- **Score swap during playback.** `adoptLoadedScore` already nils
  `pdfDoc`/`pdfPages`. The overlay's nil check makes this a no-op
  until the new doc/pages land.
- **Zoom changes while cursor is on screen.** Frames are reported
  per-render, so the no-op rule keeps the user's scroll position
  unless the new zoom genuinely pushes the cursor off-screen.
- **Tap during pinch.** `MagnificationGesture` consumes; tap is
  silently dropped — desired.

## Testing plan

The example app has no automated UI tests (per CLAUDE.md), so this
is manual:

1. Load `test.mscx`, switch to PDF mode, hit play. Cursor appears
   on page 1, advances chord-by-chord. ✓
2. As playback crosses pages, the active page scrolls into the
   horizontal viewport with the same 8 sp inset as vertical mode. ✓
3. Pinch-zoom in until a single page exceeds the viewport
   vertically. Confirm vertical auto-scroll lands the active
   system in view. ✓
4. While playing, tap a note on a non-active page. Audio seeks;
   page may scroll horizontally on the next cursor tick (since the
   new cursor is on that page). ✓
5. Pause, tap a rest. Selection updates and shows blue highlight
   (same as vertical/horizontal). ✓
6. Stop, change scores via the file picker. Re-enter PDF mode and
   confirm cursor/scroll state resets cleanly. ✓
7. SwiftLint: 0 new warnings. `swift build` / `swift test` green
   (test target is unaffected, but verify nothing in the example
   bleeds into shared code).

## Risks / open questions

- **Two-axis `scrollTo` ordering.** If SwiftUI doesn't coalesce
  the two scroll calls cleanly (visible flicker), fall back to
  a single combined target — pick whichever axis is "more out
  of view" and only fix that one this tick; the other axis
  catches up on the next cursor change. Will validate during
  implementation.
- **`pdfGestureScale` during cursor updates.** During an active
  pinch, `pdfGestureScale ≠ 1` and `scaleEffect` is in play. The
  cursor still draws correctly (it's inside the scaled subtree)
  but the visibility check uses post-scale frames in
  `"pdfScroll"`, which is what we want anyway. No change needed.
- **Frame storms.** Every `scaleEffect` animation tick republishes
  preferences; the `onChange(of: currentCursor)` fires only on
  cursor change so storms don't reach the auto-scroll handler.
  Verified.
