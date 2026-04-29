# Marquee Selection — Design

Date: 2026-04-29
Status: Approved

## Goal

Let an iOS user drag a rectangle over the score to select every musical
event (chord/rest) whose anchor falls inside that rectangle, then
highlight the selected events with the existing selection-render
pipeline. The same query also gives us an O(log N) "nearest event at X"
primitive that future features (drag-scrub of the playback cursor,
marker-flash on MIDI input) can reuse.

End state demoable in the iOS Example app:

1. Toggle a "Marquee" mode in the toolbar.
2. Drag on the score → translucent rectangle follows the finger.
3. Release → every chord/rest whose anchor is inside the rectangle is
   highlighted in the selection colour. The marquee outline disappears.
4. Drag over an empty area → selection clears.

## Non-goals

- Lasso (arbitrary polygon). Rectangle only.
- Shift-extend / additive selection (`drag` + held modifier).
- Marquee on macOS — the existing time-range selection (anchor + target)
  already covers it; macOS adds nothing in this PR.
- Auto-scroll while the finger reaches the screen edge mid-drag.
- Selecting non-event glyphs (beams, stems, barlines, dynamics, lyrics).

## Approach

Three layers, bottom-up:

### 1. Layout-time index — `LayoutSystem.eventColumns`

Each `LayoutSystem` precomputes a sorted-by-X array of
`EventColumn` records, one per chord/rest anchor in that system.
This array is the substrate for both the marquee query (rect → ids)
and the future nearest-X query (point → id).

```swift
public struct EventColumn: Sendable, Equatable {
    public let id: ScoreItemID         // .note(NoteID) | .rest(RestID)
    public let staffIndex: Int
    public let voiceIndex: Int
    public let centerX: CGFloat        // system-relative
    public let centerY: CGFloat        // system-relative
    public let bbox: CGRect            // system-relative; for tolerance
}

public struct LayoutSystem: Sendable, Equatable {
    // existing fields…
    public let eventColumns: [EventColumn]   // sorted ascending by centerX
    public let maxBBoxHalfWidth: CGFloat     // for binary-search tolerance
}
```

A chord with multiple notes contributes ONE `EventColumn` keyed on the
chord's anchor (the topmost notehead's `NoteID`, matching what
`ScoreHitTester.hitTest(at:)` returns when you tap that anchor). This
keeps the marquee semantics consistent with single-tap selection: a
selected chord highlights all its noteheads via the existing
`SelectionRenderState` color path.

`bbox` is the union of the chord's notehead rects (or the rest's rect),
used by the rect-intersection test so a rectangle that grazes a chord
still picks it up.

Built once at `LayoutEngine` system-finalize time (`+SystemBuild` or
`+Translate`); no runtime cost on render path.

### 2. Library queries — `ScoreHitTester`

```swift
extension ScoreHitTester {
    /// All chord/rest IDs whose layout bbox intersects `rect`
    /// (in `LayoutDocument` coords, same space as `hitTest(at:)`).
    public func itemIDs(in rect: CGRect) -> [ScoreItemID]
}
```

Algorithm:

1. Walk `document.systems`, skip those whose Y band doesn't intersect
   `rect` (linear; system count is small but cheap to short-circuit).
2. For each surviving system, binary-search `eventColumns` for the
   first index whose `centerX + system.maxBBoxHalfWidth >= rect.minX`
   and the last whose `centerX - system.maxBBoxHalfWidth <= rect.maxX`
   (`lowerBound` / `upperBound`). `maxBBoxHalfWidth` is precomputed
   alongside `eventColumns` at index-build time so the binary-search
   bounds are tight enough that no event with a bbox-intersecting `rect`
   gets pruned.
3. For the resulting slice, retain entries whose `bbox` intersects
   `rect` (filters out staves/voices outside the rect's Y range, and
   trims the X tolerance back to actual bbox membership).
4. Output preserves visit order (system top-to-bottom, then X
   ascending) so callers get a deterministic, musically-ordered list.

Complexity: `O(systems_intersecting_rect · (log E + k))` where E is
events per system and k is the result size. For typical scores this is
a sub-millisecond query, fast enough to call on every drag-update tick.

A separate `nearestItem(at:)` is **not** part of this PR — it shares the
same index but is gated on a future feature that needs it.

### 3. Selection model — `ScoreSelection.multi`

```swift
public enum ScoreSelection: Sendable, Equatable {
    case none
    case single(ScoreItemID)
    case range(anchor: ScoreItemID, target: ScoreItemID)  // existing time-range
    case multi(Set<ScoreItemID>)                          // NEW: arbitrary set
}
```

`SelectionRenderState.make` for `.multi(ids)`:

```swift
return SelectionRenderState(
    selectedIDs: ids,
    voiceColors: cgColors,
    drawRangeBox: false,
    rangeBoxColor: defaultBoxColor)
```

No range box — marquee is conceptually a *set selection*, not a time
window, so the per-system "selection rectangle" overlay used by `.range`
doesn't make semantic sense for it. The marquee outline drawn during
the drag is an Example-app concern, not a `ScoreView` concern.

## iOS Example integration

Toolbar gains a "Marquee" toggle (SF Symbol: `rectangle.dashed`).
While ON:

- Tap inside the score is consumed as the start of a drag (`DragGesture(minimumDistance: 0)`).
- The drag's `translation` defines a rect anchored at the start point.
- A SwiftUI `.overlay` draws a translucent fill (~12% alpha) + dashed
  stroke matching the existing selection colour.
- On `.onEnded`, call `tester.itemIDs(in: finalRect)`. If non-empty:
  `selection = .multi(Set(ids))`; if empty: `selection = .none`.
- Toggling Marquee OFF restores the existing tap/long-press handlers.

The toggle approach is chosen over "long-press → drag" because:
- We may add long-press → snap-cursor later (already discussed).
- Mode-switch is unambiguous: users don't accidentally start a marquee
  while trying to scroll.
- One-handed scroll vs. selection stays predictable.

macOS: no change. Existing range-selection covers the demo need.

## Tests

Library:
- `ScoreHitTesterTests` (existing suite) gains `itemIDs(in:)` cases:
  - rect inside a single measure → only that measure's chords.
  - rect spanning multiple systems → ids in visit order.
  - rect that misses every event → empty.
  - rect that contains the entire first system → all events of system 0.
  - rect that grazes a chord (bbox touches but centerX outside the rect
    when no tolerance is applied) → still selected.
  - chord-only / rest-only fixtures.
- New `LayoutSystemEventColumnsTests`: assert the index is sorted by
  `centerX`, has one entry per chord/rest, staff/voice indices match.

Example: no automated tests (UI-only); covered by manual demo.

## Files touched

New:
- `Sources/SheetMusicLayout/Layout/LayoutSystemEventColumns.swift`
  — `EventColumn` type + extension that builds the index from a
  `LayoutSystem`'s elements.
- `Tests/SheetMusicTests/LayoutSystemEventColumnsTests.swift`
- (Example) `Example/SheetMusicExample/iOS/MarqueeOverlay.swift`
  — translucent-rect overlay + drag handling.

Modified:
- `Sources/SheetMusicLayout/Layout/LayoutSystem.swift`
  — store `eventColumns` field; init builds it.
- `Sources/SheetMusicUI/Selection/ScoreSelection.swift`
  — add `.multi(Set<ScoreItemID>)`.
- `Sources/SheetMusicUI/Selection/SelectionRenderState.swift`
  — handle `.multi` case.
- `Sources/SheetMusicUI/Selection/ScoreHitTester.swift`
  — add `itemIDs(in:)`.
- `Tests/SheetMusicTests/Helpers/ScoreSemanticComparison.swift`
  — no change expected (eventColumns derive from elements, no
  format-noise impact); flag here so we re-verify after impl.
- `Example/SheetMusicExample/ContentView.swift`
  — Marquee toggle in toolbar; wire overlay; route gestures by mode.

## Risks / open questions

- **`ScoreSelection.multi` exhaustiveness**: every `switch` over the
  enum in the codebase needs a `.multi` case (or default). Audit list
  before merging — currently only `SelectionRenderState.make` switches
  on it, but verify with a compile pass.
- **Equatable on `LayoutSystem`**: adding a stored `[EventColumn]`
  changes the auto-synthesised `==`. Since `eventColumns` is
  deterministically derived from the existing fields, equality stays
  correct, but doc-comment that callers shouldn't supply diverging
  values via `init`.
- **`init` ergonomics**: `LayoutSystem.init` either (a) computes
  `eventColumns` from the elements internally, or (b) requires the
  caller to pass them. (a) is safer; (b) keeps `init` stateless.
  Lean (a): the engine is the only constructor in production paths,
  and tests benefit from "construct system from elements, get index
  for free".
