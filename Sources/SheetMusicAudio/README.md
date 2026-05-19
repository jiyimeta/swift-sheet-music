# SheetMusicAudio

Umbrella module for swift-sheet-music's audio sub-libraries.

- On Apple platforms, `import SheetMusicAudio` re-exports both
  `SheetMusicAudioCore` (Foundation-only value types) and
  `SheetMusicAudioApple` (AVFoundation-backed `PlaybackEngine`,
  audio file export, metronome, MIDI synth builder).
- On Android, only `SheetMusicAudioCore` participates in the build
  graph; `PlaybackEngine` and friends are absent. Phase 4 will
  introduce an actual Android backend (AAudio / Oboe bridge or a
  pure-Swift PCM renderer); until then "Android audio playback"
  is a compile-time absence by design.

## Sub-targets

| Target | Platform | Contents |
|---|---|---|
| `SheetMusicAudioCore` | All (Foundation-only) | Playback timeline, metronome beats, GM instrument table, mixer channel, loop range, playback state, audio file format / range / error enums. |
| `SheetMusicAudioApple` | Apple-only (`canImport(AVFoundation)`) | `PlaybackEngine` + extensions, `MetronomeController`, `MIDISynthBuilder`, `AudioExportWriter`, `AudioFileExporter`. |
| `SheetMusicAudio` | Apple-only (umbrella) | `@_exported import` of both above. |

Apple consumers should keep writing `import SheetMusicAudio`. Android
consumers must `import SheetMusicAudioCore` directly.

## Audio file export

```swift
let engine = PlaybackEngine(soundfontResolver: myResolver)
try engine.prepare(score: score)

let url = URL(fileURLWithPath: "/tmp/song.wav")
try await engine.exportAudioFile(
    to: url,
    score: score,
    range: .fullScore,
    format: .wav(.init())
)
```

(See `Sources/SheetMusicAudioApple/Export/` for the writer back-ends and
`Sources/SheetMusicAudioCore/Export/` for the format / error / range
value types.)
