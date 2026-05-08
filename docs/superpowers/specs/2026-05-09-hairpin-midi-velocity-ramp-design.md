# Hairpin MIDI velocity ramp — design

Status: design approved 2026-05-09. Implementation plan TBD.

## Problem

`<HairPin>` cresc. / decresc. spanners are parsed and laid out today,
but `MidiRenderer+Voice.swift` skips `.spanner` entirely (line 140).
Discrete `Dynamic` markings drive note-on velocity correctly, so
`mp` and `ff` measures already sound at different volumes; what is
missing is the **continuous ramp** between two `Dynamic`s when a
hairpin connects them. A score reading `mp <[hairpin]> f` plays at
`mp` until the hairpin end, then jumps to `f` — the intermediate
crescendo never happens.

The goal is to make hairpins drive a per-note velocity ramp during
MIDI render so the in-between notes get interpolated velocities.

## Scope

In scope:

- `<HairPin>` cresc. / decresc. spanners written by MuseScore 3 / 4
- Linear velocity interpolation between resolved start / end velocities
- Hybrid endpoint resolution: bracket `Dynamic` at the hairpin's
  start tick / end tick takes priority; fall back to `<veloChange>`
  in the hairpin payload; fall back to a hard-coded ±10 default
- Round-trip safety for the new `<HairPin>` fields in MSCX export
- Test coverage via the upstream `testSingleNoteDynamics` fixture
  with a CC-event-ignoring semantic comparison option

Out of scope (recorded as future work):

1. Non-linear curve methods (`ease-in`, `ease-out`, `ease-in-out`,
   `exponential`) — decoded and stored, but interpolation falls
   through to linear in v1
2. Single Note Dynamics continuous controllers (CC11 Expression,
   CC1 Modulation, pitch bend) — note-on velocity only
3. Cross-voice / cross-staff `Dynamic` bracketing — same-voice only,
   matching the existing per-voice `Dynamic` design
4. `<TextLine>`-form crescendos (`cresc. _ _ _`) — handled separately
   under `Spanner.kind == .textLine`, not in this work
5. `Dynamic` own `<veloChange>` field (used for sfz etc.) — the
   `Dynamic` velocity itself is reflected, but its per-Dynamic
   change-amount attribute is not
6. Hairpins crossing repeat / volta boundaries — pre-pass computes
   ramps in original ticks, so each playback iteration re-applies
   the same ramp. Volta-only hairpins are not specifically scoped

## Architecture

```
                              ┌─ existing path (unchanged) ──────────┐
                              ▼                                       │
[Score]  parse  [Spanner.kind=.hairpin            ┌──────────────┐    │
 .mscx ───────► (+ HairpinPayload: subtype,       │ MidiRenderer │    │
                   veloChange, veloChangeMethod)] │   +Voice     │    │
                              │                   └──────┬───────┘    │
                              │                          │            │
                              ▼                          ▼            │
                  HairpinRamps.collect(voice)    chord onset:         │
                              │                  velocity = ramp(t)   │
                              ▼                  if any ramp active   │
                  [HairpinRamp(startTick,                ──────────────┘
                   endTick, startVel,
                   endVel, method)]
```

New file:

- `Sources/SheetMusicMIDI/Render/HairpinRamps.swift` — pre-pass +
  resolved-ramp value type + interpolator

Existing files modified:

- `Sources/SheetMusicCore/Score/Spanner.swift` — add `HairpinPayload`
  optional field
- `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Spanner.swift` — decode
  `<HairPin>` subtags
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift` — round-trip
  the same fields back
- `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift` — call
  pre-pass + override velocity at chord emit
- `Tests/SheetMusicTests/Helpers/MidiSemanticComparison.swift` — add
  `ignoreControlChange` option

## Data model

```swift
public struct Spanner: Sendable, Equatable {
    // existing fields …

    /// Meaningful only when `kind == .hairpin`. Nil for other kinds.
    public var hairpin: HairpinPayload?
}

/// MuseScore `<HairPin>` payload needed for MIDI playback.
/// C++: `mu::engraving::Hairpin`.
public struct HairpinPayload: Sendable, Equatable {
    public enum Subtype: Int, Sendable {
        case crescendo = 0
        case decrescendo = 1
    }

    /// Linear / ease curve. **v1 implements `.normal` (linear) only;
    /// other cases fall through to linear in `HairpinRamps.interpolate`.**
    public enum VeloChangeMethod: String, Sendable {
        case normal              // = linear; default when XML omits the tag
        case easeIn = "ease-in"
        case easeOut = "ease-out"
        case easeInOut = "ease-in-out"
        case exponential
    }

    public var subtype: Subtype
    /// `<veloChange>` value (1..127). Used when bracket Dynamics
    /// don't pin both endpoints. MuseScore's default of 0 is
    /// normalised to nil at decode time.
    public var veloChange: Int?
    public var veloChangeMethod: VeloChangeMethod
}
```

The string `rawType` (`"crescendo"` / `"decrescendo"`) and the
numeric `subtype` field both stay alive in the model: `rawType`
comes from the `<Spanner type="…">` attribute, `subtype` from
`<HairPin><subtype>`. Keeping both preserves round-trip exactly.

## Parser / encoder changes

### Decoder

Inside `Spanner.decode`, after the existing kind / next-location
handling, populate `hairpin` only when `kind == .hairpin`:

```swift
var hairpin: HairpinPayload?
if kind == .hairpin, let hp = node.first("HairPin") {
    let subtypeRaw = Int(hp.first("subtype")?.text ?? "0") ?? 0
    let subtype = HairpinPayload.Subtype(rawValue: subtypeRaw) ?? .crescendo

    let veloChangeText = hp.first("veloChange")?.text
    let veloChange = veloChangeText.flatMap(Int.init).flatMap { $0 == 0 ? nil : $0 }

    let methodRaw = hp.first("veloChangeMethod")?.text ?? ""
    let method = HairpinPayload.VeloChangeMethod(rawValue: methodRaw) ?? .normal

    hairpin = HairpinPayload(
        subtype: subtype,
        veloChange: veloChange,
        veloChangeMethod: method
    )
}
```

Decoding rules:

- `<subtype>` absent → `.crescendo` (matches MuseScore default)
- `<veloChange>0</veloChange>` is treated as "unspecified" (`nil`),
  same as the tag being absent
- `<veloChangeMethod>` absent → `.normal`
- Unknown method strings → `.normal` (forward-compat)

### Encoder

`MSCXEncoder+Spanner` writes the corresponding `<HairPin>` block
when `hairpin != nil`. Tags that match MuseScore's default values
are omitted (no `<veloChange>` when `nil`; no `<veloChangeMethod>`
when `.normal`). Visual properties (`<placement>`, `<lineWidth>`,
`<beginText>`, …) remain untouched — the existing scope of the
encoder is preserved.

## Pre-pass: `HairpinRamps`

```swift
struct HairpinRamp {
    let startTick: Int        // original score tick (pre-repeat)
    let endTick: Int          // inclusive
    let startVelocity: Int    // already articulation-scaled
    let endVelocity: Int      // already articulation-scaled
    let method: HairpinPayload.VeloChangeMethod
}

enum HairpinRamps {
    static func collect(
        voiceIndex: Int,
        staff: Staff,
        instrument: Instrument,
        division: Int
    ) -> [HairpinRamp]

    static func interpolate(
        ramp: HairpinRamp, atOriginalTick tick: Int
    ) -> Int

    static func active(
        in ramps: [HairpinRamp], at tick: Int
    ) -> HairpinRamp?
}
```

### Algorithm

Single voice walk in original (pre-repeat) ticks:

1. `runningTick = 0`, `runningVel = effectiveVelocity(forDynamic: nil, …)`
2. Walk measures in score order; for each measure, set
   `measureBase = sum of prior measure ticks`,
   `runningTick = measureBase`
3. For each `VoiceElement`:
   - `.dynamic(d)` → record `(tick: runningTick, vel: effectiveVelocity(d, instrument))`
     in a separate `dynList`, set `runningVel`
   - `.spanner(s)` where `s.kind == .hairpin` →
     compute `endTick` from `nextMeasuresOffset` /
     `nextFractionsOffset` against `measureBase`, append to
     `pending` with `(startTick: runningTick, endTick, startVel: runningVel, payload: s.hairpin ?? defaultPayload)`
   - `.chord(c)` → `runningTick += c.duration.ticks(division:)`
   - `.locationShift(δ)` → `runningTick += δ.ticks(division:)`
   - other elements: no tick advance
4. Resolve each `pending` into a `HairpinRamp`:
   - `endVel = firstDynamic(in: dynList, atTickOrAfter: p.endTick)?.vel`
     (a) if found: that's the end velocity
     (b) else if `p.payload.veloChange != nil`: `p.startVel ± veloChange`
     (c) else: `p.startVel ± defaultDelta` (defaultDelta = 10)
   - sign comes from `p.payload.subtype` (cresc → +, decresc → −),
     clamped to `1...127`
5. Return `[HairpinRamp]`

`interpolate(ramp:, atOriginalTick:)` is linear:
`start + (end - start) × (tick - startTick) / max(1, endTick - startTick)`,
clamped at endpoints. The `switch ramp.method` in this function
has a single `case .normal` branch today; non-`.normal` cases
fall through to the linear branch with a `// v1: linear-only`
comment so future curve work has an obvious extension point.

`active` returns the latest-starting ramp containing `tick` (a
defensive choice; well-formed scores don't overlap hairpins).

### Why same-voice scoping

`Dynamic` and `Spanner` are both `VoiceElement` cases, so the data
model already keys them to a single voice. Rendering treats
`velocity` as a per-voice running variable. A staff-level Dynamic
that affects all voices visually would be a separate, broader
change — out of scope here. Documented as future work.

## Renderer integration

`renderVoice` gains two pre-pass calls:

```swift
let hairpinRamps = HairpinRamps.collect(
    voiceIndex: voiceIndex,
    staff: staff,
    instrument: part.instrument,
    division: division
)
let originalMeasureBase = computeOriginalMeasureBase(
    staff.measures, division: division
)
```

The per-entry loop computes a delta to convert playback ticks
to original ticks:

```swift
let originalDelta = originalMeasureBase[entry.measureIndex] - entry.tickOffset
```

`renderVoiceElement`'s `.chord(chord)` arm overrides `velocity`
just before calling `renderChordWithGraces`:

```swift
let onsetOriginalTick = (localTick + adjust.onsetShift) + originalTickDelta
let chordVelocity =
    HairpinRamps.active(in: hairpinRamps, at: onsetOriginalTick)
        .map { HairpinRamps.interpolate(ramp: $0, atOriginalTick: onsetOriginalTick) }
    ?? velocity
```

The running `velocity` variable is **not** overwritten by the ramp
— hairpin influence is scoped to the chord onset. After the ramp
ends, the next `.dynamic(d)` (typically the bracket end Dynamic)
sets `velocity` normally, so post-ramp playback continues at the
expected level.

### Articulation interaction

`HairpinRamps.collect` runs each candidate Dynamic through
`MidiRenderer.effectiveVelocity(forDynamic:instrument:)` so
`startVelocity` / `endVelocity` are already articulation-scaled.
The interpolated value at chord onset is therefore directly
substitutable for the `velocity` argument of
`renderChordWithGraces`. Per-chord articulation gateTime is
unaffected; staccato within a hairpin still shortens duration.

## Test strategy

### Fixture (GPL-3.0, test-target only)

Bit-exact copies of upstream files into
`Tests/SheetMusicTests/Resources/`:

- `testSingleNoteDynamics.mscx`
- `testSingleNoteDynamics-ref.mid`

`Tests/SheetMusicTests/Resources/LICENSE` gets one line documenting
the new fixture's provenance, alongside the existing entries.

### Comparison helper

`MidiSemanticComparison.swift` gains an option:

```swift
struct MidiSemanticComparisonOptions {
    var ignoreTempoNoise: Bool = false
    /// Drop control-change events from both ref and actual before
    /// comparing. MuseScore's Single Note Dynamics emits CC11 etc.;
    /// this implementation only does note-on velocity ramps.
    var ignoreControlChange: Bool = false
}
```

Default `false` keeps every existing test unchanged.

### New tests

`HairpinMidiTests.swift` — one fixture-driven case using
`ignoreControlChange: true`:

```swift
@Suite struct HairpinMidiTests {
    @Test func testSingleNoteDynamics_velocityRamp() async throws {
        try await assertSemanticEquivalent(
            mscxName: "testSingleNoteDynamics",
            options: .init(ignoreControlChange: true)
        )
    }
}
```

`HairpinRampsTests.swift` — pure unit tests with hand-built `Score`
values:

1. Bracket Dynamic on both sides: `mp(~60) <[…]> f(~112)`
2. No bracket, explicit `<veloChange>=20`, cresc: end = start + 20
3. No bracket, no `<veloChange>`, cresc: end = start + 10
4. Decrescendo sign: `f(~112) >[…] p(~40)` produces decreasing ramp
5. End bracket Dynamic past the hairpin's end tick: still picked up
6. Two hairpins back-to-back: `mp <[…]> f >[…] p` produces two
   ramps with the middle Dynamic acting as both ends
7. `interpolate` midpoint, endpoints, single-tick spans
8. `ease-in` / `ease-out` / `ease-in-out` / `exponential` produce
   the same numeric output as `.normal` (locks v1 spec)

### Regression

`swift test` should grow from 48 to 49+ cases, all green. Existing
fixtures contain no `<HairPin>`, so behaviour outside the new
tests is unchanged.

## Implementation order (sketch)

1. `HairpinPayload` + `Spanner.hairpin` field, no decode/render
2. Decoder: `<HairPin>` subtags
3. Encoder: round-trip the same fields
4. `HairpinRamps` + unit tests (no integration yet)
5. `MidiRenderer+Voice` integration (chord onset velocity override)
6. Comparison helper option + fixture import
7. Fixture-driven test
8. Doc updates: `HairpinPayload` doc-comment future-work notes,
   `feature_gaps_checklist` memory entry update

## References

- MuseScore C++ — `mu::engraving::Hairpin` (engraving/dom/hairpin.h, .cpp)
- MuseScore C++ — `CompatMidiRender::renderHairpin` and
  velocity-multiplier logic in
  `engraving/compat/midi/compatmidirender.cpp`
- Upstream fixture — `src/importexport/midi/tests/midiexport_data/testSingleNoteDynamics.mscx`
- Project — `MidiRenderer+Voice.swift` Dynamic handling around
  the existing `case let .dynamic(dynamic):` arm
