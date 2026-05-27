# Master output gain + peak limiter (Apple/AVFoundation backend)

**Date:** 2026-05-28
**Target:** `SheetMusicAudioApple.PlaybackEngine`
**Requested by:** the Folino app (a consumer of `swift-sheet-music`)

## Problem

Folino wants a **per-score master volume**, adjustable up to ~300%, to
compensate for soundfonts / scores that play back too quietly even at
maximum per-staff volume.

The existing per-staff volume control routes through **MIDI CC 7
(Channel Volume, 0–127)**: `setVolume(forChannel:to:)` maps `0…1` to
CC 7 `0…127` and sends it per MIDI channel
(`PlaybackEngine+Mixer.swift`, `applyStaffGain(at:gain:)`). CC 7 hard-caps
at 127, so a quietly-authored score (or a low-output soundfont) has no
headroom left once the per-staff slider tops out. Exceeding the authored
loudness requires a **real audio-domain gain (> 1.0) on the master bus**,
applied *after* per-channel synth mixing. That stage only exists inside
the engine's `AVAudioEngine` graph.

A naive boost would clip when the summed signal crosses full-scale, so a
**peak limiter** sits after the gain. The accepted trade-off (chosen by
Folino) is "loud without clipping" — mild dynamics coloration on
already-loud content is acceptable; hard clipping is not.

## Current graph

Live engine (`PlaybackEngine.prepareSynth`, `MetronomeController.prepare`):

```
scoreSynth        ─→ mainMixerNode ─→ outputNode
metronomeSampler  ─→ mainMixerNode
```

Both the multi-timbral score synth (AUMIDISynth) and the metronome's own
sampler connect straight to `mainMixerNode`. Per-channel volume is MIDI
CC 7 into the score synth; the metronome has its own node-level
`sampler.volume`.

The **offline export** path (`PlaybackEngine+Export.swift`) builds a
*separate* `AVAudioEngine` per `exportAudioFile(...)` call and
deliberately reproduces live engine state (volume / mute / solo,
per-staff programs, metronome on/off, rate). There too, both synths
connect to `mainMixerNode`.

## Design

### Node topology (live engine)

```
scoreSynth ──→ scoreGainMixer ──┐
              (outputVolume=gain) │
                                  ├─→ sumMixer ─→ limiter ─→ mainMixerNode ─→ outputNode
metronomeSampler ─────────────────┘             (PeakLimiter)
```

- **`scoreGainMixer`** (`AVAudioMixerNode`) — carries *only* the score
  synth. Its `outputVolume` **is** the master gain.
  `AVAudioMixerNode.outputVolume` accepts values `> 1.0`, unlike a
  per-connection `AVAudioMixing.volume` (documented `0.0…1.0`), which is
  why a dedicated mixer node is required rather than boosting the synth's
  input bus.
- **`sumMixer`** (`AVAudioMixerNode`) — sums boosted-score + metronome.
  Required because the limiter is a single-input effect; the metronome
  (unboosted) joins here so it is **limited but not boosted**.
- **`limiter`** (`AVAudioUnitEffect` wrapping
  `kAudioUnitSubType_PeakLimiter`, Apple manufacturer) — always in-graph,
  default params. At unity gain with sub-full-scale content it does not
  engage, so it is transparent. It is the last stage before
  `mainMixerNode`, so the final mix (score + metronome) never clips.

Three nodes are added. They are attached and interconnected **once**
(`scoreGainMixer → sumMixer → limiter → mainMixerNode`); only `scoreSynth`
is connected / disconnected to `scoreGainMixer` across `prepare(score:)`.

### Why this topology (alternatives rejected)

- *Single master mixer carrying score + metronome:* a 3× master boost
  would also make the metronome 3× louder. Rejected — the user expects a
  master boost to lift the music, not blast the click.
- *Metronome bypasses the master stage (straight to `mainMixerNode`):*
  simplest graph, but a metronome downbeat summed onto a boosted+limited
  score can cross full-scale and clip, partially defeating "loud without
  clipping." Rejected.
- *Boost the synth's input bus into the sum mixer:* `AVAudioMixing.volume`
  caps at 1.0, so it cannot reach 3.0. Rejected.

### API

```swift
/// Linear amplitude multiplier applied to the full mix, post
/// per-channel mixing. 1.0 = unity (no change). Clamped to 0.0...3.0.
/// Default 1.0. Idempotent — safe to call repeatedly during a slider
/// drag.
@MainActor public func setMasterGain(_ gain: Float)

/// Current master gain (post-clamp). Readable for SwiftUI binding;
/// `@Observable` updates fire on change.
@MainActor public private(set) var masterGain: Float
```

`setMasterGain` clamps to `0.0...3.0`, stores `masterGain`, and assigns
`scoreGainMixer.outputVolume`. Linear amplitude (not dB, not a `0…1`
fraction) so the consumer maps "300%" → `3.0` directly.

### Lifecycle / persistence

`scoreGainMixer` is built once at `init` and is **not** rebuilt by
`prepare(score:)`. Therefore `masterGain` **persists across score
reloads** — matching the handoff's stated preference. `prepare(score:)`
does **not** reset it to 1.0. Folino stores the value per-score and
re-applies it on load; that re-apply is idempotent and harmless whether
or not the value persisted.

(Note: this differs from per-staff volumes, which `rebuildMixerChannels`
*does* reset on each `prepare` because they are re-derived from the
score's CC 7 defaults. Master gain has no score-derived default, so
persisting is the natural and lower-code behavior.)

### Export parity

`ExportEngineSnapshot` gains a `masterGain: Float` field, populated by
`exportEngineSnapshot()` from the live `masterGain`.
`buildExportPipeline` rebuilds the same
`scoreGainMixer → sumMixer → limiter → mainMixerNode` chain on the
dedicated export engine and routes the export synth through
`scoreGainMixer` and the export metronome sampler through `sumMixer`.
Result: exported WAV / AIFF / M4A / MP3 match live playback — bit-for-bit
identical at unity gain, and reflecting the boost above it.

### Limiter parameters

`kAudioUnitSubType_PeakLimiter` defaults (attack / decay / pre-gain) are
used as-is. Not exposed to the consumer — Folino does not need to tune
them. Revisit only if the defaults prove audibly poor in the example app.

## Touched files

- **`PlaybackEngine.swift`**
  - Add 4 stored properties: `scoreGainMixer` (`AVAudioMixerNode`),
    `sumMixer` (`AVAudioMixerNode`), `limiter` (`AVAudioUnitEffect`),
    and `masterGain: Float = 1.0` (`public private(set)`).
  - In `init`: build + attach + connect the master chain
    (`scoreGainMixer → sumMixer → limiter → mainMixerNode`) before
    creating the `MetronomeController`, and create the metronome with the
    `sumMixer` as its output node.
  - In `prepareSynth`: connect `instrument` to `scoreGainMixer` instead
    of `mainMixerNode`. The teardown branch already disconnects the old
    synth output (works unchanged regardless of destination).
  - In `teardown`: disconnect the synth (unchanged); the master-chain
    nodes stay attached for the engine's lifetime (they are lightweight
    and reused by the next `prepare`).
  - Add `masterGain` to `ExportEngineSnapshot` and `exportEngineSnapshot()`.
- **New `PlaybackEngine+Master.swift`**
  - `setMasterGain(_:)`.
  - A `buildMasterChain()` helper called from `init` (attaches and
    connects the three nodes to `mainMixerNode`).
  - A limiter factory (a `MIDISynthBuilder`-style `static func` building
    the `AVAudioUnitEffect` from the `PeakLimiter` component description).
  - An internal accessor returning `scoreGainMixer.outputVolume` for the
    test target.
- **`MetronomeController.swift`**
  - `init(engine:output:)` — store the passed-in destination
    `AVAudioNode`.
  - `prepare(soundfontURL:)` connects the sampler to that output node
    instead of `engine.mainMixerNode`.
- **`PlaybackEngine+Export.swift`**
  - Build the same master chain on the export engine.
  - Route `exportSynth` → `scoreGainMixer`, metronome sampler →
    `sumMixer`, `sumMixer → limiter → mainMixerNode`.
  - Set `scoreGainMixer.outputVolume = snapshot.masterGain`.

## Tests

`Tests/SheetMusicTests/PlaybackEngineMasterGainTests.swift` — Swift
Testing (`@Test` / `#expect`), wrapped in `#if !os(Android)` (it
`@testable import`s the Apple-only `SheetMusicAudioApple`). Uses the
existing `NullResolver` pattern (no real soundfont, no audio output):

- **Clamping:** `setMasterGain(5)` → `masterGain == 3`;
  `setMasterGain(-1)` → `masterGain == 0`; `setMasterGain(1.5)` →
  `masterGain == 1.5`.
- **Value reaches the node:** after `setMasterGain(2.0)`, the internal
  `scoreGainMixer.outputVolume` accessor returns `2.0`.
- **Persistence:** set `2.0`, call `prepare(score:)` a second time,
  expect `masterGain` still `2.0`.
- **Smoke:** `prepare(score:)` with `NullResolver` builds the chain and
  completes without crashing; default `masterGain == 1.0`.

These do not exercise audio output. The limiter's *audible* behavior
(transparency at unity, brick-wall at boost) is verified in the
`SheetMusicExampleMac` example app with a real GM soundfont, per project
convention — CI has no real audio device.

## Out of scope

- Tuning / exposing limiter parameters.
- A dB-domain API (consumer maps percentage → linear directly).
- Android (`AndroidPlaybackEngine`) — this is the Apple backend only.
- Any change to per-staff CC 7 volume semantics.

## Consumer integration (Folino, informational)

Folino adds `setMasterGain(_:)` to its Domain `PlaybackController`
protocol and calls the new engine API from `LivePlaybackController`
(Infrastructure adapter). Value is linear `Float` (`1.0` unchanged, `3.0`
= 300%). On the version bump, Folino updates both `Package.swift` and
`project.yml` `from:`.
