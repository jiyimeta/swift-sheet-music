# Velocity-Shaping Articulations (accent / marcato / combined) — Design

Date: 2026-05-09

## Summary

Extend the chord-level articulation pipeline shipped in
`feature/note-articulations` (staccato / staccatissimo / tenuto) to the
**velocity-shaping family**: accent, marcato, and the two combined
SymIds that mix velocity boost with duration shortening
(accent-staccato, marcato-staccato). Coverage is end-to-end:

- **Decoder / Encoder**: round-trip for the four new MS4 SymIds (each
  with Above / Below variants).
- **MIDI rendering**: a per-chord velocity-scale lookup symmetric to
  the existing `effectiveGateTime`, plus combined-kind support so the
  staccato halves of the combined SymIds also shorten gateTime.
- **Layout / glyph rendering**: four new `LayoutElement.ArticulationKind`
  cases routed through the existing emitter and `ArticulationRenderer`.

Subtypes outside this set continue to round-trip as `.unknown(subtype:)`
and remain invisible / inaudible (same boundary as the previous PR).

## Motivation

- **Audible accents**: today an `articAccentAbove` in `.mscx` is parsed
  as `.unknown(...)`, so accents have no MIDI effect — the playback
  under-articulates the source. Visually the dot/accent never appears.
- **Visual fidelity**: the pipeline already draws staccato/tenuto
  glyphs; accents are the next-most-common marking on real scores and
  cost only a handful of new switch cases.
- **Symmetry**: the staccato PR locked in a clean shape (Kind enum →
  preset name → instrument lookup → MAX/MIN aggregate). Velocity slots
  in alongside gateTime with no architectural changes.

## Non-goals

- **Soft accent / stress / unstress / tenuto-accent / laissez-vibrer**:
  remain in `.unknown(subtype:)`, round-trip only.
- **`<Dynamic subtype="sf">` / sfz / sff**: these are MuseScore
  Dynamics, not articulations. Already MIDI-encoded via the existing
  `Dynamic.velocity` path. Not covered here.
- **User-tunable aggregation rules**: hard-coded MAX velocity / MIN
  gateTime mirroring `MidiArticulation::aggregateOf`.
- **Editor / mutating APIs** to add or remove articulations on a chord.
- **Articulation glyphs on `GraceChord`**: the model has no
  `articulations` field on graces; same boundary as the previous PR.
- **Auto-combine** of separate `.accent` + `.staccato` entries into a
  single combined glyph at layout time. The model is taken literally:
  one `LayoutElement.articulation` per `ChordArticulation`.
- **MS3 integer-form `<subtype>`**: SymId-string form only, same as
  the previous PR (verified for 3.6.2+ which all fixtures use).

## In-scope articulation kinds

| Marking | MS4 SymId (Above / Below) | MS3-compat preset name | Default velocity % | Default gateTime % |
|---|---|---|---|---|
| Accent (`>`) | `articAccentAbove` / `articAccentBelow` | `accent` | 120 | — (no shortening) |
| Marcato (`^`) | `articMarcatoAbove` / `articMarcatoBelow` | `marcato` | 120 | — |
| Accent-staccato (`>` + dot) | `articAccentStaccatoAbove` / `articAccentStaccatoBelow` | `accent` + `staccato` | 120 | 50 |
| Marcato-staccato (`^` + dot) | `articMarcatoStaccatoAbove` / `articMarcatoStaccatoBelow` | `marcato` + `staccato` | 120 | 50 |

Defaults match MuseScore's `defaultArticulationList`
(`engraving/dom/instrtemplate.cpp`). Combined kinds reuse the existing
`accent` / `marcato` and `staccato` preset names — there is no
`"accentStaccato"` preset to look up.

## Reference points (MuseScore C++)

- `engraving/dom/articulation.cpp` — `Articulation::write` / `::read`,
  SymId-string form for `<subtype>`.
- `engraving/dom/instrtemplate.cpp` — default articulation table
  (velocity / gateTime % per preset name).
- `engraving/compat/midi/compatmidirender.cpp` —
  `CompatMidiRender::collectMeasureEvents`, the per-chord aggregation
  path the staccato PR already mirrors.
- `engraving/dom/symid.cpp` — SymId names, including the four combined
  SymIds.

## Core model

`Sources/SheetMusicCore/Score/ChordArticulation.swift` — extend the
existing `Kind` enum:

```swift
public enum Kind: Sendable, Equatable {
    case staccato
    case staccatissimo
    case tenuto
    case accent             // articAccentAbove/Below
    case marcato            // articMarcatoAbove/Below
    case accentStaccato     // articAccentStaccatoAbove/Below
    case marcatoStaccato    // articMarcatoStaccatoAbove/Below
    case unknown(subtype: String)
}
```

No changes to `ChordArticulation`'s outer struct or to `Chord`. The
update-stamp doc comment at the top of the file now reads
"duration-shaping family + velocity-shaping family".

## Decoder

`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` —
`fromSubtypeXML(_:)` mapping. Replace the current "strip suffix → switch
on remaining stem" logic with a longest-prefix-first dispatch (an
explicit ordered list of `(stem → Kind)` checks), so
`articAccentStaccato` is matched before `articAccent`.

```swift
private static func kindAndAnchor(
    fromSubtype raw: String
) -> (Kind, Anchor?) {
    let (stem, anchor) = stripAnchorSuffix(raw)
    // Longest prefix first — order matters.
    switch stem {
    case "articStaccatissimo":     return (.staccatissimo, anchor)
    case "articStaccato":          return (.staccato, anchor)
    case "articTenuto":            return (.tenuto, anchor)
    case "articAccentStaccato":    return (.accentStaccato, anchor)
    case "articMarcatoStaccato":   return (.marcatoStaccato, anchor)
    case "articAccent":            return (.accent, anchor)
    case "articMarcato":           return (.marcato, anchor)
    default:                       return (.unknown(subtype: raw), nil)
    }
}
```

`stripAnchorSuffix` is a small helper that returns
`(stemBeforeSuffix, .above | .below | nil)`. Empty subtype → `.unknown(subtype: "")`,
anchor nil (permissive-parser convention).

## Encoder

`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift` —
extend `subtypeXML()`:

```swift
switch kind {
case .staccato:         return "articStaccato\(suffix)"
case .staccatissimo:    return "articStaccatissimo\(suffix)"
case .tenuto:           return "articTenuto\(suffix)"
case .accent:           return "articAccent\(suffix)"
case .marcato:          return "articMarcato\(suffix)"
case .accentStaccato:   return "articAccentStaccato\(suffix)"
case .marcatoStaccato:  return "articMarcatoStaccato\(suffix)"
case .unknown(let raw): return raw
}
```

`anchor == nil` continues to default to `Above`.

v3 / v4: SymId-string form is accepted by both readers (verified by
existing fixtures). No `targetVersion` branching.

## MIDI rendering

`Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`.

### New helper: `effectiveVelocityScale(for:instrument:)`

Mirrors the shape of the existing `effectiveGateTime`, but takes the
**maximum** velocity %.

```swift
static func effectiveVelocityScale(
    for chord: Chord,
    instrument: Instrument
) -> Int {
    let scales = chord.articulations.compactMap { art -> Int? in
        let presetName: String
        let hardcodedDefault: Int
        switch art.kind {
        case .accent, .accentStaccato:
            presetName = "accent"; hardcodedDefault = 120
        case .marcato, .marcatoStaccato:
            presetName = "marcato"; hardcodedDefault = 120
        case .staccato, .staccatissimo, .tenuto, .unknown:
            return nil
        }
        return instrument.articulations
            .first(where: { $0.name == presetName })?
            .velocity ?? hardcodedDefault
    }
    if let maximum = scales.max() {
        return maximum
    }
    return defaultArticulationVelocityScale(for: instrument)
}
```

### `effectiveGateTime` extension

Add the combined cases so they participate in gateTime aggregation via
the existing `staccato` preset:

```swift
case .accentStaccato, .marcatoStaccato:
    presetName = "staccato"; hardcodedDefault = 50
case .accent, .marcato:
    return nil   // velocity-only kinds don't shorten
```

This guarantees `[.accentStaccato]` and `[.accent, .staccato]` produce
identical noteOff ticks.

### Per-chord modifier (applied only to main-chord notes)

The voice-level running `velocity` is left as-is — it continues to be
re-derived from the active Dynamic via `effectiveVelocity(forDynamic:
instrument:)`. For each chord, `renderChordWithGraces` adjusts the
velocity used **only for the main-chord noteOns** (graces stay on the
unboosted `velocity`, matching MuseScore: articulations attach to the
parent chord, not to its grace satellites).

```swift
static func adjustVelocityForChord(
    baseVelocity: Int,
    chord: Chord,
    instrument: Instrument
) -> Int {
    let defaultScale = defaultArticulationVelocityScale(for: instrument)
    let effectiveScale = effectiveVelocityScale(for: chord, instrument: instrument)
    if defaultScale == effectiveScale { return baseVelocity }
    return min(127, max(1, baseVelocity * effectiveScale / defaultScale))
}
```

`baseVelocity` already has the **default** articulation scale baked in
(set by `effectiveVelocity` at lines 20 / 67 / 179). The modifier
swaps the default scale for the chord-effective scale via
`base * eff / def`. When the chord has no velocity-shaping
articulation, `effectiveScale == defaultScale` and the function is a
no-op (regression-safe).

### Call sites

`MidiRenderer+Voice.swift` lines 20 / 67 / 179 are unchanged.

`MidiRenderer+Grace.swift::renderChordWithGraces`:

- Before emitting **before-graces** (line ~152 region): keep
  `velocity` as-is.
- Before emitting the **main chord notes** (arpeggio + non-arpeggio
  branches, lines ~189–211): compute
  `let mainVelocity = adjustVelocityForChord(baseVelocity: velocity,
   chord: chord, instrument: instrument)` and substitute `mainVelocity`
  in the relevant `velocity:` arguments.
- Before emitting **after-graces** (line ~226 region): keep `velocity`
  as-is.

## Layout

`Sources/SheetMusicLayout/Layout/LayoutElement.swift` — extend
`ArticulationKind`:

```swift
public enum ArticulationKind: Sendable, Equatable {
    case staccato
    case staccatissimo
    case tenuto
    case accent
    case marcato
    case accentStaccato
    case marcatoStaccato
}
```

`Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` —
extend `renderableKind(_:)` switch with the four new mappings.
Anchor / outside-staff push / Y stacking logic is unchanged: each
`ChordArticulation` produces exactly one `LayoutElement.articulation`,
including the combined kinds (one combined glyph, not two).

`LayoutEngine+YBounds.swift` and `LayoutEngine+Translate.swift` need
no changes — they already match on the `.articulation` case
generically.

## Glyph mapping

`Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift` — add eight new
codepoints (Bravura, U+E4A0..E4B1):

| Glyph | Codepoint |
|---|---|
| `articAccentAbove` | U+E4A0 |
| `articAccentBelow` | U+E4A1 |
| `articMarcatoAbove` | U+E4AC |
| `articMarcatoBelow` | U+E4AD |
| `articAccentStaccatoAbove` | U+E4B0 |
| `articAccentStaccatoBelow` | U+E4B1 |
| `articMarcatoStaccatoAbove` | U+E4AE |
| `articMarcatoStaccatoBelow` | U+E4AF |

`Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift` —
extend the `glyph(kind:isAbove:)` switch with eight new cases. The
`draw(...)` body, `ScoreCanvas` switch, and
`ScoreLayerBuilder+Element` switch need no further changes — they
dispatch via `glyph(kind:isAbove:)` and `LayoutElement.articulation`
respectively.

## Tests

### `Tests/SheetMusicTests/ChordArticulationVelocityTests.swift` (NEW)

1. **Decode accent**: `articAccentAbove` → `.accent / .above`.
2. **Decode marcato (Below)**: `articMarcatoBelow` → `.marcato / .below`.
3. **Decode accent-staccato**: `articAccentStaccatoAbove` →
   `.accentStaccato / .above` (longest-prefix-first guard: must not
   collapse to `.accent` + spurious tail).
4. **Decode marcato-staccato**: `articMarcatoStaccatoBelow` →
   `.marcatoStaccato / .below`.
5. **Encode round-trip**: chord carrying all four new kinds across
   Above/Below variants, plus one `.unknown` — encode → decode is
   identity.
6. **Encode default anchor**: `.accent` with `anchor = nil` emits
   `articAccentAbove`.

### `Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift` (NEW)

7. **Accent default**: instrument with no accent preset, chord carries
   `.accent`, no Dynamic → noteOn velocity = `defaultDynamicVelocity *
   120 / 100 = 96`.
8. **Accent override**: preset `InstrumentArticulation(name: "accent",
   velocity: 140)` → 112 (`80 * 140 / 100`).
9. **Marcato default**: `.marcato` → 96.
10. **Combined accent-staccato (single)**: `.accentStaccato` alone
    produces velocity 96 **and** noteOff at 50% gateTime.
11. **Combined marcato-staccato (single)**: same, marcato variant.
12. **Equivalence**: `.accentStaccato` and `[.accent, .staccato]`
    produce identical noteOn velocity and identical noteOff tick.
13. **Aggregation MAX**: `.accent` plus instrument preset
    `marcato velocity=130` together with `.marcato` (or two velocity
    sources) — result picks the maximum.
14. **No regression**: chord with no velocity-shaping articulation
    keeps the existing instrument-default velocity scale.
15. **Dynamic interplay**: `Dynamic(velocity: 100)` + `.accent` →
    `min(127, 100 * 120 / 100) = 120`.

### `Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift` (NEW)

16. **Accent emit**: `.accent / .above` chord →
    `LayoutElement.articulation(kind: .accent, isAbove: true, ...)`,
    1 entry.
17. **Combined emit (1 glyph)**: `.accentStaccato / .below` →
    1 entry of `kind: .accentStaccato`, not 2 entries.
18. **Glyph mapping**: parametrised over the 8 new (kind, isAbove)
    pairs; each maps to the expected SMuFL `Character`.
19. **`ScoreLayerBuilder` smoke**: chord with `.accent` produces a
    glyph layer entry; pipeline does not crash. Mirrors the existing
    staccato smoke test.

### Fixtures

No new `.mscx` / `*-ref.mid` fixtures. Same rationale as the previous
PR: `*-ref.mid` would require running MuseScore.

## Visual verification (out of CI)

Mac example app: open an mscx augmented programmatically with a chord
of each new kind; eyeball glyph placement vs. MuseScore's own
rendering of the same file. Per project memory, visual checks use
`SheetMusicExampleMac`, not the iOS Simulator.

## File-by-file diff summary

```
Sources/SheetMusicCore/Score/ChordArticulation.swift
  + 4 new Kind cases

Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift
  ~ fromSubtypeXML: longest-prefix dispatch over 7 stems

Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift
  ~ subtypeXML: 4 new cases

Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift
  + effectiveVelocityScale(for:instrument:)
  + adjustVelocityForChord(baseVelocity:chord:instrument:)
  ~ effectiveGateTime: + combined cases / explicit nil for velocity-only kinds
  (effectiveVelocity / 3 call sites at lines 20/67/179 unchanged)

Sources/SheetMusicMIDI/Render/MidiRenderer+Grace.swift
  ~ renderChordWithGraces: compute mainVelocity via adjustVelocityForChord;
    use it for arpeggio + non-arpeggio main-note emit only (graces unchanged)

Sources/SheetMusicLayout/Layout/LayoutElement.swift
  + 4 new ArticulationKind cases

Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift
  ~ renderableKind switch: 4 new mappings

Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift
  + 8 new SMuFL codepoints

Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift
  ~ glyph switch: 8 new cases

Tests/SheetMusicTests/ChordArticulationVelocityTests.swift           [NEW]
Tests/SheetMusicTests/MidiRendererVelocityArticulationTests.swift    [NEW]
Tests/SheetMusicTests/LayoutVelocityArticulationTests.swift          [NEW]
```

## Risks / open questions

- **Decoder prefix ordering bug**: if combined SymIds are matched after
  `articAccent` / `articMarcato` they collapse to the wrong Kind. The
  longest-prefix-first switch and Test #3 are the load-bearing checks.
- **Auto anchor for accent**: MuseScore biases accent placement to the
  note side rather than strict opposite-side. The existing
  opposite-side rule is "good enough for v1" (same posture as the
  staccato PR's anchor risk note).
- **Aggregation edge cases**: a user-crafted mscx with `.accent` +
  `.marcato` on the same chord (MuseScore UI prevents this) takes the
  MAX velocity of the two. This is consistent with the gateTime MIN
  rule and shouldn't surprise.
- **Bravura coverage**: all eight codepoints exist in Bravura (the
  font shipped with the package). No fallback handling needed.
- **Combined glyph baseline**: the combined SMuFL glyph is anchored
  the same as a single glyph in Bravura's metrics — the existing
  `±0.5 sp` Y formula stays correct without a per-kind tweak.
- **Marcato default gateTime**: some historical MuseScore default
  tables ship marcato with gateTime ≈ 67% (slight shortening) rather
  than 100%. This spec keeps `.marcato` as velocity-only (no
  shortening) and lets the score override via the Instrument preset
  if shorter gateTime is needed. Implementation plan should
  cross-check the `midi01.mscx` preset block during work and adjust
  the hardcoded fallback if the table actually carries `marcato
  gateTime != 100`. Same applies to accent (canonically 100%).
