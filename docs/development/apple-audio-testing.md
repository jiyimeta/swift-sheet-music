# Apple audio testing

This document records AVFoundation constraints that are easy to miss when
testing playback and audio-file export.

## SoundFont isolation

Do not render an `AUMIDISynth` without a real SoundFont loaded. A preset-less
synth can corrupt process-wide CoreAudio state and cause a later, unrelated
synth using a valid SoundFont to fault inside mixer rendering.

The audio test suite normally uses no local SoundFont. Tests that need an
audible metronome should follow `MetronomeClickPlaybackTests`: use a nil
SoundFont resolver and a generated click WAV, leaving the score synth silent.
This remains deterministic and runs in CI.

Do not attach a preset-less synth merely to satisfy `AVAudioSequencer` routing;
removing it from the graph can instead leave the sequencer without a destination
and make `start()` raise an Objective-C exception that Swift cannot catch. Treat
the documented `SoundfontResolver.defaultGMSoundfontURL` requirement as a
precondition for real score playback.

## Export writers

Use the native writer for each format:

- WAV and AIFF/AIFFC: `AVAudioFile`
- M4A/AAC: `AVAudioFile` with MPEG-4 AAC settings
- MP3: `AVAssetWriter` on supported iOS-family versions

Do not route the other formats through `AVAssetWriter`. macOS rejects MP3
output through `AVAssetWriter` at runtime even on releases where the API is
available. See `Sources/SheetMusicAudio/Export/AudioExportWriter.swift` for the
platform gates.

## Audio Units this package registers itself

Every `AudioComponentDescription` this package *registers* — as opposed to the
ones it uses to look Apple's own components up — must set
`AudioComponentFlags.sandboxSafe` in `componentFlags`. Inside an App Sandbox the
component manager refuses a locally registered component that does not declare
it, and `AVAudioUnitEffect(audioComponentDescription:)` then throws an
Objective-C exception (`com.apple.coreaudio.avfaudio`, error -3000) which Swift
cannot catch. `PlaybackEngine.init` builds the master chain eagerly, so the host
process dies a few seconds after launch without ever starting playback.

Nothing in this package's own test suite can catch that: the tests run in an
unsandboxed host, where both flag values work. The failure was found with a
2×2 bench outside the package (App Sandbox entitlement × `componentFlags`),
which crashed in exactly one cell — sandboxed with flags `0` — and exited
cleanly in the other three. Rebuilding that bench is the only way to re-verify
it: a minimal entitled `.app` that constructs the node and exits.

Descriptions used purely to *find* an Apple component (`makePeakLimiter`,
`MIDISynthBuilder.make`) pass `componentFlagsMask: 0`, so their flags are not
matched and need no change.
