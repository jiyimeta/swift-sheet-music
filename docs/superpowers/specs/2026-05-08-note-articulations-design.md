# Note Articulations (staccato / staccatissimo / tenuto) — Design

Date: 2026-05-08

## Summary

Add support for chord-level `<Articulation>` elements in `.mscx` files,
covering the three **duration-shaping articulations** (staccato,
staccatissimo, tenuto) in the decoder, encoder, and MIDI renderer.
Unknown subtypes are not silently dropped — they are preserved verbatim
as `.unknown(rawSubtype)` so the encoder can write the same XML back
(round-trip safety).

Currently `<Articulation>` children of `<Chord>` are ignored by the
decoder. A staccato dot in the source has no audible effect in MIDI
output, and a round-trip through the encoder strips the marking.

## Motivation

- **Score fidelity:** Staccato is the most common articulation marking
  on real scores. Without note-length shortening, MIDI playback differs
  audibly from the original.
- **Round-trip safety:** Now that MSCX export ships, dropping markings
  on the input side is a silent corruption that users won't easily
  notice.
- **Extensibility:** Introducing `Chord.articulations` makes future
  additions (marcato / accent / fermata-on-chord / ornaments) a matter
  of adding enum cases, with no further model changes.

## Non-goals

- Other duration-shaping articulations (portato / louré / mezzoStaccato).
  No new enum case — they fall through to `.unknown(...)` and round-trip
  only.
- Velocity-shaping articulations (accent / marcato / sforzato). They
  fit the same machinery, but ship after the duration-shaping family
  is verified end-to-end.
- Ornaments (trill / mordent / turn) — different internal representation
  in MuseScore (separate class).
- ChordLine / Bend / Vibrato.
- Automatic Above/Below anchor decision. The decoder preserves the
  SymId variant present in the source; the encoder writes back the
  same anchor unless the caller mutates it.
- Articulations on grace notes — same boundary as the Grace Notes spec.
- Layout / glyph rendering (the actual dot or bowing mark on the
  staff). Out of scope for this PR; ship MIDI + round-trip first, UI
  separately.

## In-scope articulation kinds

| Marking | MS4 SymId (Above / Below) | MS3-compat name | Default gateTime % |
|---|---|---|---|
| Staccato (dot) | `articStaccatoAbove` / `articStaccatoBelow` | `staccato` | 50 |
| Staccatissimo (wedge) | `articStaccatissimoAbove` / `articStaccatissimoBelow` | `staccatissimo` | 33 |
| Tenuto (bar) | `articTenutoAbove` / `articTenutoBelow` | `tenuto` | 100 |

Default gateTime % matches MuseScore's default Instrument articulation
table (cross-checked against `midi01.mscx` which carries the full
`<Articulation name="staccato">` etc. preset block). Tenuto's MuseScore
default is 100; if a score wants a stretched-tenuto effect, it overrides
via the Instrument preset (covered below).

## Reference points (MuseScore C++)

- `engraving/dom/articulation.h` — `Articulation` class
- `engraving/dom/chord.h` — `Chord::_articulations`
- `engraving/dom/articulation.cpp` — `Articulation::write` /
  `Articulation::read` (subtype = SymId string)
- `engraving/compat/midi/compatmidirender.cpp` —
  `CompatMidiRender::collectMeasureEvents`
  (`getPlayTicks` / `articulationGateTime`)
- `engraving/dom/symid.cpp` — SymId names (`articStaccatoAbove` etc.)
- MS3 compat (`MasterScore::read302`): MS3 may write subtype as either
  an integer ID or a SymId string. This implementation accepts SymId
  strings only — all available fixtures are 3.6.2+ and use SymIds.

## Core model

New file `Sources/SheetMusicCore/Score/ChordArticulation.swift`:

```swift
import Foundation

/// Per-chord articulation marking. C++: `mu::engraving::Articulation`.
public struct ChordArticulation: Sendable, Equatable {
    public var kind: Kind
    /// Anchor side written by MuseScore (`articStaccatoAbove` vs
    /// `…Below`). Preserved verbatim for round-trip; encoder defaults
    /// to `.above` when `nil` (matches MuseScore's default for newly
    /// created articulations).
    public var anchor: Anchor?

    public init(kind: Kind, anchor: Anchor? = nil) {
        self.kind = kind
        self.anchor = anchor
    }

    public enum Kind: Sendable, Equatable {
        case staccato
        case staccatissimo
        case tenuto
        /// Any subtype outside the in-scope set above. The raw MS4
        /// SymId (e.g. `articAccentAbove`) is preserved so the encoder
        /// can write the same XML back, but the MIDI renderer ignores
        /// it.
        case unknown(subtype: String)
    }

    public enum Anchor: Sendable, Equatable {
        case above
        case below
    }
}
```

Extend `Chord` with one new field. Existing call sites stay
source-compatible because the new parameter has a default:

```swift
public struct Chord: ... {
    public var duration: NoteDuration
    public var notes: ChordNotes
    public var arpeggio: Arpeggio?
    public var lyrics: [Lyric]
    public var articulations: [ChordArticulation]   // new

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = [],
        articulations: [ChordArticulation] = []     // new (trailing default)
    ) { ... }
}
```

## Decoder

Extend `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`. Right
after the arpeggio block, harvest the `<Articulation>` children:

```swift
let articulations = node.all("Articulation").map { artNode -> ChordArticulation in
    let subtype = artNode.first("subtype")?.text ?? ""
    return ChordArticulation.fromSubtypeXML(subtype)
}
```

`ChordArticulation.fromSubtypeXML(_:)` (a decoder-side helper) does:

1. Strip the `Above` / `Below` suffix to derive `anchor`.
2. Map the remaining base name to `kind`:
   - `articStaccato` → `.staccato`
   - `articStaccatissimo` → `.staccatissimo`
   - `articTenuto` → `.tenuto`
   - anything else → `.unknown(subtype: <raw>)`, `anchor = nil`
     (the raw string is preserved verbatim for round-trip).
3. If subtype is empty → `.unknown(subtype: "")`, anchor nil. MuseScore
   never emits this, but the permissive-parser convention says don't
   throw.

Note: MS3 may add `<channel>` / `<anchor>` children alongside
`<subtype>` inside `<Articulation>`. We pull subtype only and silently
skip the rest, in line with the project's permissive-parser convention.
If overrides for velocity / gateTime per articulation become relevant,
extend later.

## Encoder

Extend `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift`. Insert
articulation output between `appendDurationXML` and the lyrics block.
This matches MuseScore's `Chord::write` ordering (`durationType` →
`StemDirection` → `ChordLine` / `Articulation` / `Tremolo` → `Lyrics` →
`Note`). Duration-shaping articulations sit naturally directly after
`durationType` and are accepted by both MS4 and MS3 readers.

```swift
duration.appendDurationXML(to: &children)
for art in articulations {
    children.append(art.encode(options: options))
}
for lyric in lyrics where !lyric.text.isEmpty { ... }
for note in notes { ... }
```

New file `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift`:

```swift
extension ChordArticulation {
    func encode(options: MSCXEncoderOptions) -> XMLTreeNode {
        let subtype = subtypeXML()
        return XMLTreeNode(
            name: "Articulation",
            children: [XMLTreeNode(name: "subtype", text: subtype)]
        )
    }

    private func subtypeXML() -> String {
        let suffix: String
        switch anchor {
        case .below:        suffix = "Below"
        case .above, nil:   suffix = "Above"
        }
        switch kind {
        case .staccato:        return "articStaccato\(suffix)"
        case .staccatissimo:   return "articStaccatissimo\(suffix)"
        case .tenuto:          return "articTenuto\(suffix)"
        case .unknown(let raw): return raw
        }
    }
}
```

Defaulting `anchor == nil` to `.above` on encode matches MuseScore's
default anchor for newly created articulations. `unknown` writes the
raw subtype verbatim and ignores the `anchor` field (the decoder leaves
it nil for unknowns anyway).

v3 / v4 differences: this SymId-string-based `<subtype>` is accepted by
both MuseScore 3.6.2+ and MS4 (verified by the `midi01` fixture, which
is a 3.6.2 export using SymId form). `MSCXEncoderOptions.targetVersion`
does not branch the encoder. The MS3 strictness risk noted in the
project memory does not apply here as long as the Instrument preset
names (existing `name="staccato"` etc.) match.

## MIDI rendering

Extend `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`. The
current per-chord gateTime computation (line 228):

```swift
let gate = defaultArticulationGateTime(for: instrument)
```

becomes a chord-aware lookup:

```swift
let gate = effectiveGateTime(for: chord, instrument: instrument)
```

`effectiveGateTime(for:instrument:)` behaviour:

1. Filter `chord.articulations` to in-scope kinds (`.staccato` /
   `.staccatissimo` / `.tenuto`). If empty, return the instrument's
   unnamed-default articulation gateTime (existing behaviour
   preserved).
2. For each in-scope articulation, look up the Instrument preset table
   (`instrument.articulations`) by name:
   - `.staccato`      → preset `name == "staccato"`
   - `.staccatissimo` → preset `name == "staccatissimo"`
   - `.tenuto`        → preset `name == "tenuto"`
   Hardcoded fallback when the preset is absent: 50 / 33 / 100.
3. Aggregate by taking the **minimum** gateTime % among the candidates
   (matches MuseScore's `MidiArticulation::aggregateOf` behaviour:
   the most-shortening articulation wins). For example, staccato +
   tenuto on the same chord — possible to construct in mscx even if
   MuseScore's UI doesn't allow it — yields the staccato value.
4. Velocity scaling stays untouched. Duration-shaping articulations
   never adjust velocity; the existing
   `defaultArticulationVelocityScale` path is unchanged.

## Editor APIs

`Sources/SheetMusicCore/ScoreCursor.swift` and friends are not touched.
A mutating API for editing `Chord.articulations` is out of scope for
this PR. All existing tests construct `Chord(duration:..., notes:...)`
with two arguments; the trailing default for `articulations` keeps them
source-compatible.

## Tests

New file `Tests/SheetMusicTests/ChordArticulationTests.swift`:

1. **Decode (single):** `<Chord><durationType>quarter</durationType>
   <Articulation><subtype>articStaccatoAbove</subtype></Articulation>
   <Note>...</Note></Chord>` decodes to `articulations == [.init(.staccato,
   anchor: .above)]`.
2. **Decode (multiple):** staccato + tenuto in the same chord. Order
   preserved, anchors independent.
3. **Decode (unknown):** `<subtype>articAccentAbove</subtype>` →
   `.unknown(subtype: "articAccentAbove")`.
4. **Encode round-trip:** Chord with staccato/Above, staccatissimo/Below,
   and one unknown — encode → decode equals the original.
5. **Encode default anchor:** staccato with `anchor = nil` produces
   `articStaccatoAbove` in the emitted XML.

New file `Tests/SheetMusicTests/MidiRendererArticulationTests.swift`:

6. **Staccato, default:** Instrument with no staccato preset, chord
   carries `.staccato` → noteOff fires at 50% gateTime offset.
7. **Staccato, instrument override:** Instrument preset
   `InstrumentArticulation(name: "staccato", gateTime: 25)` → 25%.
8. **Staccatissimo, default:** 33%.
9. **Tenuto, default:** 100% (full duration).
10. **No articulation:** existing instrument-default gateTime preserved
    (regression guard).
11. **Multiple, smallest wins:** staccato + tenuto on the same chord
    → 50%.
12. **Unknown ignored:** chord with only `.unknown(...)` falls through
    to the instrument-default gateTime (same as no articulation).

A new mscx fixture `articulation_staccato.mscx` is **not** added.
Adding it to `MidiExportTests` would require a paired `*-ref.mid`
reference, which we cannot generate without running MuseScore. Cases
6–12 build the `Score` programmatically and assert on event tick
offsets — same style as existing `MidiRendererTests`.

## File-by-file diff summary

```
Sources/SheetMusicCore/Score/Chord.swift
  + var articulations: [ChordArticulation]
  + init: trailing parameter `articulations: [ChordArticulation] = []`

Sources/SheetMusicCore/Score/ChordArticulation.swift            [NEW]

Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift
  + harvest node.all("Articulation") into articulations
  + ChordArticulation.fromSubtypeXML(_:) helper (private)

Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift
  + emit articulations between durationType and lyrics

Sources/SheetMusicMSCX/Encoders/MSCXEncoder+ChordArticulation.swift [NEW]

Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift
  - line 228: defaultArticulationGateTime → effectiveGateTime(for: chord, instrument:)
  + effectiveGateTime helper

Tests/SheetMusicTests/ChordArticulationTests.swift              [NEW]
Tests/SheetMusicTests/MidiRendererArticulationTests.swift       [NEW]
```

## Risks / Open questions

- **MS3 round-trip:** `articStaccatoAbove`-style SymIds are accepted by
  3.6.2 (verified against the existing `midi01` fixture, which is a
  3.6.2 export using SymId form). The implementation plan should still
  include a sanity check by emitting an mscx with chord-level staccato
  and opening it in native 3.6.2.
- **Anchor semantics:** MuseScore renders `Above` above the staff and
  `Below` below. This implementation preserves the side for round-trip
  only; rendering does not consume `anchor` (UI is out of scope).
- **No `MidiExportTests` addition:** as noted, a `*-ref.mid` from
  MuseScore is needed for that suite, and we don't run MuseScore in CI.
  Programmatic MIDI assertions cover the gateTime semantics instead.
