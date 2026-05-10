# Clef Selection and Replacement

## Goal

Allow users of the example app to tap/click a clef in the rendered
score and replace it with one of four choices: treble G, treble G with
ottava-bassa (G8vb), bass F, bass F with ottava-bassa (F8vb).

The library exposes the selection and edit primitives so that any host
app — not just `SheetMusicExample` — can build the same interaction.
The example wires up a SwiftUI popover with a 2×2 glyph grid as the
reference UI.

## Scope

- Selectable clef instances:
  - **Explicit clef changes** — `VoiceElement.clef(Clef)` anywhere in
    the score.
  - **Staff-default clefs** — the synthesized clef rendered at the
    very start of the score when the first measure has no explicit
    `<Clef>` (sourced from `Staff.defaultClefType`).
- **Not selectable**: continuation-system header clefs (the synth
  clef that appears at the leftmost column of every system after the
  first). They re-state the active clef but are not authoritative.
- Replacement vocabulary in the example app: `G`, `G8vb`, `F`, `F8vb`.
  Library-level APIs accept any clef raw-type string `Clef` already
  supports.
- macOS only for the example UI. iOS host wiring is out of scope.

## Non-goals

- Adding new clef shapes (alto, tenor, percussion, 15ma/15mb) to the
  popover. The library keeps supporting them via `Clef.concertClefType`.
- Inserting a *new* clef change at an arbitrary point in a measure.
  Only existing clefs (explicit or staff-default) can be edited.
- MIDI semantics: clefs remain display-only — `MidiRenderer` is not
  touched.

## Library-level changes

### `ClefAnchor` (SheetMusicCore)

New value identifying *which* clef an action targets.

```swift
public enum ClefAnchor: Hashable, Sendable {
    /// An explicit `VoiceElement.clef` at this voice-element location.
    case explicit(VoiceElementID)
    /// The synthesized clef at the start of the score derived from
    /// `Staff.defaultClefType` for the named staff.
    case staffDefault(StaffAddress)
}
```

### `ScoreItemID.clef` (SheetMusicCore)

Add a fourth case so the existing selection / hit-test pipeline can
carry clef identity end-to-end:

```swift
public enum ScoreItemID: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case tuplet(TupletID)
    case clef(ClefAnchor)              // NEW
}
```

Existing accessors (`staff`, `measureIndex`, `voiceIndex`,
`elementIndex`) extend to the clef case:

- `.clef(.explicit(let id))` → values come from `id` (the
  `VoiceElementID`).
- `.clef(.staffDefault(let staff))` → `staff` is the staff address;
  `measureIndex = 0`, `voiceIndex = 0`, `elementIndex = 0`.

This is purely a positional approximation for sort / comparison; the
authoritative target for editing is the `ClefAnchor` itself.

Adding a `ScoreItemID` case requires updating every exhaustive
switch on it. Audit them all in this change set.

### `SetStaffDefaultClef` (SheetMusicCore)

New `EditCommand` for editing the staff-default path.

```swift
public struct SetStaffDefaultClef: EditCommand {
    public let staff: StaffAddress
    public let newRawType: String?   // nil clears the default
}
```

`apply(to:)` writes `Staff.defaultClefType = newRawType` and returns
the inverse (the previous value). Throws `SheetMusicError.invalidEdit`
if `staff` does not resolve to a real staff.

`ReplaceVoiceElement` already covers the explicit-clef path — no new
command is needed there.

### `LayoutElement.clef` carries an anchor (SheetMusicLayout)

Layout currently emits:

```swift
case clef(rawType: String, origin: CGPoint)
```

Extend to:

```swift
case clef(rawType: String, origin: CGPoint, anchor: ClefAnchor?)
```

- Explicit clef voice elements set `anchor = .explicit(VoiceElementID)`.
- Staff-default synthesized clef at measure 0 sets
  `anchor = .staffDefault(StaffAddress)`.
- Continuation-system header clefs (re-statement on every new system)
  set `anchor = nil`.

Sites to update:

- `LayoutEngine+Placement.swift` — explicit and synthesized-from-default
  emit (the `initialClefRawType` path and the `case let .clef(c)`
  branch in voice element loop).
- `LayoutEngine+Contexts.swift` — `headerLayoutElements` (continuation
  header) emits with `anchor = nil`.
- `LayoutEngine+Translate.swift` — preserves the new field through
  shifts.
- Renderer / hit-tester / any other site reading the case must update
  its pattern. The translate function is the easy gotcha — exhaustive
  switch on `LayoutElement` lives in several places.

### `ScoreHitTarget.clef` and hit-testing (SheetMusicUI)

```swift
public enum ScoreHitTarget: Hashable, Sendable {
    // existing cases…
    case clef(ClefAnchor)
}
```

`ScoreHitTester.hitTest(at:)` adds a `hitClef` step. Bounding-box
heuristic: a rectangle around the clef origin sized to roughly the
glyph's visual extent — `width ≈ sp × 2`, `height ≈ sp × 5` —
shifted by the same per-clef y-offset `ClefRenderer.draw` applies
(treble +1 sp, bass −1 sp, C-clef 0). Only matches when
`anchor != nil`.

`itemID(at:)` extends to return `.clef(anchor)` when the hit is a
selectable clef.

Hit priority: clefs are checked **before** notes/rests would not be
correct (clefs sit before the notes in x); they are checked **after**
notes/rests/beam/flag/stem/tuplet at the existing per-measure
dispatch. Notes/rests almost never overlap clefs (clefs sit in the
header column), so the priority order is robust either way.

### Selection rendering (SheetMusicUI)

`SelectionRenderState.selectedIDs: Set<ScoreItemID>` already feeds
the renderer. Extend `ScoreLayerBuilder`'s clef-drawing path so that
when `selectedIDs.contains(.clef(anchor))`, the glyph is drawn in the
selection tint instead of black. `ClefRenderer.draw` accepts an
optional `tint: CGColor?` (or equivalent) so callers stay simple.

## Example app (macOS)

### State

`ContentViewMac` adds:

```swift
@State private var clefPopover: ClefPopoverState? = nil

struct ClefPopoverState: Equatable {
    let anchor: ClefAnchor
    let currentRawType: String
    let attachmentRect: CGRect    // doc-coord rect of the clef glyph
}
```

### Tap handling

In the existing tap handler, after marquee / selection logic, add a
clef-first branch:

```swift
if case let .clef(anchor) = tester.hitTest(at: location) {
    let raw = currentClefRawType(for: anchor)        // helper
    let bbox = clefHitRect(for: anchor)              // from layout
    clefPopover = .init(anchor: anchor,
                        currentRawType: raw,
                        attachmentRect: bbox)
    selection = .single(.clef(anchor))
    return
}
```

Selecting a clef also sets `ScoreSelection.single(.clef(...))` so the
existing highlight pipeline tints the glyph.

### Popover view

```swift
struct ClefPopover: View {
    let current: ClefChoice
    let onPick: (ClefChoice) -> Void
}

enum ClefChoice: Hashable {
    case trebleG, trebleG8vb, bassF, bassF8vb

    var rawType: String { … }   // "G", "G8vb", "F", "F8vb"
    var smuflGlyph: Character { … }
}
```

2×2 grid (rows: G family, F family) of buttons drawn with the
SMuFL glyph from the existing `SMuFLGlyph` table (gClef, gClef8vb,
fClef, fClef8vb). The button matching `current` shows a selected
appearance (border / background tint) but is still clickable
(re-applying the same clef is a no-op edit and is fine).

Selecting a button calls `onPick`, dismisses the popover, and clears
`clefPopover`. Clicking outside the popover (SwiftUI default behavior)
also dismisses.

### Edit dispatch

```swift
private func applyClefChoice(_ choice: ClefChoice,
                             for anchor: ClefAnchor) {
    let newClef = Clef(concertClefType: choice.rawType)
    do {
        switch anchor {
        case .explicit(let veID):
            try noteInput.apply(
                ReplaceVoiceElement(at: veID,
                                    with: .clef(newClef)),
                undoManager: undoManager)
        case .staffDefault(let staff):
            try noteInput.apply(
                SetStaffDefaultClef(staff: staff,
                                    newRawType: choice.rawType),
                undoManager: undoManager)
        }
    } catch {
        errorMessage = "Failed to change clef: \(error)"
    }
}
```

`undo` / `redo` already flow through `NoteInputController`, so ⌘Z
reverts the clef change like any other edit.

### Re-anchor selection on re-layout

The layout document rebuilds after each edit. `clefPopover` is
dismissed before applying so there is no stale `attachmentRect`.
`selection` is cleared after the apply (single-clef selection lives
only while the popover is open).

## Error handling

- `SetStaffDefaultClef` throws `SheetMusicError.invalidEdit` when
  `staff` doesn't resolve. The host catches and surfaces in the
  existing `errorMessage` banner.
- `ReplaceVoiceElement` already throws when the location is stale.
- Hit-test returning `nil` or non-clef types simply leaves
  `clefPopover` at `nil`.

## Testing

### Unit (Core)

- `SetStaffDefaultClef` apply + inverse round-trip on a 2-staff score:
  setting, clearing, and resetting `defaultClefType`.
- Invalid `StaffAddress` throws `.invalidEdit`.
- `ScoreItemID.clef(.staffDefault(...))` Hashable + accessor defaults.

### Unit (Layout)

- `LayoutElement.clef` anchor is `.staffDefault` for the synthesized
  initial clef, `.explicit(VoiceElementID)` for an inserted clef
  change, and `nil` for the continuation-header restatement.

### Unit (UI)

- `ScoreHitTester.hitTest(at:)` returns `.clef(.staffDefault(...))`
  for a point on the leading clef of a fresh score.
- After inserting an explicit `VoiceElement.clef` mid-piece,
  hit-testing the new clef returns `.clef(.explicit(veID))`.
- A point on a continuation-header clef returns `nil` (or whatever
  background hit type), never `.clef`.

### Manual (macOS example)

Use Mac example app to verify:

1. Open `Resources/midi05.mscx` (or any sample with two staves).
2. Click the leading G clef on staff 1 → popover appears at the
   glyph.
3. Pick "F" → glyph re-renders as a bass clef, selection highlight
   matches.
4. ⌘Z reverts to G clef.
5. Insert a clef change voice element via existing tooling
   (or use a fixture that already has one) — repeat steps 2–4 on
   that mid-piece clef.
6. Click on a continuation-system header clef → no popover, no
   selection.

## Out-of-scope follow-ups

- Adding more clef choices (C-clefs, percussion, 15ma/15mb) to the
  popover.
- Inserting a *new* clef change inside a measure (would need a
  cursor / location picker UI).
- iOS popover variant.
- MusicXML / MSCX export verification of the new edit pathways
  (`SetStaffDefaultClef` round-trip is already covered by the
  existing MSCX encoder reading `Staff.defaultClefType`; explicit
  clef voice elements are likewise already handled).
