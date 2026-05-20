# Android audio file export — design (Phase 5 sub-project B)

Status: design ready, plan pending.

Worktree: `worktree-android-audio-export`. Branched from local `main` HEAD (`04600b8`).

## Goal

Bring Apple parity audio file export to Android:
`AndroidPlaybackEngine.exportAudioFile(...)` writes the prepared score to
WAV / AIFF / M4A / MP3 via offline FluidSynth render, mirroring Apple
`PlaybackEngine.exportAudioFile(...)`'s structure, snapshot model, and
error surface.

Out of scope (Phase 5+ follow-ups): surround / multi-channel export,
ID3v2 / iTunes metadata, concurrent live + export mode, Maven Central
publication.

## Architecture overview

```
Apple-only (existing)                Cross-platform (NEW shared)         Android-only (NEW)
─────────────────────                ────────────────────────────         ──────────────────
PlaybackEngine.exportAudioFile()     SheetMusicAudioCore/                 AndroidPlaybackEngine
  └─ AudioFileExporter (actor)          Export/AudioExportRange+              .exportAudioFile()
      └─ AVAudioEngine.renderOffline    Resolve.swift                          └─ AudioExporter
      └─ AVAudioFile/AVAssetWriter        resolveTickRange(timeline:loop:)         ├─ dedicated FluidSynth
                                          resolveCursorTick(_:in:)                 │   + PlayerDriver
                                                                                   ├─ RenderLoop
                                     SheetMusicAndroidJNI/                         └─ AudioFileEncoder
                                       Audio/AudioExportRangeJNI.swift                  ├─ WavPcmEncoder
                                       (@_cdecl nativeResolveExportTickRange)           ├─ AiffPcmEncoder
                                                                                        ├─ AacM4aEncoder
                                                                                        └─ Mp3MediaCodecEncoder
```

### Code sharing

Apple's `PlaybackEngine+Export.swift` currently owns `resolveRange(_:timeline:loop:)`
and `resolveCursorTick(_:in:)`. Both are Foundation-only, depend only on
`PlaybackTimeline` + `LoopRange`, and apply unchanged on Android. They
move to `SheetMusicAudioCore/Export/AudioExportRange+Resolve.swift` as
a public extension method on `AudioExportRange`:

```swift
extension AudioExportRange {
    public func resolveTickRange(
        timeline: PlaybackTimeline,
        loop: LoopRange?,
    ) throws -> (startTick: Int, endTick: Int)
}
```

The Apple call site changes to:

```swift
let (startTick, endTick) = try range.resolveTickRange(
    timeline: timeline, loop: loopRange,
)
```

The Android side reaches it through a new JNI seam.

### New Swift code

- `Sources/SheetMusicAudioCore/Export/AudioExportRange+Resolve.swift` — moved
  range resolver. Public surface.
- `Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNI.swift` — new
  `@_cdecl` symbol that decodes a serialized `AudioExportRange` from a
  `jbyteArray`, resolves it against the score handle's timeline, returns
  `LongArray[startTick, endTick]`. Returns `[-1, -1]` on resolution failure
  (Kotlin maps to `RangeNotInTimeline`).
- `Sources/SheetMusicAndroidJNI/Audio/AudioExportRangeJNICodec.swift` —
  Swift-side decoder for the same wire format that Kotlin writes. Existing
  `BinaryReader` helper is reused.

### New Kotlin code

`Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/`:

- `model/AudioFileFormat.kt` — sealed interface mirroring Swift
  `AudioFileFormat` (Wav / Aiff / M4a / Mp3 cases), plus value classes
  `PcmOptions(sampleRate, bitDepth, channels)` and
  `CompressedOptions(sampleRate, bitRate, channels)` and enums
  `PcmBitDepth { Int16, Int24, Int32, Float32 }` and
  `AudioChannelCount { Mono, Stereo }`.
- `model/AudioExportRange.kt` — sealed interface mirroring the Swift enum.
- `serialization/AudioExportRangeEncoder.kt` — Kotlin → wire bytes.
- `export/AudioExporter.kt` — orchestrator (internal class).
- `export/AudioFileEncoder.kt` — encoder interface + `create(format, sampleRate, fd)`.
- `export/WavPcmEncoder.kt`, `AiffPcmEncoder.kt`, `AacM4aEncoder.kt`,
  `Mp3MediaCodecEncoder.kt` — four concrete encoders.
- `AudioBackendException.kt` — five new subclasses (NoScorePrepared,
  RangeNotInTimeline, FormatUnsupportedOnThisOS, FileWriteFailed, Cancelled);
  existing `EngineSetupFailed` is reused.

`AndroidPlaybackEngine.exportAudioFile(...)` is added as a new public
`suspend fun` on the existing class. Existing `PlaybackState.EXPORTING`
already gates every mutating API as no-op during export (Phase 5
sub-project A landed this).

## Public Android API

```kotlin
suspend fun exportAudioFile(
    outputFd: ParcelFileDescriptor,
    scoreHandle: Long,
    format: AudioFileFormat,
    range: AudioExportRange = AudioExportRange.Full,
    progress: ((Float) -> Unit)? = null,
)
```

- `outputFd` ownership stays with the caller. The exporter wraps a local
  `FileOutputStream(fd.fileDescriptor)` for the file write but does not
  close the `ParcelFileDescriptor` itself.
- `scoreHandle` must match the score handle most recently passed to
  `prepare(...)`; otherwise throws `NoScorePrepared`.
- `range` default is `Full`. `CurrentLoop` falls back to `Full` if no
  loop is set.
- `progress` is invoked at ~33 ms intervals on the calling coroutine's
  dispatcher with a value in `[0, 1]`. Always emits `1.0` on success.
- Cancellation: cancelling the calling coroutine aborts the render at the
  next buffer boundary and throws `Cancelled`. The partial file at
  `outputFd` is left intact; the caller decides whether to delete it.
- Concurrency: a private `exportMutex: Mutex` serializes export calls.
  Concurrent invocations queue rather than fail.

## AudioExportRange wire format

Tag byte at offset 0; case-specific payload follows:

| Tag | Case               | Payload (using existing codec helpers)                     |
|-----|--------------------|------------------------------------------------------------|
| `0` | `Full`             | (none)                                                     |
| `1` | `CurrentLoop`      | (none)                                                     |
| `2` | `Region`           | `ScoreCursorCodec.encode(from)` + `ScoreCursorCodec.encode(to)` |
| `3` | `RegionThroughEnd` | `ScoreCursorCodec.encode(from)` + `ScoreItemIDCodec.encode(last)` |

Both sides use the existing `BinaryWriter` / `BinaryReader` LE format
from `Sources/SheetMusicAndroidJNI/Serialization/` and the matching
Kotlin `serialization/` package.

## Render loop

`AudioExporter.run(...)` (internal, in `Android/SheetMusicAudioAndroid/.../export/`):

```kotlin
suspend fun run(
    outputFd: ParcelFileDescriptor,
    smfBytes: ByteArray,
    staffParams: List<StaffParams>,
    snapshot: ExportEngineSnapshot,
    startTick: Long,
    endTick: Long,
    ticksPerBeat: Int,
    format: AudioFileFormat,
    sampleRate: Int,
    progress: ((Float) -> Unit)?,
)
```

Flow:

1. **Build dedicated engine.** Fresh `SynthDriver` via `synthFactory(sampleRate)`,
   load the GM SF2 once, apply per-staff program selection from `snapshot`,
   apply mixer (CC7 / mute / solo translated to effective gain) — same
   logic as `FluidSynthEngine.setupStaves` / mixer apply, extracted to a
   shared helper used by both live + export.
2. **Build dedicated player.** Fresh `PlayerDriver` bound to the dedicated
   synth's `nativeHandle`. `playerAddMem(smfBytes)`, `setTempo(snapshot.rate)`,
   `seekTick(startTick)`, `play()`.
3. **Build encoder.** `AudioFileEncoder.create(format, sampleRate, outputFd)`.
   MP3 encoder's `create` may throw `FormatUnsupportedOnThisOS` if the
   device has no MP3 encoder.
4. **Pump loop.** While `player.currentTick < endTick` and the coroutine
   is still active:
   - `synth.writeFloat(BUFFER_FRAMES, left, right)` — pulls samples; the
     FluidSynth player scheduler advances by the same `BUFFER_FRAMES`
     internally (consumer-pull time model, no wall-clock dependency).
   - `encoder.appendPcmFloat(left, right, frames)`.
   - Emit progress at ≥33 ms intervals.
5. **Finish + teardown.** `encoder.finish()`, `player.close()`,
   `synth.close()`. All teardown happens in `finally` so cancellation and
   failure both clean up.

`BUFFER_FRAMES = 4096` (parity with Apple's `AudioFileExporter.bufferFrames`).

### ExportEngineSnapshot

```kotlin
internal data class ExportEngineSnapshot(
    val mixerChannels: List<MixerChannel>,
    val metronomeEnabled: Boolean,
    val metronomeVolume: Float,
    val metronomeBeats: List<MetronomeBeat>,
    val rate: Float,
)
```

Captured once at the top of `exportAudioFile`. The live engine continues
to hold the same state (export does not mutate live state). When the
metronome is enabled, the SMF is re-rendered to include the metronome
track (mirror of `MetronomeController.metronomeTrack(...)` on Apple).

### FluidSynth offline render verification

Plan task T0 is a spike: confirm on emulator that calling
`fluid_synth_write_float` repeatedly with no Oboe attached advances the
player by exactly N frames per call (sample-pull time, no wall-clock
dependency). If this assumption fails, the plan pivots to either:
- attaching a virtual / silent Oboe stream, or
- switching to FluidSynth's `fluid_file_renderer` for WAV/AIFF and
  keeping MediaCodec for M4A/MP3.

The pivot is a strategy decision, not tactical; the plan author surfaces
this to the user rather than picking unilaterally (see memory:
[[subagent-no-unilateral-pivot]]).

## Encoders

`AudioFileEncoder` (interface):

```kotlin
internal interface AudioFileEncoder : AutoCloseable {
    fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int)
    fun finish()
    companion object {
        fun create(
            format: AudioFileFormat, sampleRate: Int, fd: ParcelFileDescriptor,
        ): AudioFileEncoder
    }
}
```

### WavPcmEncoder

- Pure Kotlin. `RandomAccessFile(fd.fileDescriptor, "rw")` for backfill
  of size fields.
- Header: RIFF + WAVE + `fmt ` (16-byte for int, 18-byte for float
  `WAVE_FORMAT_IEEE_FLOAT`) + `data` chunk.
- bitDepth: int16 / int24 / int32 / float32. Float → int conversion
  with clipping: `(x * 32767.0f).coerceIn(-32768f, 32767f).toInt()` for
  int16, analogous for int24 / int32.
- Little-endian via `ByteBuffer.order(ByteOrder.LITTLE_ENDIAN)`.
- `finish()` writes the final `RIFF size` and `data size` via
  `RandomAccessFile.seek(...)`.

### AiffPcmEncoder

- Pure Kotlin. AIFF (int) or AIFC (float32) based on `PCMOptions.bitDepth`.
- Big-endian.
- Header: FORM (AIFF / AIFC) + COMM (channels, numFrames, sampleSize,
  80-bit IEEE 754 extended-precision sample rate) + SSND chunk. The
  80-bit float encoding is a fixed routine (sign / exponent / mantissa
  layout) of ~30 lines.
- For AIFC float, the COMM chunk also carries the `fl32` compression
  type code + pascal-string compression name.
- `finish()` backfills FORM size, COMM `numFrames`, SSND chunk size.
- Note: caller passes a `.aiff`-suffixed URI. The encoder writes valid
  AIFF or AIFC bytes regardless of the URI's extension; the demo's
  SAF file naming chooses `.aifc` when float32 is selected (mirror of
  Apple's `PCMAudioExportWriter.resolveURL`).

### AacM4aEncoder

- `MediaCodec.createEncoderByType("audio/mp4a-latm")` configured with
  `MediaFormat`: sample rate, channel count, bit rate from
  `CompressedOptions`, `AACObjectLC` profile.
- `MediaMuxer(fd, OutputFormat.MUXER_OUTPUT_MPEG_4)`.
- Lifecycle:
  1. `mediaCodec.configure(format, null, null, CONFIGURE_FLAG_ENCODE)`,
     `mediaCodec.start()`.
  2. `appendPcmFloat`: convert float → int16 interleaved, push to
     `dequeueInputBuffer` / `queueInputBuffer` (with timestamp computed
     from accumulated frames).
  3. Drain `dequeueOutputBuffer`; the first non-data output is
     `INFO_OUTPUT_FORMAT_CHANGED` — `muxer.addTrack(format)` and
     `muxer.start()`. Subsequent outputs go to `muxer.writeSampleData`.
  4. `finish()`: send EOS flag, drain remaining output, `muxer.stop()`,
     `muxer.release()`, `mediaCodec.stop()`, `mediaCodec.release()`.
- `presentationTimeUs = accumulatedFrames * 1_000_000L / sampleRate`.

### Mp3MediaCodecEncoder

- `MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(mp3Format)`.
  If null → constructor throws `FormatUnsupportedOnThisOS(AudioFileFormat.Mp3(...))`.
- If found: `MediaCodec.createByCodecName(name)`.
- MP3 is *not* a container supported by `MediaMuxer.OutputFormat.*` —
  the encoder's output buffers contain MPEG frame-aligned byte streams.
  Write directly to `FileOutputStream(fd.fileDescriptor)`. No ID3v2
  tag (v0 spec; follow-up).
- Same float → int16 conversion + presentationTimeUs cadence as M4A.

### Shared helpers (private)

`AudioFileEncoder.kt` private file-scope helpers:
- `floatToInt16(left, right, frames, mono): ShortArray` — clipping + interleave.
- `floatToInt24` / `floatToInt32` — analogous for the WAV PCM variants.
- `floatToFloat32LE` / `floatToFloat32BE` — float32 round-trip for
  WAV (LE) / AIFC (BE).

`finish()` of every encoder calls `os.flush()` + `fos.fd.sync()` to
ensure bytes reach the underlying SAF stream before the function returns.

## Compose demo integration

Adds an Export button to the existing audio controls strip in
`Examples/Android/app/src/main/java/com/example/sheetmusic/`:

- `export/ExportFormatOption.kt` — `enum class FormatChoice(displayName, mime, extension)`:
  `Wav`, `Aiff`, `M4a`, `Mp3`. Maps to `AudioFileFormat` factory.
- Format picker `AlertDialog` with 4 radio rows.
- SAF `CreateDocument(mime)` `ActivityResultContract` per selected format.
- `ExportState`: `Idle` / `Running(progress: Float)` / `Done(uri: Uri)` /
  `Failed(message: String)`.
- Progress dialog with `LinearProgressIndicator(progress)` + Cancel button.
- Cancel: `exportJob?.cancel()` → coroutine throws `CancellationException`
  → exporter cleans up → demo deletes the partial file via
  `contentResolver.delete(uri, null, null)`.
- Done: Snackbar "Exported to <filename>" + Share action.

`AudioFileFormat` is an associated-value sealed type in Kotlin (mirroring
the Swift enum). The picker uses the tag-only `FormatChoice` enum because
associated-value sealed types don't play well as radio-row tags — same
rationale Apple's `AudioFileFormat` doc comment cites for SwiftUI Picker.

## Testing strategy

### Apple (refactor, behavior unchanged)

Existing `Tests/SheetMusicTests/AudioFileExportTests.swift` keeps passing
without modification. Internal call site changes from `Self.resolveRange(...)`
to `range.resolveTickRange(timeline:loop:)`.

### Cross-platform (Swift Testing, Foundation-only — runs on macOS host and Android emulator)

`Tests/SheetMusicTests/AudioExportRangeResolveTests.swift` (new):
- `.full` baseline.
- `.currentLoop` with loop set + with no loop (fallback to `.full`).
- `.region` happy path.
- `.region` with invalid cursor → `rangeNotInTimeline`.
- `.regionThroughEnd` happy path.
- `.regionThroughEnd` with unknown `last: ScoreItemID` → `rangeNotInTimeline`.
- `.beat` cursor fallback when the beat tick is occupied by a chord/rest
  frame and the dedicated `.beat` frame was deduped (covers the same
  case Phase 5 sub-project A added `measureStartTicks` for).

### JNI seam (Swift Testing, host)

`Tests/SheetMusicAndroidJNITests/AudioExportRangeJNICodecTests.swift`:
- Round-trip every `AudioExportRange` case through the Kotlin↔Swift wire
  format. The Kotlin encoder's expected byte layout is the contract.
- Codec decoders alone (no JNI symbol invocation) — verifying wire-format
  agreement without needing an Android device.

### Kotlin unit tests (JVM, JUnit 5)

- `WavPcmEncoderTest.kt` — byte-for-byte expected WAV bytes from a known
  PCM input across all (bitDepth, channels, sampleRate) combinations.
- `AiffPcmEncoderTest.kt` — same for AIFF + AIFC. The 80-bit IEEE 754
  sample rate encoding has its own focused test.
- `AudioExportRangeEncoderTest.kt` — Kotlin → ByteArray round-trip and
  comparison against fixture bytes that match the Swift codec.
- `AudioExporterTest.kt` — `FakeSynthDriver` + `FakePlayerDriver` (which
  advance the current tick by `frames * ticksPerSample`) + in-memory
  `AudioFileEncoder` fake. Verifies render-loop termination at `endTick`,
  progress emission cadence, cancellation cleanup, and empty-range
  (startTick == endTick) edge case.

MediaCodec-backed encoders (M4A / MP3) are not covered by JVM tests
(MediaCodec doesn't exist in the JVM). Instrumented `androidTest/` tests
on emulator verify that the output files are valid M4A / MP3 containers
via `MediaMetadataRetriever`.

### End-to-end emulator verification (final plan task)

Pixel 6 Pro API 36 emulator + `~/Desktop/test.mscz` + `~/Desktop/gm.sf2`:
- Compose demo Export button → SAF → Downloads, for each format.
- `adb pull` the file; verify with `ffprobe` (or `MediaMetadataRetriever`
  in an `androidTest`).
- macOS export of the same `.mscz` from `SheetMusicExampleMac` provides
  a reference WAV; compare duration to confirm range resolution is
  cross-platform consistent.
- Aural comparison (perceptual, not pixel-exact) confirms staff programs
  and metronome match between platforms.

## Error mapping

| Swift `AudioExportError`         | Kotlin `AudioBackendException`        | Trigger |
|----------------------------------|---------------------------------------|---------|
| `.noScorePrepared`               | `NoScorePrepared`                     | `prepare()` not called or `scoreHandle` mismatch |
| `.rangeNotInTimeline`            | `RangeNotInTimeline`                  | JNI returns `[-1, -1]` (cursor not in timeline) |
| `.formatUnsupportedOnThisOS(f)`  | `FormatUnsupportedOnThisOS(f)`        | No MP3 encoder on device (and `.mp3` requested) |
| `.engineSetupFailed(underlying:)`| `EngineSetupFailed(cause)` (existing) | `loadSoundFont` / `playerAddMem` failure |
| `.fileWriteFailed(underlying:)`  | `FileWriteFailed(cause)`              | Encoder write exception, `fd.sync` failure |
| `.cancelled`                     | `Cancelled`                           | `CancellationException` caught and rethrown |

Cancellation contract differs intentionally:
- Apple deletes the partial output via `FileManager.removeItem(at: url)`.
- Android leaves the partial file at `outputFd` for the caller to decide
  (`ParcelFileDescriptor` ownership is the caller's). The demo's
  ViewModel issues `contentResolver.delete(uri, null, null)` in its
  cancellation handler.

State transition: `_state.value = PlaybackState.EXPORTING` at function
entry; `_state.value = PlaybackState.STOPPED` in the function's `finally`
(success, cancel, error all reach the same terminal state).
`exportMutex: Mutex` in `AndroidPlaybackEngine` serializes concurrent
calls; a queued call waits for the in-flight one rather than failing
fast.

## Out of scope (deferred follow-ups)

- Surround / multi-channel export (PCMOptions currently mono / stereo only).
- ID3v2 tag writing (MP3) and iTunes metadata (M4A).
- Concurrent live + export mode.
- Maven Central publication (v0 remains GitHub Packages-only).
- iOS 16 / Android API 27 fallbacks (package floor is iOS 17 / API 28).

## Related work / memories

- [[android-port-roadmap]] — Phase 5 sub-projects list. This is sub-project B.
- [[android-compose-example]] — Phase 4 audio wiring + JNI bridge layout.
- [[aumidisynth-program-change]] — single-shared-synth playback model that
  the export engine snapshot mirrors.
- [[subagent-no-unilateral-pivot]] — applies to the T0 spike: if the
  consumer-pull time-model assumption fails, surface to the user and
  ask between attached-silent-Oboe and `fluid_file_renderer` rather than
  picking unilaterally.
