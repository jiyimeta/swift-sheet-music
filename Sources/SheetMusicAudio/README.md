# SheetMusicAudio

AVFoundation-backed audio for `swift-sheet-music`:
- Per-staff `AVAudioUnitSampler` playback driven by a SoundFont
  resolver.
- Mixer (per-staff volume / mute / solo) and a built-in metronome.
- Timeline-driven full-score playback with looping and cursor
  feedback.
- Offline audio-file export (WAV / AIFF / M4A / MP3).

## Audio file export

```swift
let engine = PlaybackEngine(soundfontResolver: myResolver)
try engine.prepare(score: score)

let url = URL(fileURLWithPath: "/tmp/song.wav")
try await engine.exportAudioFile(
    to: url,
    score: score,
    format: .wav(PCMOptions(sampleRate: 48_000, bitDepth: .int24))
)
```

The exported file reflects the live engine state — mixer levels,
per-staff GM program changes, metronome on/off, and the current
playback rate.

### SwiftUI picker pattern

`AudioFileFormat` is an enum with associated values, so it doesn't
bind directly to a `Picker`. The recommended host pattern is a
companion tag enum + per-format options state:

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
    case .wav:  .wav(pcm)
    case .aiff: .aiff(pcm)
    case .m4a:  .m4a(comp)
    case .mp3:  .mp3(comp)
    }
}

var body: some View {
    Picker("Format", selection: $tag) {
        ForEach(FormatTag.allCases) { Text($0.rawValue.uppercased()).tag($0) }
    }
}
```

### Progress / cancellation

```swift
let task = Task {
    try await engine.exportAudioFile(
        to: url, score: score, format: .wav(),
        progress: { p in /* update UI; called on MainActor */ }
    )
}
// later, to cancel:
task.cancel()
```

A cancelled export deletes the partial file.

### Platform notes

- **MP3** writing relies on `AVAssetWriter`'s MP3 file type, which
  is only available on iOS 17 / tvOS 17 / watchOS 10. **macOS is
  not supported** for MP3 export at runtime, even on macOS 14+ —
  `AVAssetWriter` rejects `.mp3` on macOS. Calling
  `exportAudioFile` with `.mp3(...)` on macOS or on an older mobile
  OS throws `AudioExportError.formatUnsupportedOnThisOS(.mp3(...))`.
- **AIFF float32** is stored as AIFC; the writer rewrites the
  extension to `.aifc` in that case.
