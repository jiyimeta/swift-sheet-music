# SheetMusicAudioAndroid

Kotlin Gradle module providing audio playback for `swift-sheet-music` on
Android. Peer to `SheetMusicAudioApple` (the Swift module that provides
the same capability on Apple platforms).

## What it provides

- `AndroidPlaybackEngine` — the Android counterpart to Apple's
  `PlaybackEngine`. Accepts a Score handle (obtained via the Phase 4
  JNI bridge), prepares per-staff FluidSynth voices loaded from a
  General MIDI SoundFont, and plays back synchronized with a cursor.
- `SoundfontResolver` — Kotlin interface that hosts implement to
  point `AndroidPlaybackEngine` at SF2 files. Apple's
  `SoundfontResolver` is the same semantically; the cross-platform
  mapping is below.
- Observable state via `StateFlow<…>` — Compose consumes the cursor,
  current time, mixer channels, and playback state idiomatically.

## v0 scope

Supported: `prepare / play / pause / stop / seek / skip / playPreview /
clearCursor / earliest / mixer (mute/solo/volume/master) / metronome
(on-off/volume) / teardown`.

Not yet supported (planned for v1+):
- Loop region (`setLoop`)
- Variable rate (`setRate`)
- Per-staff program change at runtime (`loadProgram`)
- Audio file export
- MediaSession / lock-screen integration

## Usage

```kotlin
// In your Gradle build:
dependencies {
    implementation("io.github.kiichiio:sheet-music-audio-android:0.0.0-SNAPSHOT")
}

// In your ViewModel:
class AudioViewModel(application: Application) : AndroidViewModel(application) {
    private val resolver = object : SoundfontResolver {
        // Materialize an SF2 from your assets / cache and return its URI
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? =
            yourGmSoundfontUri
        override val defaultGmSoundfontUri: Uri? = yourGmSoundfontUri
    }
    val engine = AndroidPlaybackEngine(application, resolver)

    fun start(scoreHandle: Long) {
        viewModelScope.launch {
            engine.prepare(scoreHandle)
            engine.play()
        }
    }

    override fun onCleared() {
        engine.teardown()
        super.onCleared()
    }
}
```

## SoundfontResolver — Apple/Kotlin mapping

| Apple (Swift)                                                  | Android (Kotlin)                                                |
|---|---|
| `func soundfontURL(forBank: UInt8, program: UInt8, isDrums: Bool) -> URL?` | `fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri?` |
| `var defaultGMSoundfontURL: URL?`                              | `val defaultGmSoundfontUri: Uri?`                               |

Same semantics, idiomatic naming per language. Apple uses `URL` /
`UInt8`; Kotlin uses `Uri` / `Int` (no `UInt8` in mainstream Kotlin).

## Architecture (1-line summary)

`SheetMusicAudioJNI` Kotlin object loads `libSheetMusicJNI.so` (Swift
bridge) and `libsheetmusicaudio.so` (C JNI shim over FluidSynth via
`libfluidsynth.so`). MIDI rendering + timeline lookups happen Swift-side;
synthesis + Oboe-style output (currently `AudioTrack` for v0) happen
Kotlin-side.

Full design in `docs/superpowers/specs/2026-05-19-android-audio-backend-design.md`.

## ABI matrix

| ABI         | Status |
|-------------|--------|
| arm64-v8a   | Supported (primary) |
| x86_64      | Supported (emulator) |
| armv7       | Not supported |

Minimum SDK: 28 (Android 9).

## License

The published Kotlin source code is MIT-licensed (matches the
swift-sheet-music package). The Kotlin module pulls in:

- **FluidSynth** (`net.volcanomobile.fluidsynth-android:2.4.6`) —
  LGPL 2.1, dynamically linked via `libfluidsynth.so` packaged in the
  AAR. Source: https://github.com/VolcanoMobile/fluidsynth-android
- **Oboe** (transitively via Gradle) — Apache 2.0
- **kotlinx-coroutines-android** — Apache 2.0

Per LGPL §4, applications using this module must:
1. Allow the user to replace `libfluidsynth.so` with a modified version
   (which is automatic via the dynamic `jniLibs/` packaging — no action
   needed by the app developer).
2. Include the LGPL notice + a source pointer in their application's
   open-source licenses screen.

A consumer-app LICENSE notice template:
```
This app uses FluidSynth (https://github.com/VolcanoMobile/fluidsynth-android),
licensed under LGPL 2.1. Library source available at the URL above.
```
