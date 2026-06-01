# Custom Metronome Click — Phase 2 (Apple integration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Phase 1 Core (`WavPcmReader` + `ClickSoundFontBuilder` + the click-source seam) into `SheetMusicAudioApple` so the live `PlaybackEngine` and its offline audio export play a host-supplied click instead of the GM drum-kit — with `.defaultGM` / no-provider preserving today's behavior.

**Architecture:** A new `MetronomeClickResolver` (in `SheetMusicAudioApple`) turns a `MetronomeClickProvider`'s `MetronomeClickSource` into a concrete SoundFont URL: `.clickSamples` reads the WAV pair and builds an SF2 once (cached), `.soundFont` passes a host SF2 through, `.defaultGM` falls back to the existing `SoundfontResolver` drum-kit lookup. `PlaybackEngine` owns one resolver, uses it in `prepare(score:)` (handing the URL to the unchanged `MetronomeController.prepare(soundfontURL:)`), and captures the resolved URL in `ExportEngineSnapshot` so the export pipeline loads the same click. AUMIDISynth is unchanged — it already auto-selects the SF2's bank-128 percussion preset on MIDI channel 9.

**Tech Stack:** Swift, AVFoundation, Swift Testing. All new tests import `SheetMusicAudioApple` and are `#if !os(Android)`-gated.

**Spec:** `docs/superpowers/specs/2026-06-01-custom-metronome-click-design.md` (section "4. Apple integration").
**Depends on:** Phase 1 (merged into this branch): `WavPcmReader`, `ClickSoundFontBuilder`, `MetronomeClickSource`, `MetronomeClickProvider` in `SheetMusicAudioCore`.

**Working directory:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click` (branch `worktree-custom-metronome-click`). Run all commands from there. Do NOT `cd` to the main worktree.

**Pre-commit-hook note for every task:** the repo's SwiftLint `--fix` pre-commit hook can rewrite force-unwraps (`x!` → `x?` or `try #require`) and drop `@Suite`, which has broken committed code before. After each commit lands, RE-RUN the task's `swift test --filter ...` on the committed (post-hook) state and fix/re-commit if the hook broke compilation. Prefer `try #require(...)` over `!` in tests from the start.

---

## File Structure

New source file (Apple-only target `SheetMusicAudioApple`):
- `Sources/SheetMusicAudioApple/MetronomeClickResolver.swift` — resolves a click source to a SoundFont URL, builds + caches the SF2 for `.clickSamples`.

Modified source files:
- `Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift` — add `Hashable` (needed as a cache key).
- `Sources/SheetMusicAudioApple/PlaybackEngine.swift` — new optional init param, stored resolver, `prepare(score:)` uses it, `ExportEngineSnapshot` gains the resolved URL.
- `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift` — `buildMetronomeSampler` loads the snapshot's resolved URL.

New test files (in `SheetMusicTests`, all `#if !os(Android)`):
- `Tests/SheetMusicTests/Metronome/MetronomeClickResolverTests.swift`
- `Tests/SheetMusicTests/Metronome/MetronomeClickPlaybackTests.swift`

`SheetMusicAudioApple` / `SheetMusicAudio` are already test-target dependencies; no `Package.swift` change.

---

## Task 1: `MetronomeClickResolver` (+ make `MetronomeClickSource` Hashable)

**Files:**
- Modify: `Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift`
- Create: `Sources/SheetMusicAudioApple/MetronomeClickResolver.swift`
- Test: `Tests/SheetMusicTests/Metronome/MetronomeClickResolverTests.swift`

- [ ] **Step 1: Add `Hashable` to `MetronomeClickSource`**

In `Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift`, change the enum declaration line:

```swift
public enum MetronomeClickSource: Sendable, Equatable {
```
to:
```swift
public enum MetronomeClickSource: Sendable, Equatable, Hashable {
```

(All associated values are `URL`, which is `Hashable`, so synthesis works. `Equatable` is kept explicit for readability though `Hashable` refines it.)

- [ ] **Step 2: Write the failing resolver test**

Create `Tests/SheetMusicTests/Metronome/MetronomeClickResolverTests.swift`:

```swift
#if !os(Android)
@testable import SheetMusicAudioApple
@testable import SheetMusicAudioCore
import AVFoundation
import Foundation
import Testing

@Suite struct MetronomeClickResolverTests {
    // A SoundfontResolver whose drum-kit lookup and GM fallback return
    // known sentinel URLs so we can assert the .defaultGM path.
    private struct StubResolver: SoundfontResolver {
        let drumURL: URL?
        let gmURL: URL?
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
            isDrums ? drumURL : nil
        }
        var defaultGMSoundfontURL: URL? { gmURL }
    }

    private struct FixedProvider: MetronomeClickProvider {
        let source: MetronomeClickSource
        func metronomeClickSource() -> MetronomeClickSource { source }
    }

    /// Write a small 16-bit mono WAV to a temp file and return its URL.
    private func writeWav(_ samples: [Int16], rate: UInt32) throws -> URL {
        let data = WavTestSupport.pcm16(
            interleaved: samples, channels: 1, sampleRate: rate,
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("click-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    @Test func defaultGMReturnsDrumKitURL() {
        let drum = URL(fileURLWithPath: "/tmp/gm-drums.sf2")
        let resolver = MetronomeClickResolver(
            provider: nil,
            soundfontResolver: StubResolver(drumURL: drum, gmURL: nil),
        )
        #expect(resolver.resolvedSoundFontURL() == drum)
    }

    @Test func soundFontSourceReturnedVerbatim() {
        let sf2 = URL(fileURLWithPath: "/tmp/custom.sf2")
        let resolver = MetronomeClickResolver(
            provider: FixedProvider(source: .soundFont(sf2)),
            soundfontResolver: StubResolver(drumURL: nil, gmURL: nil),
        )
        #expect(resolver.resolvedSoundFontURL() == sf2)
    }

    @Test func clickSamplesGeneratesLoadablePlayableSF2() throws {
        // ±12000 square wave so there is real energy when rendered.
        let wave = (0 ..< 2205).map { Int16($0 % 2 == 0 ? 12000 : -12000) }
        let strong = try writeWav(wave, rate: 44100)
        let weak = try writeWav(wave, rate: 44100)
        defer {
            try? FileManager.default.removeItem(at: strong)
            try? FileManager.default.removeItem(at: weak)
        }
        let resolver = MetronomeClickResolver(
            provider: FixedProvider(source: .clickSamples(strong: strong, weak: weak)),
            soundfontResolver: StubResolver(drumURL: nil, gmURL: nil),
        )
        let url = try #require(resolver.resolvedSoundFontURL())
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Prove the generated SF2 actually plays note 76 on a real sampler.
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try sampler.loadSoundBankInstrument(
            at: url, program: 0,
            bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0,
        )
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        sampler.startNote(76, withVelocity: 100, onChannel: 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var peak: Float = 0
        for _ in 0 ..< 12 {
            if try engine.renderOffline(4096, to: buffer) == .success, let ch = buffer.floatChannelData {
                for i in 0 ..< Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) }
            }
        }
        engine.stop()
        engine.disableManualRenderingMode()
        #expect(peak > 0.0001)
    }

    @Test func clickSamplesCachesGeneratedFile() throws {
        let wave = [Int16](repeating: 5000, count: 100)
        let strong = try writeWav(wave, rate: 44100)
        let weak = try writeWav(wave, rate: 44100)
        defer {
            try? FileManager.default.removeItem(at: strong)
            try? FileManager.default.removeItem(at: weak)
        }
        let resolver = MetronomeClickResolver(
            provider: FixedProvider(source: .clickSamples(strong: strong, weak: weak)),
            soundfontResolver: StubResolver(drumURL: nil, gmURL: nil),
        )
        let first = try #require(resolver.resolvedSoundFontURL())
        let second = try #require(resolver.resolvedSoundFontURL())
        #expect(first == second)
    }

    @Test func clickSamplesFallsBackToGMOnBadWav() throws {
        let drum = URL(fileURLWithPath: "/tmp/gm-drums.sf2")
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).wav")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let resolver = MetronomeClickResolver(
            provider: FixedProvider(source: .clickSamples(strong: bad, weak: bad)),
            soundfontResolver: StubResolver(drumURL: drum, gmURL: nil),
        )
        #expect(resolver.resolvedSoundFontURL() == drum)
    }
}
#endif
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter MetronomeClickResolverTests`
Expected: FAIL — "cannot find 'MetronomeClickResolver' in scope" (and a Hashable-related success for Step 1's change).

- [ ] **Step 4: Implement `MetronomeClickResolver`**

Create `Sources/SheetMusicAudioApple/MetronomeClickResolver.swift`:

```swift
import Foundation
import SheetMusicAudioCore

/// Resolves a `MetronomeClickProvider`'s `MetronomeClickSource` into a
/// concrete SoundFont URL the metronome synth can load.
///
/// * `.clickSamples` — reads the WAV pair with `WavPcmReader`, builds an
///   SF2 with `ClickSoundFontBuilder`, writes it to the caches directory
///   once, and caches the generated URL keyed by the source so repeated
///   `prepare(score:)` / export calls reuse the same file.
/// * `.soundFont` — returns the host's SF2 URL verbatim.
/// * `.defaultGM` (or no provider) — falls back to the score's
///   `SoundfontResolver` drum-kit lookup, preserving the legacy behavior.
///
/// On any WAV-read / SF2-write failure for `.clickSamples`, falls back to
/// the `.defaultGM` URL so a bad click file degrades to the GM drum-kit
/// rather than failing score preparation (metronome load is non-fatal).
///
/// Used only from `PlaybackEngine` on the main actor, so it needs no
/// internal synchronization.
final class MetronomeClickResolver {
    private let provider: MetronomeClickProvider?
    private let soundfontResolver: SoundfontResolver
    private var generatedCache: [MetronomeClickSource: URL] = [:]

    init(provider: MetronomeClickProvider?, soundfontResolver: SoundfontResolver) {
        self.provider = provider
        self.soundfontResolver = soundfontResolver
    }

    /// The SoundFont URL the metronome should load, or `nil` when even the
    /// GM fallback is unavailable (host ships no SoundFont).
    func resolvedSoundFontURL() -> URL? {
        let source = provider?.metronomeClickSource() ?? .defaultGM
        switch source {
        case .defaultGM:
            return defaultGMURL()
        case let .soundFont(url):
            return url
        case let .clickSamples(strong, weak):
            if let cached = generatedCache[source] { return cached }
            guard let built = buildClickSoundFont(strong: strong, weak: weak) else {
                return defaultGMURL()
            }
            generatedCache[source] = built
            return built
        }
    }

    private func defaultGMURL() -> URL? {
        soundfontResolver.soundfontURL(forBank: 0, program: 0, isDrums: true)
            ?? soundfontResolver.defaultGMSoundfontURL
    }

    private func buildClickSoundFont(strong: URL, weak: URL) -> URL? {
        guard
            let strongPCM = try? WavPcmReader.read(contentsOf: strong),
            let weakPCM = try? WavPcmReader.read(contentsOf: weak)
        else { return nil }
        let sf2 = ClickSoundFontBuilder.build(
            strong: strongPCM.samples, strongRate: strongPCM.sampleRate,
            weak: weakPCM.samples, weakRate: weakPCM.sampleRate,
        )
        guard let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SheetMusicMetronomeClicks", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
        )
        let file = dir.appendingPathComponent("\(UUID().uuidString).sf2")
        guard (try? sf2.write(to: file)) != nil else { return nil }
        return file
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter MetronomeClickResolverTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit (verify branch first)**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click rev-parse --abbrev-ref HEAD   # must be worktree-custom-metronome-click
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click add Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift Sources/SheetMusicAudioApple/MetronomeClickResolver.swift Tests/SheetMusicTests/Metronome/MetronomeClickResolverTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click commit -m "feat(audio-apple): add metronome click resolver (WAV->SF2, cache, GM fallback)"
```

Then re-run `swift test --filter MetronomeClickResolverTests` on the committed state (pre-commit hook may have rewritten force-unwraps/`@Suite`); fix and re-commit if it broke.

---

## Task 2: Wire the resolver into `PlaybackEngine` (live + export)

**Files:**
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine.swift`
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`
- Test: `Tests/SheetMusicTests/Metronome/MetronomeClickPlaybackTests.swift`

- [ ] **Step 1: Write the failing integration test**

Create `Tests/SheetMusicTests/Metronome/MetronomeClickPlaybackTests.swift`:

```swift
#if !os(Android)
@testable import SheetMusicAudioApple
@testable import SheetMusicAudioCore
import AVFoundation
import Foundation
import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("Metronome click playback (Apple)")
@MainActor
struct MetronomeClickPlaybackTests {
    // Score synth stays silent; any energy in the export must be the
    // metronome click, proving the click SF2 reached the output.
    private struct SilentResolver: SoundfontResolver {
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? { nil }
        var defaultGMSoundfontURL: URL? { nil }
    }

    private struct FixedProvider: MetronomeClickProvider {
        let source: MetronomeClickSource
        func metronomeClickSource() -> MetronomeClickSource { source }
    }

    private func loadMidi01() throws -> Score {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        return try MSCXParser.parse(contentsOf: url)
    }

    private func writeClickWav() throws -> URL {
        let wave = (0 ..< 4410).map { Int16($0 % 2 == 0 ? 14000 : -14000) }
        let data = WavTestSupport.pcm16(interleaved: wave, channels: 1, sampleRate: 44100)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("click-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func peakOfWav(at url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length),
        ))
        try file.read(into: buffer)
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for c in 0 ..< Int(format.channelCount) {
                for i in 0 ..< Int(buffer.frameLength) { peak = max(peak, abs(data[c][i])) }
            }
        }
        return peak
    }

    @Test("custom click is audible in export while the score is silent")
    func clickAudibleInExport() async throws {
        let score = try loadMidi01()
        let click = try writeClickWav()
        defer { try? FileManager.default.removeItem(at: click) }

        let engine = PlaybackEngine(
            soundfontResolver: SilentResolver(),
            metronomeClickProvider: FixedProvider(
                source: .clickSamples(strong: click, weak: click),
            ),
        )
        try engine.prepare(score: score)
        engine.setMetronomeEnabled(true)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("metro-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        try await engine.exportAudioFile(
            to: out, score: score,
            format: .wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo)),
        )

        let peak = try peakOfWav(at: out)
        #expect(peak > 0.0001)
    }

    @Test("no provider keeps the engine working (backward compatible)")
    func noProviderStillPrepares() throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        // Should not throw; metronome resolves to the (nil) GM fallback.
        try engine.prepare(score: score)
        #expect(engine.state == .stopped)
    }
}
#endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "Metronome click playback"`
Expected: FAIL to compile — `PlaybackEngine.init` has no `metronomeClickProvider:` parameter yet.

- [ ] **Step 3: Add the init param + stored resolver in `PlaybackEngine.swift`**

Find the stored property (around line 28):
```swift
    private let resolver: SoundfontResolver
```
Add immediately after it:
```swift
    /// Resolves the metronome's click sound (host WAVs → SF2, host SF2,
    /// or the GM drum-kit fallback). See `MetronomeClickResolver`.
    private let clickResolver: MetronomeClickResolver
```

Find the initializer:
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
Replace it with:
```swift
    public init(
        soundfontResolver: SoundfontResolver,
        metronomeClickProvider: MetronomeClickProvider? = nil,
    ) {
        resolver = soundfontResolver
        clickResolver = MetronomeClickResolver(
            provider: metronomeClickProvider,
            soundfontResolver: soundfontResolver,
        )
        // The metronome joins the master stage at `sumMixer` (post-gain,
        // pre-limiter) so it is limited along with the boosted score but
        // is not itself boosted by the master gain.
        metronome = MetronomeController(engine: engine, output: sumMixer)
        buildMasterChain()
    }
```

- [ ] **Step 4: Use the resolver in `prepare(score:)`**

In `PlaybackEngine.swift`, find the metronome-URL block inside `prepare(score:)`:
```swift
        // Metronome always plays GM percussion (hi/low wood block on
        // notes 76 / 77). Ask the resolver for the drum kit at
        // (bank: 0, program: 0, isDrums: true) so a host that doesn't
        // ship a full GM SoundFont can still serve the metronome from
        // a per-(bank, program) split file. Falls back to the GM URL
        // for hosts that haven't moved over.
        let metronomeURL =
            resolver.soundfontURL(forBank: 0, program: 0, isDrums: true)
            ?? resolver.defaultGMSoundfontURL
        metronome.prepare(soundfontURL: metronomeURL)
```
Replace it with:
```swift
        // Resolve the metronome's SoundFont through the click provider:
        // `.clickSamples` builds an SF2 from the host's WAVs, `.soundFont`
        // uses a host SF2, and `.defaultGM` (or no provider) falls back to
        // the GM drum-kit (notes 76 / 77). AUMIDISynth loads it unchanged.
        metronome.prepare(soundfontURL: clickResolver.resolvedSoundFontURL())
```

- [ ] **Step 5: Add the resolved URL to `ExportEngineSnapshot`**

In `PlaybackEngine.swift`, find the snapshot struct:
```swift
    struct ExportEngineSnapshot {
        let resolver: SoundfontResolver
        let mixerChannels: [MixerChannel]
        let metronomeEnabled: Bool
        let metronomeVolume: Float
        let rate: Float
        let metronomeBeats: [MetronomeBeat]
        /// Linear amplitude multiplier captured from
        /// `PlaybackEngine.masterGain`, so the export engine rebuilds
        /// the master stage at the same gain the user hears live.
        let masterGain: Float // swiftlint:disable:this inclusive_language
    }
```
Add a field for the resolved metronome SoundFont URL:
```swift
    struct ExportEngineSnapshot {
        let resolver: SoundfontResolver
        let mixerChannels: [MixerChannel]
        let metronomeEnabled: Bool
        let metronomeVolume: Float
        let rate: Float
        let metronomeBeats: [MetronomeBeat]
        /// Linear amplitude multiplier captured from
        /// `PlaybackEngine.masterGain`, so the export engine rebuilds
        /// the master stage at the same gain the user hears live.
        let masterGain: Float // swiftlint:disable:this inclusive_language
        /// Resolved metronome SoundFont URL (host click SF2, host SF2, or
        /// GM drum-kit), so the export plays the same click as live.
        let metronomeSoundFontURL: URL?
    }
```

Find `exportEngineSnapshot()`:
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
Replace it with (add the new argument):
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
            metronomeSoundFontURL: clickResolver.resolvedSoundFontURL(),
        )
    }
```

- [ ] **Step 6: Use the snapshot URL in `PlaybackEngine+Export.swift`**

Find `buildMetronomeSampler`:
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
        try? MIDISynthBuilder.loadSoundFont(
            into: s, url: metroURL,
            bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
        )
        s.volume = snapshot.metronomeVolume
        return s
    }
```
Replace it with (drop the now-unused `resolver` parameter, read the URL from the snapshot):
```swift
    private static func buildMetronomeSampler(
        snapshot: ExportEngineSnapshot,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> AVAudioUnitMIDIInstrument? {
        guard snapshot.metronomeEnabled,
              let metroURL = snapshot.metronomeSoundFontURL
        else { return nil }
        let s = MIDISynthBuilder.make()
        engine.attach(s)
        engine.connect(s, to: output, format: nil)
        try? MIDISynthBuilder.loadSoundFont(
            into: s, url: metroURL,
            bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
        )
        s.volume = snapshot.metronomeVolume
        return s
    }
```

Find the call site in `buildExportPipeline`:
```swift
        // 2. Optional metronome synth / track.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, resolver: resolver, engine: engine,
            output: sumMixer,
        )
```
Replace it with:
```swift
        // 2. Optional metronome synth / track.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, engine: engine, output: sumMixer,
        )
```

- [ ] **Step 7: Run the integration test to verify it passes**

Run: `swift test --filter "Metronome click playback"`
Expected: PASS (2 tests). `clickAudibleInExport` proves the metronome click reaches the offline-rendered output through AUMIDISynth (channel 9 → bank 128); `noProviderStillPrepares` proves backward compatibility.

- [ ] **Step 8: Run the existing PlaybackEngine / export suites to confirm no regression**

Run: `swift test --filter PlaybackEngine`
then: `swift test --filter AudioFileExporter`
Expected: PASS. The new init param is defaulted, so existing call sites (`PlaybackEngine(soundfontResolver:)`) are unchanged, and the export path still builds the metronome sampler — now from the snapshot URL.

- [ ] **Step 9: Commit (verify branch first)**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click rev-parse --abbrev-ref HEAD   # worktree-custom-metronome-click
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click add Sources/SheetMusicAudioApple/PlaybackEngine.swift Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift Tests/SheetMusicTests/Metronome/MetronomeClickPlaybackTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click commit -m "feat(audio-apple): play custom metronome click in PlaybackEngine live + export"
```

Then re-run `swift test --filter "Metronome click playback"` on the committed state (post-hook) and fix/re-commit if the hook broke anything.

---

## Task 3: Full-suite green + Android-shape check

- [ ] **Step 1: Run the whole suite**

Run: `swift test`
Expected: PASS (the prior full run was 1508 tests + 1 pre-existing known issue; expect that plus the new Metronome-resolver/playback tests).

- [ ] **Step 2: Verify the Android manifest shape still resolves**

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe`
Expected: succeeds. `MetronomeClickResolver` and the `PlaybackEngine` changes live in `SheetMusicAudioApple`, which is excluded from the Android build, and the only `SheetMusicAudioCore` change is the additive `Hashable` conformance — so the Android shape is unaffected.

- [ ] **Step 3: Lint (if available)**

Run: `swiftlint --quiet Sources/SheetMusicAudioApple Sources/SheetMusicAudioCore/Metronome Tests/SheetMusicTests/Metronome`
Expected: no NEW warnings introduced by this phase (pre-existing warnings in unrelated files are out of scope).

- [ ] **Step 4: No commit needed** — verification only. If lint/suite surface fixes, commit them with `style:` / `fix:`.

---

## Self-Review

**Spec coverage (Apple-integration section of the spec):**
- `.clickSamples` → WAV read + SF2 build + cache → URL → `MetronomeController.prepare(soundfontURL:)` (AUMIDISynth unchanged) → Task 1 + Task 2 Steps 3–4. ✓
- `.soundFont` passthrough and `.defaultGM` fallback (and no-provider == defaultGM) → Task 1 resolver + tests. ✓
- Export reflects the same click via `ExportEngineSnapshot.metronomeSoundFontURL` → Task 2 Steps 5–6 + integration test. ✓
- Backward compatibility (no provider → current GM behavior, existing call sites unchanged) → defaulted init param + `noProviderStillPrepares` + Step 8 regression run. ✓
- Caching of the generated SF2 → resolver `generatedCache` + `clickSamplesCachesGeneratedFile`. ✓

**Placeholder scan:** none — every step has concrete code/edits and exact commands.

**Type consistency:** `MetronomeClickResolver(provider:soundfontResolver:)` and `.resolvedSoundFontURL() -> URL?` are used identically in the tests, `PlaybackEngine.init`, `prepare(score:)`, and `exportEngineSnapshot()`. `ExportEngineSnapshot.metronomeSoundFontURL` is added in Step 5 and consumed in Step 6. `buildMetronomeSampler`'s signature change (dropping `resolver:`) is matched at its only call site (Step 6). `MetronomeClickSource` gains `Hashable` (Step 1) which the resolver's `generatedCache` dictionary key requires. The Phase 1 `WavPcmReader.Result.samples/sampleRate` and `ClickSoundFontBuilder.build(strong:strongRate:weak:weakRate:)` are consumed exactly as defined.

**Note for the implementer:** `clickAudibleInExport` depends on AUMIDISynth auto-selecting the SF2's bank-128 preset on MIDI channel 9 — the same mechanism the existing GM metronome relies on. If that test renders silence, do NOT weaken it: first confirm the metronome is enabled in the snapshot and the resolved URL is non-nil; report BLOCKED with findings if the click genuinely won't sound through AUMIDISynth (that would be a real integration finding, distinct from the Task-1 AUSampler proof which already passed).
