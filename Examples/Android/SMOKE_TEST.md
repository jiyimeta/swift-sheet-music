# Android audio backend — manual smoke test

Run this checklist on both:
- arm64-v8a physical device (Pixel / Samsung / etc.)
- x86_64 emulator (Android Studio AVD, API 28+)

## Prerequisites

- `gm.sf2` (General MIDI SoundFont; GeneralUser GS is a free choice) installed at `~/Desktop/gm.sf2`
- `test.mscz` MuseScore file at `~/Desktop/test.mscz`
- `Scripts/android-build-libs.sh` has run successfully
- `Scripts/android-bundle-test-score.sh` has staged both files into `Examples/Android/app/src/main/assets/`

Build + install:
```
cd Examples/Android && ./gradlew :app:installDebug
```

## Checklist

### Lifecycle
- [ ] App launches without crash
- [ ] Score renders on canvas
- [ ] Play button becomes enabled after the score finishes loading
  (if it stays disabled, check logcat for `AudioVM: prepare failed`)

### Playback core
- [ ] Tap Play → audio starts; cursor advances visually
- [ ] Tap Pause → audio halts within ~100ms; cursor freezes
- [ ] Tap Pause-then-Play → audio resumes from the paused position
- [ ] Tap Stop → audio halts; cursor disappears; next Play starts from beginning
- [ ] Tap +5s → cursor jumps forward ~5s; audio continues seamlessly
- [ ] Tap -5s → cursor jumps backward ~5s; audio continues seamlessly

### Mixer (per-staff)
- [ ] Each staff's mute toggle silences that staff only; others continue
- [ ] Solo toggle: with N=1 soloed, only that staff is audible
- [ ] Solo + Mute on same staff: that staff stays muted (mute wins)
- [ ] Volume slider 0.0 silences that staff
- [ ] Master volume 0.0 silences everything
- [ ] Master volume 1.0 restores normal level

### Metronome
- [ ] Metronome toggle ON: hear wood-block ticks aligned to beats during playback
- [ ] Metronome toggle OFF: ticks stop, music continues
- [ ] Metronome volume slider scales the tick amplitude

### Robustness
- [ ] Background the app (Home button) → playback continues by default
- [ ] Plug in BT headphones during playback → audio routes to BT (brief gap allowed)
- [ ] Unplug BT → audio routes back to speaker
- [ ] Incoming phone call (or notification with audio) → playback pauses
- [ ] Configuration change (rotate device) → playback continues from same tick
- [ ] Large score (≥ 30 staves) → prepare under 3s; memory under 250MB
- [ ] Tap Stop, then close + relaunch app → fresh start, no leaked process

## Phase 5 sub-project A — engine extensions

### Rate slider
- [ ] Open the app and wait for "Ready" state
- [ ] Tap Play
- [ ] Drag the Speed slider to 0.5x → audible slow-down + cursor still tracks
- [ ] Drag to 2.0x → audible speed-up + cursor still tracks
- [ ] Drag back to 1.0x
- [ ] Speed label updates to match the slider value (e.g., "Speed: 1.25x")

### Program picker
- [ ] Tap Play, then Pause
- [ ] In the mixer panel ("Show"), tap a non-drum staff's program label
  (defaults to "Acoustic Grand Piano" or whatever the score specifies)
- [ ] Picker dialog opens, scrolled to the current patch
- [ ] Pick "Violin" (program 40)
- [ ] Tap Play → that staff sounds as a violin; other staves unaffected
- [ ] Drum staves show "Drums" non-clickable (verify if your score has drums)

### Loop toggle (v0)
- [ ] Loop status row reads "Loop: off" by default
- [ ] Switch is disabled when no loop is set
- [ ] After `setLoop()` is called programmatically (Phase 5.1 will add the
  tap-to-set-A/B UI), the status reads "Loop: <startTick>..<endTick>" and
  the switch becomes enabled
- [ ] Toggling the switch OFF calls `clearLoop()` — status returns to "Loop: off"

### Known v0 deferred
The following are intentionally NOT supported in v0:
- Tap-to-set-A/B UI for `setLoop` (engine API ready; UI gesture deferred to Phase 5.1)
- Audio file export (WAV/AIFF/M4A/MP3)
- MediaSession / lock-screen controls
- > 16 staves (throws `AudioBackendException.TooManyStaves`)
- Tap-to-seek on the score canvas (UI hook present, spatial mapping TBD)

## Failure triage

If a checkbox fails:
- Capture logcat: `adb logcat *:S AudioVM:V FluidSynth:V`
- Check the spec's "Errors / edge cases" section for the matching scenario
- File a follow-up issue
