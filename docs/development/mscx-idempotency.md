# The MSCX 2-pass idempotency gate

**The property.** Decode a score, encode it (**pass 1**), decode that, encode
again (**pass 2**). Pass 1 and pass 2 must be **byte-identical**.

`Tests/SheetMusicTests/MSCXIdempotencyGateTests.swift` is the gate.

## What it detects that nothing else does

Pass 1 differing from the **original** file is expected and legitimate: the
encoder writes tags MuseScore's own files omit, and normalizes ones they spell
differently. Every other round-trip test in the repo therefore compares `Score`
**values** rather than bytes (`MSCXRoundTripTests`, `SlurRoundTripTests`, …).

Pass 1 differing from **pass 2** is a defect with no other detector:

- A `Score`-equality round trip is blind to it — both passes decode to the same
  score. It is the bytes that drift.
- A byte comparison against the original is blind to it too, because that
  comparison does not pass in the first place, so nobody runs it.

The consequence in a host application is that **saving is not a fixed point**:
every save mutates the file further, and a user who opens and saves five times
gets five different files. The shape is usually a decoder and an encoder that
walk the same cursor and disagree about it — the real instance was `<location>`
tick cursors walked independently by `MSCXDecoder` and `MSCXEncoder`, each
advancing the cursor permanently, so pass 2 re-spelled positions pass 1 had
already normalized.

## Layer 1 — always on, in CI

`@Suite("MSCX 2-pass idempotency")` runs the comparison over committed fixtures
in `Tests/SheetMusicTests/Resources/`. It needs no environment setup and takes
well under a second, so it runs on every `swift test`.

The fixtures are chosen for the shapes that have moved the encoder's output;
each one's reason is in the test's doc comment. Briefly: `testVoltaTemp` (a
`<Tempo>` plus a `<Volta>`'s relative `<location>`), `testSingleNoteDynamics`
(the densest spanner fixture), `slur_ms4_resave` (slurs, which live in
`Chord.spanners` rather than as their own element), `own/grace-notes` (the only
`<Tuplet>` fixture, and it has grace notes), `grace_after` (after-grace
placement, absolute `<grace>` vs delta `<notes>`), `multiPartMixedStaves`
(per-staff tick cursors that must agree with each other), and
`spanner_offsets_score_end` (the score-end boundary). `own/test_lyrics.mscz`
covers the zipped container through `MSCZReader`.

One case is **synthesized** rather than loaded: a hidden beam
(`<Beam><visible>0</visible></Beam>`) is a tag the encoder writes from
`Chord.beamVisible` rather than carrying through from a decoded node, and no
committed fixture has one — every `<Beam>` in `Resources/` is an `<l1>`/`<l2>`
stem-position node. That case decodes a beamed fixture, clears `beamVisible`,
and asserts a non-zero count of chords changed so it cannot silently do nothing.

**When you add a fixture, add the reason with it.** A list of names with no
stated shapes stops being maintainable the moment the encoder changes.

## Layer 2 — the corpus sweep, opt in

`@Suite MSCXIdempotencySweep` runs the same comparison over every `.mscx` /
`.mscz` under a directory, recursively:

```bash
SM_MSCX_IDEMPOTENCY_DIR=~/path/to/scores swift test --filter MSCXIdempotencySweep
```

The suite is **disabled** when `SM_MSCX_IDEMPOTENCY_DIR` is unset, so it costs a
default `swift test` nothing. **No corpus path is committed** — the variable
carries it, following `SM_VELOCITY_DIR` (`Sources/RenderPreviews/VelocityReport
.swift`), `SM_PDF_PROBE` and `OMR_DATA_ROOT`.

A file that will not **decode** is reported and skipped rather than failed: a
corpus of real scores contains MuseScore 1.x files this reader does not claim to
open, and failing on those says nothing about idempotency. The run prints its
counts —

```
[mscx-idempotency] files=669 loaded=668 unreadable=1 differing=0
```

— because "no failure was reported" and "it compared 668 scores" are different
facts. Quote the counts, not the conclusion.

Run this before a release, and after any change to `Sources/SheetMusicMSCX/`.
