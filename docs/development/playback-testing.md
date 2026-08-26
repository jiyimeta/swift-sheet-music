# Playback regression testing

Playback tests must distinguish notated score time from the unrolled player
timeline and must use fixtures capable of exposing missing state.

## Repeat-aware positions

`UnrolledTimeMap` is the identity for a score without repeats. Such a fixture
cannot prove that notated positions are projected into player time correctly.
Use `repeat.mscz` for playback-clock assertions: it contains a repeated region
whose notated and player timelines differ.

`unrolledSeconds(fromNotated:)` intentionally returns the first occurrence and
is suitable for seek, play-from, and loop-wrap operations. To locate a specific
measure occurrence during playback, resolve against the unrolled span instead;
`PlaybackClock.playerSecondsForUnrolledTick` provides that behavior.

## Seek behavior

A browser sequencer can report its old position for one or two audio buffers
after a seek. Cursor and readout updates should render the requested destination
immediately instead of reading the sequencer position back synchronously.

## Audio assertions

- An offline render can produce correctly sized silence. Assert a meaningful
  peak level as well as byte count and duration.
- A score whose melodic parts all use General MIDI program 0 cannot detect a
  missing program application. Use `mixer.mscz`, which contains non-zero
  programs, different volumes, and percussion.
- Percussion alone does not prove program selection because MIDI channel 9 uses
  the drum bank independently of the melodic program.

When adding a regression fixture, make sure its data differs on the dimension
the bug could accidentally default correctly.
