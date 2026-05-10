# Fermata MIDI hold duration — Design

Status: brainstormed 2026-05-10. Successor to spec → plan flow.

## Goal

When a `Score` contains a `.fermata` element, the rendered MIDI should
hold the anchored chord/rest for longer real-time, mirroring MuseScore's
playback. Today the renderer no-ops on fermatas
(`MidiRenderer+Voice.swift:268-273`), so the feature is silent.

## Non-goals (v1)

- **Multi-chord fermata ranges.** A fermata anchors to exactly one
  chord/rest. We do not implement "fermata over a phrase" semantics.
- **Tempo changes inside a fermata's tick range.** Structurally
  impossible under the one-chord anchor rule, so out of scope.
- **MuseScore-equivalence regression test for fermatas.** No upstream
  fixture exists; authoring one is deferred. Hand-rolled Score unit
  tests cover the rendering math.
- **Cross-staff dedupe of identical fermata ranges.** Per-staff dedupe
  only. Multiple staves may emit identical tempo meta events at the
  same tick; SMF semantics keep this idempotent.

## Approach: tempomap insertion (MuseScore parity)

Hold is achieved by inserting a temporary tempo change covering the
fermata's tick range:

```
tick:    T0 ──── chord_duration ──── T1
tempo:   bpm/stretch                 bpm  (restored)
```

The chord's nominal tick length is unchanged, so concurrent voices,
ties, spanners, and subsequent events stay in sync without re-timing.
This mirrors MuseScore's `tempomapWithPauses` — already tolerated by
`MidiSemanticComparison.swift`.

## Model changes

### `Sources/SheetMusicCore/Score/Fermata.swift`

```swift
public struct Fermata: Sendable, Equatable {
    public var subtype: String

    /// MIDI hold ratio. 1.0 = no stretch. MSCX `<timeStretch>` overrides
    /// the subtype default when present.
    /// C++: `mu::engraving::Fermata::timeStretch`.
    public var timeStretch: Double

    public init(subtype: String, timeStretch: Double? = nil) {
        self.subtype = subtype
        self.timeStretch = timeStretch ?? Self.defaultTimeStretch(for: subtype)
    }

    static func defaultTimeStretch(for subtype: String) -> Double {
        switch subtype {
        case "fermataVeryShortAbove", "fermataVeryShortBelow",
             "fermataShortHenzeAbove", "fermataShortHenzeBelow":
            return 1.25
        case "fermataAbove", "fermataBelow",
             "fermataShortAbove", "fermataShortBelow":
            return 1.5
        case "fermataLongAbove", "fermataLongBelow",
             "fermataLongHenzeAbove", "fermataLongHenzeBelow":
            return 2.0
        case "fermataVeryLongAbove", "fermataVeryLongBelow":
            return 3.0
        default:
            return 1.5
        }
    }
}
```

### MSCX decoder (`MSCXDecoder+Voice.swift:116-118`)

Read `<timeStretch>` if present (parsed as `Double`); pass `nil`
otherwise so the subtype default applies.

```swift
case "Fermata":
    let subtype = child.first("subtype")?.text ?? ""
    let stretch = child.first("timeStretch")?.text.flatMap(Double.init)
    elements.append(.fermata(Fermata(subtype: subtype, timeStretch: stretch)))
```

### MSCX encoder (`MSCXEncoder+Fermata.swift`)

Emit `<timeStretch>` only when it differs from the subtype default
(round-trip parity with MuseScore's "omit when default" convention):

```swift
func encode() -> XMLTreeNode {
    var children = [XMLTreeNode(name: "subtype", text: subtype)]
    let defaultStretch = Fermata.defaultTimeStretch(for: subtype)
    if timeStretch != defaultStretch {
        children.append(XMLTreeNode(name: "timeStretch",
                                    text: String(timeStretch)))
    }
    return XMLTreeNode(name: "Fermata", children: children)
}
```

## Rendering pipeline

### Anchor rule

A `.fermata` element anchors to the nearest `.chord` (rest included) in
the **same voice**:

1. **Forward search** — scan voice elements after the fermata for the
   first `.chord`. This is the hot path (MusicXML decoder always
   pre-positions fermatas; many MSCX files do too).
2. **Backward fallback** — if no following chord exists in the voice,
   scan backwards for the most recent `.chord`. Covers MSCX files where
   `<Fermata>` appears as a sibling after `<Chord>` in the segment.
3. **Drop silently** — if neither direction yields a chord, the fermata
   is discarded for MIDI purposes (permissive parser convention).

### `FermataRange` collection

New file `Sources/SheetMusicMIDI/Render/FermataRanges.swift`:

```swift
struct FermataRange: Sendable, Equatable {
    let startTick: Int    // original (pre-repeat) tick of anchor chord
    let endTick: Int      // exclusive: startTick + chord.duration.ticks
    let stretch: Double   // ≥ 1.0
}

enum FermataRanges {
    /// Walks every voice in the staff, anchors fermatas, and returns
    /// the per-staff range list (already deduped on identical
    /// (startTick, endTick) — max stretch wins).
    static func collect(from staff: Staff, division: Int) -> [FermataRange]
}
```

The collection pass mirrors how `HairpinRamps` and `OttavaRanges` are
gathered today (per-staff, original ticks).

### Tempo timeline

Pre-build a tempo timeline from staff 0 / voice 0:

```swift
struct TempoTimeline {
    var entries: [(tick: Int, bps: Double)]   // sorted, includes (0, 2.0)
    func bps(at tick: Int) -> Double          // last entry where tick' ≤ tick
}
```

This is shared infrastructure used by the sweep-merge below to read the
"base" tempo at any boundary tick, including ticks where a `.tempo`
element coincides with a fermata bookend.

### Sweep-merge → tempo bookends

For every distinct boundary tick `t_i` ∈ `{startTick, endTick} ∀ range`:

1. Compute `active = { stretch | range covers [t_i, t_{i+1}) }`
2. `effectiveStretch = active.max() ?? 1.0`
3. `baseBps = tempoTimeline.bps(at: t_i)`
4. Emit tempo meta at `t_i`: `bpm = baseBps × 60 / effectiveStretch`

The final boundary (where `effectiveStretch` returns to 1.0) emits the
plain `baseBps`-derived tempo to restore normal playback.

This handles full-overlap, partial-overlap, and nested same-range
fermatas with one algorithm — at every tick the effective stretch is
exactly `max` of all covering fermatas.

### Emission order at the same tick

The renderer's `[TimedMidiEvent]` sorter must enforce, for same-tick
events, the order:

1. **fermata bookend (open)** — stretch increasing
2. **score `.tempo` event** — user's intended tempo at that tick
3. **fermata bookend (close)** — stretch decreasing / restore

Rationale:

- **Start co-location**: a `.tempo` change exactly at a fermata's
  startTick is consumed by the timeline pre-build, so the fermata
  bookend already reads the new base. The order above is therefore
  trivially safe.
- **End co-location**: the fermata's restore comes first, then the
  user's `.tempo` overrides it as last-write-wins. Subsequent music
  plays at the user's intended tempo, not the pre-fermata base.

### Where to emit

Existing `.tempo` elements emit tempo meta events from voice 0 of every
staff (`MidiRenderer+Voice.swift:194-198`). Fermata bookends follow the
same convention — every staff's voice 0 emits identical tempo meta at
the same tick. SMF semantics tolerate the duplication.

## Tests

### `Tests/SheetMusicTests/FermataMidiTests.swift` (new)

Hand-rolled Score values exercise the rendering math directly:

1. **Single normal fermata on quarter note** at 120 BPM. Expect tempo
   80 BPM (= 120 / 1.5) for the held quarter, then 120 BPM restored.
2. **Long fermata on rest (grand pause)**. Expect tempo 60 BPM for the
   rest range, no extra notes, original tempo restored.
3. **MSCX `<timeStretch>` override** (subtype default 1.5,
   `timeStretch = 2.5`). Expect tempo 48 BPM during the held chord.
4. **Fermata after chord in MSCX order** — voice list
   `[chord, fermata, chord]`. Expect anchor to the preceding chord and
   identical bookends to the canonical "fermata before chord" case.
5. **Same-range fermatas in two voices** — staff with voice 1 and
   voice 2 both holding the same beat. Expect a single tempo bookend
   pair per staff with `effectiveStretch = max(...)`.
6. **Partial overlap (sweep-merge)** — voice 1 fermata stretch 2.0 on a
   dotted-quarter, voice 2 fermata stretch 1.5 on a quarter at the
   same start tick. Expect three regions: max(2.0, 1.5) = 2.0,
   then 1.5 only, then 1.0 restored.
7. **Boundary co-location with `.tempo`** — fermata's endTick coincides
   with a `.tempo(180)`. Expect tempo 180 BPM after fermata, not the
   pre-fermata base.

### `Tests/SheetMusicTests/MSCXEncoderTextElementsTests.swift` (extend)

Augment `fermataRoundTrip` with cases that include explicit
`<timeStretch>` values and verify:

- `timeStretch != default` round-trips losslessly (XML has the element)
- `timeStretch == default` is omitted from the XML (matches MuseScore)

### Regression

`swift test` and the full 12-case `MidiExportTests` MuseScore-equivalence
suite must remain green. None of those fixtures contain fermatas, so the
expected impact is zero.

## File touch list

**New:**

- `Sources/SheetMusicMIDI/Render/FermataRanges.swift`
- `Tests/SheetMusicTests/FermataMidiTests.swift`

**Modified:**

- `Sources/SheetMusicCore/Score/Fermata.swift` — add `timeStretch`
  field and subtype-default helper.
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift:116-118` —
  parse `<timeStretch>`.
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Fermata.swift` — emit
  `<timeStretch>` when not default.
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — replace
  the `.fermata` no-op site; thread `FermataRanges` through the staff
  walk; integrate sweep-merge tempo emission alongside the existing
  `.tempo` path with the documented ordering.
- `Sources/SheetMusicMIDI/Render/MidiRenderer.swift` (and/or
  `MidiRenderer+Header.swift`) — wire collection and tempo timeline
  pre-build alongside the existing per-staff `HairpinRamps` /
  `OttavaRanges` collection.

## Known limitations (deferred)

- **Multi-chord fermata ranges** would require splitting the anchor
  model. Not planned.
- **Tempo changes strictly between a fermata's start and end ticks**
  are structurally impossible under the one-chord anchor rule.
  If multi-chord ranges land later, the timeline pre-build can be
  re-evaluated at every internal tempo change.
- **Cross-staff dedupe** — multiple staves emit duplicate tempo meta
  events. SMF readers ignore duplicates of equal value, so audible
  behavior is unaffected; file size grows by ~6 bytes per fermata per
  staff.
