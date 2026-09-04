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

## Audio route / device changes

`AVAudioEngine` stops itself when its I/O configuration changes and posts
`AVAudioEngineConfigurationChange`; `PlaybackEngine` observes it and rebuilds the
graph in place (`PlaybackEngine+ConfigurationChange.swift`), debounced 250 ms
trailing so a burst of posts from one device switch collapses into a single
rebuild rather than one per post. The automated tests post that notification
themselves, which proves the wiring, the debounce, and the rebuild, but not
that the system posts it for a real device switch — that part is manual:

- **macOS.** With two output devices connected (built-in speakers and any USB /
  Bluetooth / HDMI output), start playback in `SheetMusicExampleMac` and switch
  the system output in System Settings → Sound, or from the menu-bar volume
  control. Playback must continue, on the new device, from where it was.
  Listen for the gap: a single switch should produce **exactly one** brief
  gap (~0.3 s, the debounce interval plus the rebuild itself). Several gaps in
  a row for one switch means the burst isn't being collapsed and the debounce
  needs revisiting — check how many notifications the device actually posts
  and whether 250 ms still covers the gap between them.
- **iOS.** Start playback and unplug (or plug in) headphones mid-score.
  Note that unplugging *also* posts an `AVAudioSession` route change whose
  default behavior pauses; what matters here is that playback does not end up
  silent-but-`.playing`.

The rebuild itself is `prepare(score:)`, which is synchronous and — per its own
doc comment — can take tens of milliseconds (more on a large score, since it
re-parses the SF2 and re-renders the full SMF). A configuration-change rebuild
runs on the main actor like any other `prepare(score:)` call, so a device
switch on a large score is a brief main-thread hitch the host has no way to
opt out of; the debounce above bounds it to one hitch per switch rather than
one per notification.

If a device switch turns out not to post the notification on macOS, the fallback
is a HAL property listener on `kAudioHardwarePropertyDefaultOutputDevice` — left
out deliberately (YAGNI) until that manual test says otherwise.
