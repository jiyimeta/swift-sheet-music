# Master Output Gain + Peak Limiter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a master output gain (linear `0.0...3.0`, default `1.0`) with a brick-wall peak limiter on the master bus of `SheetMusicAudioApple.PlaybackEngine`, so a consumer can boost quietly-authored scores past CC-7's ceiling without clipping, in both live playback and offline audio-file export.

**Architecture:** Insert a three-node master stage into the `AVAudioEngine` graph: `scoreSynth → scoreGainMixer (outputVolume = gain) → sumMixer → limiter → mainMixerNode`. The metronome joins `sumMixer` so the final mix is limited but *not* boosted. The stage is built once in `init` and reused across every `prepare(score:)`, so `masterGain` persists across score reloads. The offline export pipeline rebuilds the identical chain on its dedicated engine.

**Tech Stack:** Swift 6, AVFoundation (`AVAudioEngine`, `AVAudioMixerNode`, `AVAudioUnitEffect` / `kAudioUnitSubType_PeakLimiter`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-05-28-master-output-gain-limiter-design.md`

**Working directory:** This plan executes in the worktree at `.claude/worktrees/master-output-gain` on branch `feature/master-output-gain`. All `swift` commands run from that directory.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Sources/SheetMusicAudioApple/PlaybackEngine.swift` | Engine state + lifecycle | Modify: add 3 master-stage node properties + `masterGain`; build chain in `init`; route synth to `scoreGainMixer`; add `masterGain` to export snapshot |
| `Sources/SheetMusicAudioApple/PlaybackEngine+Master.swift` | Master-gain API + chain builder + limiter factory | **Create** |
| `Sources/SheetMusicAudioApple/MetronomeController.swift` | Metronome synth ownership | Modify: connect sampler to an injected output node instead of `mainMixerNode` |
| `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift` | Offline export pipeline | Modify: rebuild the master chain on the export engine; route export synth + metronome through it |
| `Tests/SheetMusicTests/PlaybackEngineMasterGainTests.swift` | Master-gain unit tests | **Create** |
| `Tests/SheetMusicTests/AudioFileExporterTests.swift` | Export integration tests | Modify: add one export-with-gain smoke test |

---

## Task 1: Live-engine master stage + `setMasterGain` API

Adds the three-node master chain to the live engine, the public `setMasterGain` / `masterGain` API, and rewires the metronome to feed the sum mixer. This is one cohesive unit: a partial chain would leave dangling nodes or break `prepare(score:)`, so all graph edits land together.

**Files:**
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine.swift`
- Create: `Sources/SheetMusicAudioApple/PlaybackEngine+Master.swift`
- Modify: `Sources/SheetMusicAudioApple/MetronomeController.swift`
- Test: `Tests/SheetMusicTests/PlaybackEngineMasterGainTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/PlaybackEngineMasterGainTests.swift`:

```swift
#if !os(Android)
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// Unit tests for `PlaybackEngine`'s master output gain. These do
    /// not exercise audio output — they verify the public clamping
    /// contract, that the clamped value reaches the underlying mixer
    /// node, and that the value survives `prepare(score:)`. Audible
    /// limiter behavior is verified in the Mac example app with a real
    /// GM soundfont (CI has no audio device).
    @Suite("PlaybackEngine master gain")
    @MainActor
    struct PlaybackEngineMasterGainTests {
        @Test("defaults to unity gain")
        func defaultsToUnity() {
            let engine = PlaybackEngine(soundfontResolver: NullResolver())
            #expect(engine.masterGain == 1.0)
            #expect(engine.scoreGainMixerOutputVolume == 1.0)
        }

        @Test("setMasterGain clamps to 0...3 and reaches the node")
        func clampsAndApplies() {
            let engine = PlaybackEngine(soundfontResolver: NullResolver())

            engine.setMasterGain(1.5)
            #expect(engine.masterGain == 1.5)
            #expect(engine.scoreGainMixerOutputVolume == 1.5)

            engine.setMasterGain(5) // above ceiling
            #expect(engine.masterGain == 3.0)
            #expect(engine.scoreGainMixerOutputVolume == 3.0)

            engine.setMasterGain(-1) // below floor
            #expect(engine.masterGain == 0.0)
            #expect(engine.scoreGainMixerOutputVolume == 0.0)
        }

        @Test("master gain persists across prepare(score:)")
        func persistsAcrossPrepare() throws {
            let part = Part(
                id: "p",
                instrument: Instrument(
                    id: "i",
                    channels: [InstrumentChannel(program: 0)],
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let score = Score(division: 480, parts: [part])
            let engine = PlaybackEngine(soundfontResolver: NullResolver())

            engine.setMasterGain(2.0)
            try engine.prepare(score: score)

            #expect(engine.masterGain == 2.0)
            #expect(engine.scoreGainMixerOutputVolume == 2.0)
            #expect(engine.synth != nil)
        }
    }

    private struct NullResolver: SoundfontResolver {
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
```

- [ ] **Step 2: Run the test to verify it fails (does not compile)**

Run: `swift test --filter PlaybackEngineMasterGainTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `value of type 'PlaybackEngine' has no member 'masterGain'` / `'setMasterGain'` / `'scoreGainMixerOutputVolume'`.

- [ ] **Step 3: Add the master-stage stored properties to `PlaybackEngine`**

In `Sources/SheetMusicAudioApple/PlaybackEngine.swift`, immediately after the `synth` property block (the `var synth: AVAudioUnitMIDIInstrument?` declaration around line 33), insert:

```swift
    /// Master output stage. The score synth feeds `scoreGainMixer`,
    /// whose `outputVolume` is the user's master gain (`0...3`). Its
    /// output is summed with the metronome at `sumMixer`, brick-walled
    /// by `limiter`, then routed into `mainMixerNode`. Built once in
    /// `init` and reused across every `prepare(score:)`, so `masterGain`
    /// survives score reloads. `internal` so the `+Master` / `+Export`
    /// extensions in sibling files can reach the nodes directly.
    let scoreGainMixer = AVAudioMixerNode()
    let sumMixer = AVAudioMixerNode()
    let limiter = PlaybackEngine.makePeakLimiter()

    /// Linear amplitude multiplier applied to the full mix, post
    /// per-channel mixing. `1.0` = unity. Clamped to `0...3` by
    /// `setMasterGain`. Setter is module-internal so the `+Master`
    /// extension (a different file) can mirror the clamped value here.
    public internal(set) var masterGain: Float = 1.0
```

- [ ] **Step 4: Build the master chain in `init` and feed the metronome from `sumMixer`**

In `Sources/SheetMusicAudioApple/PlaybackEngine.swift`, replace the initializer:

```swift
    public init(soundfontResolver: SoundfontResolver) {
        resolver = soundfontResolver
        metronome = MetronomeController(engine: engine)
    }
```

with:

```swift
    public init(soundfontResolver: SoundfontResolver) {
        resolver = soundfontResolver
        // The metronome joins the master stage at `sumMixer` (post-gain,
        // pre-limiter) so it is limited along with the boosted score but
        // is not itself boosted by the master gain.
        metronome = MetronomeController(engine: engine, output: sumMixer)
        buildMasterChain()
    }
```

(`sumMixer` is an inline-initialized stored property, so it is available before the `init` body runs; `buildMasterChain()` is called last, once every stored property is initialized.)

- [ ] **Step 5: Route the score synth through the master stage**

In `Sources/SheetMusicAudioApple/PlaybackEngine.swift`, inside `prepareSynth(score:)`, change the synth's output connection from `mainMixerNode` to `scoreGainMixer`:

```swift
        let instrument = MIDISynthBuilder.make()
        engine.attach(instrument)
        engine.connect(
            instrument, to: scoreGainMixer, format: nil,
        )
```

(The teardown branch in `prepare(score:)` / `teardown()` calls `engine.disconnectNodeOutput(oldSynth)`, which works regardless of the destination — no change needed there.)

- [ ] **Step 6: Create the `+Master` extension**

Create `Sources/SheetMusicAudioApple/PlaybackEngine+Master.swift`:

```swift
import AudioToolbox
import AVFoundation
import Foundation

extension PlaybackEngine {
    /// Set the master output gain — a linear amplitude multiplier
    /// applied to the full mix after per-channel mixing. `1.0` is unity
    /// (bit-for-bit unchanged); the value is clamped to `0.0...3.0`
    /// (300%). Idempotent and cheap, so it is safe to call on every
    /// frame of a slider drag. Persists across `prepare(score:)`.
    public func setMasterGain(_ gain: Float) {
        let clamped = max(0, min(3, gain))
        masterGain = clamped
        scoreGainMixer.outputVolume = clamped
    }

    /// Attach the master output stage and wire it once:
    /// `scoreGainMixer → sumMixer → limiter → mainMixerNode`. The score
    /// synth is connected to `scoreGainMixer` in `prepareSynth`; the
    /// metronome sampler connects to `sumMixer` from
    /// `MetronomeController`. Called from `init`, so the chain — and
    /// therefore `masterGain` — outlives every `prepare(score:)`.
    func buildMasterChain() {
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(limiter)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = masterGain
    }

    /// Build a brick-wall peak limiter (`kAudioUnitSubType_PeakLimiter`,
    /// Apple). Default attack / decay / pre-gain are transparent below
    /// full-scale, so the limiter only engages once the master gain
    /// pushes the summed signal past 0 dBFS.
    static func makePeakLimiter() -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0,
        )
        return AVAudioUnitEffect(audioComponentDescription: description)
    }

    /// Test-only read-back of the gain actually applied to the audio
    /// node, distinct from the `masterGain` stored mirror.
    var scoreGainMixerOutputVolume: Float {
        scoreGainMixer.outputVolume
    }
}
```

- [ ] **Step 7: Update `MetronomeController` to connect to an injected output node**

In `Sources/SheetMusicAudioApple/MetronomeController.swift`, add the stored output node next to the existing `engine` property:

```swift
    private let engine: AVAudioEngine
    private let output: AVAudioNode
```

Replace the initializer:

```swift
    init(engine: AVAudioEngine) {
        self.engine = engine
    }
```

with:

```swift
    init(engine: AVAudioEngine, output: AVAudioNode) {
        self.engine = engine
        self.output = output
    }
```

In `prepare(soundfontURL:)`, change the sampler's output connection from `engine.mainMixerNode` to the injected `output`:

```swift
        let instrument = sampler ?? {
            let s = MIDISynthBuilder.make()
            engine.attach(s)
            engine.connect(s, to: output, format: nil)
            s.volume = volume
            self.sampler = s
            return s
        }()
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter PlaybackEngineMasterGainTests 2>&1 | tail -20`
Expected: PASS — `Test run with 3 tests ... passed`.

- [ ] **Step 9: Run the existing PlaybackEngine tests to confirm no regression**

Run: `swift test --filter PlaybackEngine 2>&1 | tail -10`
Expected: PASS — all suites green (the prepare / loop-wrap / export integration suites must still pass with the rewired graph).

- [ ] **Step 10: Commit**

```bash
git add Sources/SheetMusicAudioApple/PlaybackEngine.swift \
        Sources/SheetMusicAudioApple/PlaybackEngine+Master.swift \
        Sources/SheetMusicAudioApple/MetronomeController.swift \
        Tests/SheetMusicTests/PlaybackEngineMasterGainTests.swift
git commit -m "feat(audio): master output gain + peak limiter on live engine

Add setMasterGain(_:) / masterGain to PlaybackEngine. Score synth now
routes through scoreGainMixer (outputVolume = gain, 0...3) -> sumMixer
-> PeakLimiter -> mainMixerNode; the metronome joins sumMixer so the
final mix is limited but not boosted. The chain is built once in init
so masterGain persists across prepare(score:).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Export-pipeline parity

Rebuild the identical master stage on the dedicated offline-export engine so exported files match live playback. Adds `masterGain` to the export snapshot and routes the export synth + metronome through the chain.

**Files:**
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine.swift` (`ExportEngineSnapshot` + `exportEngineSnapshot()`)
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`
- Test: `Tests/SheetMusicTests/AudioFileExporterTests.swift`

- [ ] **Step 1: Write the failing test**

In `Tests/SheetMusicTests/AudioFileExporterTests.swift`, add this test inside the existing `PlaybackEngineExportTests` suite (after `wavSmoke`, before the closing `}` of the suite). It reuses the file-private `SilentResolver` and `loadMidi01()` helpers already defined in that file:

```swift
        @Test("export with master gain set produces a readable file")
        func exportWithMasterGain() async throws {
            let score = try loadMidi01()
            let engine = PlaybackEngine(soundfontResolver: SilentResolver())
            try engine.prepare(score: score)
            engine.setMasterGain(2.0)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            try await engine.exportAudioFile(
                to: url,
                score: score,
                format: .wav(PCMOptions(sampleRate: 22050, bitDepth: .int16, channels: .stereo)),
            )

            let file = try AVAudioFile(forReading: url)
            #expect(file.length > 0)
            #expect(engine.state == .stopped)
        }
```

- [ ] **Step 2: Run the test to verify it passes-but-bypasses-the-chain (baseline behavior)**

Run: `swift test --filter "export with master gain" 2>&1 | tail -15`
Expected: PASS. This test passes even before the export-pipeline change (the export currently ignores master gain but still renders a valid silent file). It is a *smoke guard*: it must keep passing after the chain is added, proving the rewired export pipeline still renders without crashing. The audible boost itself is verified in the example app, not here. Proceed to wire the chain.

- [ ] **Step 3: Add `masterGain` to the export snapshot**

In `Sources/SheetMusicAudioApple/PlaybackEngine.swift`, add a field to `ExportEngineSnapshot`:

```swift
    struct ExportEngineSnapshot {
        let resolver: SoundfontResolver
        let mixerChannels: [MixerChannel]
        let metronomeEnabled: Bool
        let metronomeVolume: Float
        let rate: Float
        let metronomeBeats: [MetronomeBeat]
        let masterGain: Float
    }
```

and populate it in `exportEngineSnapshot()`:

```swift
    func exportEngineSnapshot() -> ExportEngineSnapshot {
        ExportEngineSnapshot(
            resolver: resolver,
            mixerChannels: mixerChannels,
            metronomeEnabled: metronome.isEnabled,
            metronomeVolume: metronome.volume,
            rate: pendingRate,
            metronomeBeats: metronomeBeats,
            masterGain: masterGain,
        )
    }
```

- [ ] **Step 4: Build the master chain in the export pipeline**

In `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`, in `buildExportPipeline(...)`, replace the opening of the function body (the `let engine = AVAudioEngine()` / `let resolver = ...` lines through the `// 1. Build the score synth.` block) with:

```swift
        let engine = AVAudioEngine()
        let resolver = snapshot.resolver

        // Master output stage — mirrors the live engine
        // (PlaybackEngine.buildMasterChain). Rebuilt here on the export
        // engine so exported files reflect the live master gain.
        let scoreGainMixer = AVAudioMixerNode()
        let sumMixer = AVAudioMixerNode()
        let limiter = makePeakLimiter()
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(limiter)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = snapshot.masterGain

        // 1. Build the score synth (routed through the master stage).
        let exportSynth = buildScoreSynth(
            score: score, snapshot: snapshot, resolver: resolver,
            engine: engine, output: scoreGainMixer,
        )
```

Then update the metronome-build call (the `// 2. Optional metronome synth / track.` block) to route through `sumMixer`:

```swift
        // 2. Optional metronome synth / track.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, resolver: resolver, engine: engine,
            output: sumMixer,
        )
```

- [ ] **Step 5: Thread the output node through `buildScoreSynth` and `buildMetronomeSampler`**

In `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`, change `buildScoreSynth`'s signature and its synth connection:

```swift
    private static func buildScoreSynth(
        score: Score,
        snapshot: ExportEngineSnapshot,
        resolver: SoundfontResolver,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> ScoreSynth {
        let instrument = MIDISynthBuilder.make()
        engine.attach(instrument)
        engine.connect(
            instrument, to: output, format: nil,
        )
```

(the rest of `buildScoreSynth` is unchanged).

Change `buildMetronomeSampler`'s signature and its sampler connection:

```swift
    private static func buildMetronomeSampler(
        snapshot: ExportEngineSnapshot,
        resolver: SoundfontResolver,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> AVAudioUnitMIDIInstrument? {
        guard snapshot.metronomeEnabled,
              let metroURL = resolver.soundfontURL(
                  forBank: 0, program: 0, isDrums: true,
              ) ?? resolver.defaultGMSoundfontURL
        else { return nil }
        let s = MIDISynthBuilder.make()
        engine.attach(s)
        engine.connect(s, to: output, format: nil)
```

(the rest of `buildMetronomeSampler` is unchanged).

- [ ] **Step 6: Run the export test to verify it still passes with the chain wired**

Run: `swift test --filter "export with master gain" 2>&1 | tail -15`
Expected: PASS — `file.length > 0`, `engine.state == .stopped`.

- [ ] **Step 7: Run all export integration tests to confirm no regression**

Run: `swift test --filter PlaybackEngineExportTests 2>&1 | tail -15`
Expected: PASS — WAV / AIFF / M4A round-trips, range narrowing, error and cancellation cases all green.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicAudioApple/PlaybackEngine.swift \
        Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "feat(audio): apply master gain + limiter in offline export

Snapshot masterGain into ExportEngineSnapshot and rebuild the
scoreGainMixer -> sumMixer -> PeakLimiter -> mainMixerNode chain on the
dedicated export engine, routing the export synth and metronome through
it. Exported files now match live playback at the chosen master gain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Full verification

Confirm the whole package builds, the entire suite is green, and lint is clean.

**Files:** none (verification only).

- [ ] **Step 1: Full clean build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | tail -15`
Expected: all tests pass, 0 failures (per CLAUDE.md, the suite must be 100% green).

- [ ] **Step 3: Lint**

Run: `swiftlint --quiet Sources Tests 2>&1 | tail -20`
Expected: no output (0 warnings / 0 errors). If `swiftlint` is not installed, skip this step and note it.

- [ ] **Step 4: Confirm the Android cross-compile manifest is unaffected**

This change touches only Apple-only files (`SheetMusicAudioApple`) and an Apple-gated test (`#if !os(Android)`), so no `Package.swift` change is required. Sanity-check that the new test file is gated:

Run: `head -1 Tests/SheetMusicTests/PlaybackEngineMasterGainTests.swift`
Expected: `#if !os(Android)`

(No Android build is run here — the new code is never compiled on Android.)

- [ ] **Step 5: Report completion**

Summarize: API added (`setMasterGain(_:)` / `masterGain`), live + export graphs rewired, N tests passing, lint clean. Flag the remaining manual step: **audible verification in `SheetMusicExampleMac`** with a real GM soundfont — confirm (a) unity gain is unchanged vs. `main`, (b) gain `> 1.0` is audibly louder, (c) a loud passage at `3.0` does not hard-clip (limiter engages), (d) the metronome is limited but not boosted by master gain. This cannot run in CI (no audio device).

---

## Notes for the implementer

- **Why a separate `scoreGainMixer` *and* `sumMixer`:** `AVAudioMixerNode.outputVolume` is the only graph property that accepts values `> 1.0` (per-connection `AVAudioMixing.volume` caps at `1.0`), so the boost must live on a mixer's `outputVolume`. That mixer must carry *only* the score (or the metronome would be boosted too), and the limiter is a single-input effect — so a second mixer is needed to sum boosted-score + metronome before the limiter. Do not try to collapse these into one node.
- **Float equality in tests is intentional and safe:** the test gains (`1.5`, `3.0`, `0.0`, `2.0`) are exact in IEEE-754 `Float`, and `clamp` + node round-trip preserve them exactly. No tolerance needed.
- **Persistence is by construction, not by code:** `prepare(score:)` deliberately does **not** touch `scoreGainMixer.outputVolume` or `masterGain`. The chain is built once in `init` and never rebuilt, so the value simply survives. Do not add a reset.
- **`makePeakLimiter()` is a `static func` on `PlaybackEngine`** (defined in `+Master.swift`); it is referenced both from the `limiter` property initializer in `PlaybackEngine.swift` (`PlaybackEngine.makePeakLimiter()`) and unqualified from `buildExportPipeline` in `+Export.swift` (`makePeakLimiter()`). Both resolve to the same method.
