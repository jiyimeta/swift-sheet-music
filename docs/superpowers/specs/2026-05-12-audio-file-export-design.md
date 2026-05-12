# Audio File Export — Design

Status: brainstormed 2026-05-12.

## Goal

Add an offline audio-file rendering API to `SheetMusicAudio` so host
apps can export a `Score` to a sound file. Mandatory format coverage:
**WAV, AIFF, M4A (AAC), MP3**. The format and its codec-specific
options (sample rate, bit depth, channels, bit rate) must be selectable
from app code via a typed enum. The exported audio reflects the live
`PlaybackEngine` state — mixer (volume / mute / solo), program changes,
metronome on/off, and playback rate — so the host's "export what I
hear" button is honest.

## Non-goals (v1)

- **Per-staff stem export** (one file per staff/part). Mix-down only.
- **Surround / >2 channels.** Mono and stereo only.
- **Hardware acceleration / real-time-faster-than-1× streaming.** We
  use `AVAudioEngine.enableManualRenderingMode(.offline, ...)` which is
  already CPU-bound but no special tuning beyond "don't drop frames".
- **Standalone exporter that does not need a `PlaybackEngine`.** The
  user opted explicitly for "reflect current playback state", so the
  API hangs off `PlaybackEngine`. A pure score → file API can be added
  later if a host requires it.
- **Lossless compression (FLAC, ALAC).** Out of scope for v1.
- **Custom AU effects between sampler and writer.** The graph stays
  `sampler(s) → mainMixerNode → writer`.

## Library placement

All new code lives under
`Sources/SheetMusicAudio/Export/`:

```
Sources/SheetMusicAudio/Export/
  AudioFileFormat.swift       — format enum + options structs
  AudioExportRange.swift      — range enum
  AudioExportError.swift      — Error type
  AudioFileExporter.swift     — offline-render engine driver
PlaybackEngine+Export.swift   — public method `exportAudioFile(...)`
```

Splitting `PlaybackEngine.swift` is required: it is already 729 lines
(over the 300-line SwiftLint cap, currently `swiftlint:disable` at the
file head). The export method goes into a new
`PlaybackEngine+Export.swift` extension file; the heavy lifting lives
in a separate `AudioFileExporter` actor so the export pipeline can be
reasoned about independently of the existing playback state machine.

No new product, no `Package.swift` change. Same min-platform
(`iOS 16 / macOS 13 / tvOS 16 / watchOS 9`); MP3 path is `@available`-
gated for iOS 17 / macOS 14 / tvOS 17 / watchOS 10.

## Public API

### `AudioFileFormat`

```swift
public enum AudioFileFormat: Sendable {
    case wav(PCMOptions = .init())
    case aiff(PCMOptions = .init())
    case m4a(CompressedOptions = .init())
    case mp3(CompressedOptions = .init())
}
```

Associated-value form gives compile-time guarantees that PCM-only
fields (bit depth) and compressed-only fields (bit rate) cannot be
mixed. Bare `.wav` / `.aiff` / `.m4a` / `.mp3` work in switches because
each case has a default-initialised payload.

### Options structs

```swift
public enum PCMBitDepth: Sendable, CaseIterable {
    case int16, int24, int32, float32
}

public enum AudioChannelCount: Int, Sendable, CaseIterable {
    case mono = 1
    case stereo = 2
}

public struct PCMOptions: Sendable {
    public var sampleRate: Double
    public var bitDepth: PCMBitDepth
    public var channels: AudioChannelCount

    public init(
        sampleRate: Double = 44_100,
        bitDepth: PCMBitDepth = .int16,
        channels: AudioChannelCount = .stereo
    ) { ... }
}

public struct CompressedOptions: Sendable {
    public var sampleRate: Double
    public var bitRate: Int          // bits per second
    public var channels: AudioChannelCount

    public init(
        sampleRate: Double = 44_100,
        bitRate: Int = 192_000,
        channels: AudioChannelCount = .stereo
    ) { ... }
}
```

### Range

```swift
public enum AudioExportRange: Sendable {
    case full
    case currentLoop   // PlaybackEngine.loopRange; falls back to .full when nil
    case region(from: ScoreCursor, to: ScoreCursor)
    case regionThroughEnd(from: ScoreCursor, last: ScoreItemID)
}
```

### `PlaybackEngine.exportAudioFile(...)`

```swift
extension PlaybackEngine {
    /// Offline-render the current score to an audio file at `url`.
    ///
    /// Reflects the live state of this engine: mixer (volume / mute /
    /// solo), per-staff program changes, metronome on/off, and the
    /// current playback rate. `prepare(score:)` must have been called
    /// for the supplied `score`; otherwise throws `.noScorePrepared`.
    ///
    /// While the export is running the engine is in
    /// `AVAudioEngine` manual-rendering mode, so normal playback is
    /// suspended (`state == .exporting`). On completion / failure /
    /// cancellation the engine is restored and `state` returns to
    /// `.stopped`.
    ///
    /// - parameter url: Destination file. Overwritten if it exists.
    /// - parameter score: The score that was prepared.
    /// - parameter format: Container + codec choice; carries its own
    ///   sample rate / bit depth / channels / bit rate options.
    /// - parameter range: What region to render (default: `.full`).
    /// - parameter progress: Optional 0.0…1.0 callback, invoked on
    ///   the main actor at ~30 Hz. Final tick may exceed 1.0
    ///   slightly when the last buffer overshoots; clamp on read.
    /// - throws: `AudioExportError`, or `CancellationError` (via
    ///   `Task.checkCancellation`).
    public func exportAudioFile(
        to url: URL,
        score: Score,
        format: AudioFileFormat,
        range: AudioExportRange = .full,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws
}
```

### Error type

```swift
public enum AudioExportError: Error, Sendable, Equatable {
    case noScorePrepared
    case rangeNotInTimeline
    case formatUnsupportedOnThisOS(AudioFileFormat)
    case engineSetupFailed(underlying: String)
    case fileWriteFailed(underlying: String)
    case cancelled
}
```

`underlying` is a `String` rather than `Error` so the enum stays
`Equatable` / `Sendable` cheaply. The underlying `NSError` description
is rendered into the string at throw time.

### `PlaybackState` extension

```swift
public enum PlaybackState: Sendable, Equatable {
    case stopped, playing, paused, exporting   // .exporting is new
}
```

Existing playback methods (`play`, `pause`, `seek`, `setRate`, the
`setLoop` overloads, `clearLoop`, `playPreview`) gain an explicit
`guard state != .exporting else { return }` at the top. Behaviour is a
silent no-op; the host's UI is responsible for disabling the buttons.

Calling `prepare(score:)` while exporting cancels the export
implicitly (via the `Task` the host should have stored), then proceeds
with the prepare. Callers who do not hold a reference to the export
`Task` see the export finish on its old score before the new one is
loaded — acceptable, and documented.

### Picker integration (host pattern)

Associated-value enums do not bind directly to `SwiftUI.Picker`. The
recommended host pattern is a small tag enum + separate options state,
documented in the SheetMusicAudio README:

```swift
enum FormatTag: String, CaseIterable, Identifiable {
    case wav, aiff, m4a, mp3
    var id: Self { self }
}

@State private var tag: FormatTag = .wav
@State private var pcm = PCMOptions()
@State private var comp = CompressedOptions()

private var format: AudioFileFormat {
    switch tag {
    case .wav: .wav(pcm)
    case .aiff: .aiff(pcm)
    case .m4a: .m4a(comp)
    case .mp3: .mp3(comp)
    }
}
```

## Implementation outline

### Rendering loop

`AudioFileExporter` is an `actor` that owns the offline-render
session. Steps inside `export(...)`:

1. Resolve the tick range from `AudioExportRange` against the
   engine's `PlaybackTimeline`. Throw `.rangeNotInTimeline` when the
   cursors don't map.
2. Compute total render frames:
   `frames = ceil((endSec - startSec) × outSampleRate)`.
   Use the timeline's tempo-aware `frame(atTime:)`; do not divide by
   rate (we want output duration, not score-internal duration).
3. Stop normal playback, capture the engine's pre-export state:
   `engine.isRunning`, `sequencer`, mixer levels, audio session.
   (Mixer state is already applied to the sampler nodes, so we only
   need to remember "was the engine running" for restore.)
4. Pause the sequencer (`sequencer?.stop()`), pause the engine
   (`engine.pause()`).
5. Configure manual rendering:
   ```swift
   let outFmt = AVAudioFormat(
       commonFormat: .pcmFormatFloat32,
       sampleRate: outSampleRate,
       channels: outChannels,
       interleaved: false
   )!
   try engine.enableManualRenderingMode(
       .offline, format: outFmt, maximumFrameCount: 4096
   )
   try engine.start()
   ```
6. Build the sequencer for this score if not already built, set
   `currentPositionInBeats` to the range start, set
   `sequencer.rate = pendingRate`, call `sequencer.prepareToPlay()`
   and `sequencer.start()`.
7. Loop: allocate `AVAudioPCMBuffer` (frameCapacity = 4096), call
   `engine.renderOffline(_:to:)`, write the buffer to the writer.
   After each successful write:
   - update `framesWritten`
   - debounce the `progress` callback (every ~33 ms)
   - `try Task.checkCancellation()`
8. On clean exit:
   - close the writer
   - stop the sequencer, stop the engine
   - `engine.disableManualRenderingMode()`
   - restart engine if it was running before
   - set `state = .stopped`
9. On thrown error / cancellation: same teardown, plus delete the
   partial file at `url`. Re-throw the original error.

### Writer back-ends

| Format        | Back-end                            | Notes                                                                                           |
|---------------|-------------------------------------|-------------------------------------------------------------------------------------------------|
| `.wav`        | `AVAudioFile(forWriting:settings:)` | File type inferred from URL extension. Settings: `AVFormatIDKey = kAudioFormatLinearPCM` plus bit-depth keys (see table below). |
| `.aiff`       | `AVAudioFile(forWriting:settings:)` | URL extension `.aiff` (int variants) or `.aifc` (float32). Same PCM settings keys as `.wav`. Implementation chooses extension automatically based on `bitDepth`. |
| `.m4a`        | `AVAudioFile(forWriting:settings:)` | `AVFormatIDKey = kAudioFormatMPEG4AAC`, `AVEncoderBitRateKey = bitRate`.                       |
| `.mp3`        | `AVAssetWriter` + `AVAssetWriterInput` (audio) | `@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)`. `AVFileType.mp3`, AAC-style settings dict. Throw `.formatUnsupportedOnThisOS` outside availability. |

`AVAudioFile.write(from:)` accepts a float32 buffer and converts via
its internal `AVAudioConverter` (we never instantiate one manually).
For the `AVAssetWriter` (mp3) path we wrap the float32 buffer as a
`CMSampleBuffer` and append via the writer input.

A small protocol `AudioExportWriter` (file-private, not public) hides
the writer choice from the rendering loop:

```swift
private protocol AudioExportWriter {
    func write(_ buffer: AVAudioPCMBuffer) async throws
    func finish() async throws
}
```

### Bit depth → settings dict mapping

| `PCMBitDepth` | `AVLinearPCMBitDepthKey` | `AVLinearPCMIsFloatKey` |
|---------------|--------------------------|--------------------------|
| `.int16`      | 16                       | false                    |
| `.int24`      | 24                       | false                    |
| `.int32`      | 32                       | false                    |
| `.float32`    | 32                       | true                     |

AIFF picks `kAudioFileAIFCType` automatically for the `.float32` row.

### Progress accounting

```swift
let total = Double(framesToRender)
let now = Double(framesWritten)
let p = max(0, min(1, now / total))
```

Called from inside the actor; the callback hop to MainActor happens
via `await MainActor.run { progress(p) }`. Debounced at 33 ms by
comparing `CACurrentMediaTime()` against a `lastEmittedAt` field.

## Test plan

`Tests/SheetMusicAudioTests/Export/` (new sub-directory):

1. **Type tests** — `AudioFileFormat`, options structs, range enum
   sendability and default-init correctness. Plain `@Test` cases.
2. **WAV smoke test** — load `midi01.mscx`, prepare engine with a
   stub `SoundfontResolver` (returns nil → silent samplers are fine
   for "did we write the right format"), export to `.wav`, reopen
   with `AVAudioFile(forReading:)`, assert sample rate / channels /
   bit depth match and `frameLength > 0`.
3. **AIFF smoke test** — same shape as WAV.
4. **M4A smoke test** — export, reopen, assert
   `processingFormat.formatDescription`'s `kAudioFormatMPEG4AAC` ID.
5. **MP3 smoke test** — same shape as M4A; gated by
   `if #available(iOS 17, macOS 14, *)`.
6. **Range narrowing** — `.region(from:to:)` produces a shorter file
   than `.full` (tolerance: ±50 ms; SF2-free silent render is exact
   on PCM but tolerance keeps tempo curves honest).
7. **Cancellation** — start export inside `Task`, `task.cancel()`
   immediately, await: expect `AudioExportError.cancelled` or
   `CancellationError`, assert output file does **not** exist on
   disk.
8. **Error paths** — export before `prepare` → `.noScorePrepared`;
   bad cursor → `.rangeNotInTimeline`.

Fixtures: existing `midi01.mscx` only. No new audio fixtures (we
don't byte-compare audio output — only metadata and existence).

Example apps (`Example/SheetMusicExample` iOS + Mac): a new
"Export audio…" sheet with a `FormatTag` picker, options form, save
dialog, progress bar, cancel button. This is the listening-by-ear
verification path documented in the README.

## CLAUDE.md update

Done as the final commit of the implementation, not inside this spec.
The update brings the file in line with the current `Package.swift`:

1. **Library layout** section: rewrite the dependency diagram to
   reflect the 10 library products (`SheetMusicCore`, `MSCX`,
   `MusicXML`, `MIDI`, `Audio`, `Layout`, `UI`, `PDF`, plus the
   internal `XMLTools` target and the `render-previews` executable).
2. **File layout** section: add the `SheetMusicAudio/Export/`
   sub-tree from this spec.
3. **Conventions**: add `SheetMusicAudio/Export/*` to the
   "one responsibility per file" example list, alongside the
   existing `MidiRenderer.swift` split.
4. **Recurring pitfalls**: add a one-paragraph entry —
   "`AVAudioFile` writes WAV/AIFF/M4A natively via the settings
   dict; only MP3 needs `AVAssetWriter`. Don't reach for
   `AVAssetWriter` for the others."
5. **Things not to do**: unchanged. The MIT/GPL boundary, the
   trademark constraint, and the flat re-export pattern all stay.

## Open questions

None at the time of writing. Defaults committed:

- Default sample rate: 44_100 Hz (CD-standard; iOS hardware native
  is 48 kHz but the converter handles the resample transparently).
- Default channels: stereo.
- Default PCM bit depth: 16-bit int (smallest reasonable WAV, what
  most consumer tools expect).
- Default compressed bit rate: 192 kbps (a sensible "transparent"
  AAC/MP3 floor).
- Existing-file behaviour: overwrite.
- Progress emission: ~30 Hz on MainActor.
- Cancellation cleanup: delete partial file.
