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
(per-staff tick cursors that must agree with each other),
`spanner_offsets_score_end` (the score-end boundary), `slur_ms3_exchangevoices`
(4 `<voice>` nodes and 6 `<location>` nodes across 3 measures — the only
fixture here that is not single-voice), and `guitarbend_simple` (6
`<location>` nodes, covering the endpoint writer `bb3474ae` reworked).
`own/test_lyrics.mscz` covers the zipped container through `MSCZReader`.

**Every other fixture here is single-voice** (`<voice>` count equals
`<Measure>` count) — measured, not assumed. That made the gate structurally
unable to catch ANY bug confined to a second voice, of any shape, until
`slur_ms3_exchangevoices` was added.

**What `slur_ms3_exchangevoices` actually covers, precisely.** Its six
`<location>` nodes are all `<Spanner><next>/<prev>` slur begin/end markers
spanning several voices in one measure — multi-voice `<location>` MARKER
writing, not the literal historical bug. `8623592d` (`fix(mscx): walk one
cursor through voice-level <location> jogs`) is cited as the MOTIVATION for
having a multi-voice fixture in this gate at all — a per-voice tick-cursor
disagreement can only ever be caught by a fixture with more than one voice —
not as something this specific fixture reproduces: that commit's bug was in
bare voice-level jog `<location>` elements (`VoiceElement.locationShift`),
and this fixture carries none.

**The literal voice-jog mechanism is NOT covered by any committed fixture.**
Measured, not assumed: a `.locationShift` was built directly into a
non-zero voice and probed with the encoder's cursor-advance for
`.locationShift` disabled outright — decode → encode → decode → encode
stayed byte-identical regardless. The reason: the only channel through
which that within-measure cursor's value reaches the written bytes at all —
interleaving a system element (`<Tempo>` / `<StaffText>` / …) at its
position — is wired to voice 0 only
(`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift`:
`index == 0 ? voice0SystemElements : []`). Neither a slur end marker
(`Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`: "the `<prev>`
side carries no model state — the encoder recomputes it") nor a tie's
`<location>` (`Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice+Ties.swift`'s
`forwardTieDelta` / `backwardTieDelta` depend only on chord duration and the
PREVIOUS MEASURE's carry, never the within-measure cursor) reads that
cursor's value either. **Covering the literal mechanism would need the
encoder taught to interleave a system element into a non-zero voice too —
not just a fixture on its own** — which is a real architectural gap, not
merely an untested one.

One case is **synthesized** rather than loaded: a hidden beam
(`<Beam><visible>0</visible></Beam>`) is a tag the encoder writes from
`Chord.beamVisible` rather than carrying through from a decoded node, and no
committed fixture has one — every `<Beam>` in `Resources/` is an `<l1>`/`<l2>`
stem-position node. That case decodes a beamed fixture, clears `beamVisible`,
and asserts a non-zero count of chords changed so it cannot silently do nothing.

**When you add a fixture, add the reason with it.** A list of names with no
stated shapes stops being maintainable the moment the encoder changes.

**Which fixtures are pristine MuseScore output, and which are not.**
`midi01.mscx`, `grace_after.mscx`, `guitarbend_release_twice.mscx`,
`guitarbend_gracebend.mscx` and `musicxml/*_ref.mscx` are unmodified
MuseScore-authored files and may be cited as evidence of what MuseScore
itself writes. `slur_ms4_resave.mscx` and `legacybend_ms4_resave.mscx` are
**not** — both are hybrids that carry this library's own writer output,
including `<Part><eid>` values no MuseScore file ever contains (MuseScore's
writer has no such tag — see "A real MuseScore round trip" below, which
measures this as the one carrier that does not survive an actual MuseScore
save). `slur_ms4_resave.mscx` also
gained an explicit `<TimeSig><subtype>1</subtype>` during this phase
specifically to pin the `<eid>`-after-`<subtype>` ordering under a gate
rather than only a comment (`e2fa7d0d`) — a reader should not mistake that
tag for musical intent recorded by MuseScore itself.

## Layer 2 — the corpus sweeps, opt in

Two suites gate on the same `SM_MSCX_IDEMPOTENCY_DIR` environment variable and
walk the same corpus, but check different properties. **Filtering by suite
name runs exactly one; an unfiltered `swift test` with the variable set arms
and runs both.**

`@Suite MSCXIdempotencySweep` runs the encode/decode/encode byte-identity
comparison described above over every `.mscx` / `.mscz` under a directory,
recursively:

```bash
SM_MSCX_IDEMPOTENCY_DIR=~/path/to/scores swift test --filter MSCXIdempotencySweep
```

`@Suite EIDRoundTripSweep` (added in the P4 `<eid>`-persistence phase) checks
a different property over the same corpus: that every identifier a file
carries survives this library's own decode → encode → decode, at the same
structural position. It is the layer-2 counterpart to the single-fixture
`EIDPersistenceTests`, over real scores rather than committed fixtures:

```bash
SM_MSCX_IDEMPOTENCY_DIR=~/path/to/scores swift test --filter EIDRoundTripSweep
```

**`--filter Sweep` is a loose match, not a way to select "the sweeps"** — on
this corpus it caught 13 tests across 9 suites, most of them unrelated. To run
precisely these two:

```bash
SM_MSCX_IDEMPOTENCY_DIR=~/path/to/scores swift test --filter 'EIDRoundTripSweep|MSCXIdempotencySweep'
```

Both suites are **disabled** when `SM_MSCX_IDEMPOTENCY_DIR` is unset, so an
unfiltered default `swift test` costs nothing. **No corpus path is
committed** — the variable carries it, following `SM_VELOCITY_DIR`
(`Sources/RenderPreviews/VelocityReport.swift`), `SM_PDF_PROBE` and
`OMR_DATA_ROOT`. **Measured** running `EIDRoundTripSweep` alone against the
669-file corpus: **17.7 minutes (1062.5 seconds)** — budget for that, not
the 9–10 minutes an earlier estimate in this doc named before the sweep had
actually been run once end to end.

```
[eid-roundtrip] files=670 loaded=669 unreadable=1 failed=0 identifiers=3320622 dropped=13
                unstable=0 invented=0 noIdentifiers=0
```

3.3 million identifiers compared over 669 real scores, zero unstable, zero
invented. **`dropped=13`**: a static scan of the same corpus (matching every
staff-head, voice-0, measure-0 `<KeySig>` against
`MSCXEncoder+Voice.swift`'s `shouldDropInitialZeroKeySig` precondition —
concert key resolves to 0 under `MSCXDecoder+KeySignature.swift`'s rules)
found exactly 13 qualifying elements, confirming the count is not a mystery:
9 are the ordinary case already known from a smaller measurement (ordinary
staff-head implicit-C-major `<KeySig>`, spelled `<accidental>0</accidental>`
or `<concertKey>0</concertKey>`), and the remaining **4 are a related but
distinct sub-case worth flagging on its own**: a staff-head key signature
marked `<custom>`/`<mode>` and spelled entirely with `<KeySym>` glyphs (an
atonal or non-standard signature) decodes its absent fifths count as 0 under
`KeySignature.decode`'s custom-key fallback, so `shouldDropInitialZeroKeySig`
treats it exactly like an implicit C-major default and drops it **whole** —
losing the actual custom glyphs, not merely an implicit default that carried
no information. That is a genuine (if rare — 4 of 3.3 million identifiers)
content-loss gap in the pre-existing custom-key-signature simplification,
not introduced by this phase and out of scope for this fix wave, but worth
a follow-up. (A third, unrelated shape was also found while scanning: one
corpus file's staff-head `<KeySig>` uses the legacy MuseScore 1.x `<subtype>`
+ `<KeySym>` spelling with no `<concertKey>`/`<accidental>`/`<custom>`/`<mode>`
at all, which this decoder does not recognize and would fail to decode —
consistent with the sweep's own `unreadable=1`, and irrelevant to the
`dropped` count since a file that never loads contributes to neither side of
the comparison.)

A file that will not **decode** is reported and skipped rather than failed: a
corpus of real scores contains MuseScore 1.x files this reader does not claim to
open, and failing on those says nothing about idempotency. A file that decodes
but whose **encode throws** is counted separately, as `failed`, and makes the
sweep fail rather than pass quietly — folding a throwing encode into "not
different" (`try?` swallowing the error) would let a broken encoder hide inside
a green `differing=0`, exactly the "a pass is not evidence" failure this gate
exists to catch, reproduced inside the gate itself. `MSCXIdempotencySweep`
prints its counts —

```
[mscx-idempotency] files=670 loaded=669 unreadable=1 failed=0 differing=0
```

— because "no failure was reported" and "it compared 669 scores" are different
facts. Quote the counts, not the conclusion. The corpus has grown over time —
an earlier measurement of this same transcript read `loaded=668`; do not read
that older number as the gate's current size.

Run this before a release, and after any change to `Sources/SheetMusicMSCX/`.

## A property that looks like a bug and is not: `systemMeasures` shorter than the measure count

A `Score` whose `systemMeasures` lane is shorter than its measure count is
**not** an encode fixed point, even though `MSCXEncoder.encode` runs the
identifier chokepoint (`assignMissingIDs`) on a local copy before encoding,
and every carrier whose slot exists is otherwise a fixed point under it. The
chokepoint can only **fill** a slot that exists — `Score.swift:132` assigns
into `systemMeasures`, it never resizes the array — while decode always pads
the lane to the real measure count. So a score built or edited into that
shorter-than-measure-count shape encodes once with the lane short, and only
gains the missing identified slots on the next decode → encode, one round
trip later.

This is a legitimately reachable host state, not a defect to "fix" by
rejecting it: `InsertMeasure.swift:136-139` and
`SetTimeSignature+Splice.swift:165` both maintain the lane **only when**
`systemMeasures.count == measureCount` already held, because "a score that
never held the lane at all" is itself a supported state (most scores have no
system-lane elements). It stabilises after one round trip and nothing is
lost — the identifiers filled on that second encode are as valid as any
other minted identifier.

The candidate fix for a later phase is to normalise `systemMeasures` to the
measure count inside `assignMissingIDs` itself, so the chokepoint's fill
covers this case in the same pass rather than needing a second round trip.

## A real MuseScore round trip (`<eid>` identifier survival)

Everything above is this library checking itself against itself. This section is
the one gate in the P4 `<eid>`-persistence phase that is not: it runs the
**installed MuseScore application** on a file this library wrote, and checks
what comes back.

**Measured 2026-09-11 against `MuseScore4 4.7.4`** (`/Applications/MuseScore
4.app/Contents/MacOS/mscore --version`). The spec's source citations
(`read460.cpp`, `tread.cpp`, `twrite.cpp`) are from the MuseScore 4.6 source
tree; this measurement does not confirm those citations against 4.6 itself; it
measures the actually-installed 4.7.4 binary, which is the version whose
behavior matters for anyone running this library today. A MuseScore 3
installation is also present on this machine and was **not** used — MuseScore 3
predates this phase's `<eid>` support entirely.

Method: decode a fixture, encode it with `MSCZWriter` (the same path a host
app uses), and re-parse that exact `.mscz` to record every identifier's
value at its structural position (part/staff/measure/voice/element/note —
see the scratch harness for the full walk). Run the MuseScore 4.7.4 CLI
(`mscore -o roundtrip.mscz input.mscz`) against the file this library wrote,
re-parse the CLI's output, and compare every recorded identifier at its
position.

Three fixtures were used to cover the carriers this library identifies:
`guitarbend_release_twice.mscx` (Part, Staff, Measure, TimeSig, Dynamic,
Tempo, Chord, Note, Rest, GraceChord), `own/grace-notes.mscx` (adds Tuplet),
and `testRepeatsWithKeySigsExceptFirstMeas.mscx` (KeySig at a non-staff-head
position — the staff-head KeySig in the other two fixtures is a C-major key
this library's own encoder omits as implicit, per MuseScore's own writer
convention, so it never reaches MuseScore at all and cannot test survival).

**Per-carrier survival, summed over the three fixtures (74 identifiers recorded total):**

| Carrier | Survived | Changed | Missing |
|---|---|---|---|
| Chord | 14 | 0 | 0 |
| Note | 19 | 0 | 0 |
| Rest | 2 | 0 | 0 |
| GraceChord | 7 | 0 | 0 |
| Note (grace) | 7 | 0 | 0 |
| Measure | 9 | 0 | 0 |
| Staff (`<Part><Staff>` declaration) | 3 | 0 | 0 |
| KeySignature | 4 | 0 | 0 |
| TimeSignature | 3 | 0 | 0 |
| Dynamic | 1 | 0 | 0 |
| Tempo | 1 | 0 | 0 |
| Tuplet | 1 | 0 | 0 |
| **Part** | **0** | **3** | **0** |

71 of 74 identifiers came back byte-identical. The only carrier that did
not is **Part**, on all 3 of 3 occurrences — exactly the gap this phase
already documents as deliberate: `<Part><eid>` is this library's own tag
inside MuseScore's element, MuseScore's writer never round-trips it, and a
fresh save re-mints it. No other modeled carrier changed or went missing in
any of the three fixtures.

Two things the raw MuseScore output surfaced that are **not** carrier
losses, recorded here so a future measurement doesn't re-diagnose them:

- **A voice element this library does not model at all — decoded as
  `.preserved`/replayed verbatim — carries no persistent identifier by
  design.** `MSCXEncoder+Voice+Emit.swift`'s `case let .preserved(markup):
  return XMLTreeNode(preserved: markup)` never consults the slot's `eid`;
  `IdentifiedArray.assignMissingIDs` still gives the slot an in-memory ID
  because every slot gets one uniformly, but that ID is never written. The
  `testRepeatsWithKeySigsExceptFirstMeas.mscx` fixture (a pre-P4, no-`<voice>`
  legacy layout) decodes its bare `<startRepeat/>` / `<endRepeat>` markers at
  measures 3–4 into one such unmodeled slot each; comparing raw XML-child
  index would have misreported every following real carrier in that voice as
  "shifted", so the harness's position index counts only the elements this
  library actually persists identity for.
- **The MuseScore 4.7.4 CLI process crashed with `libc++abi: mutex lock
  failed` (exit code 6) after successfully writing its output** on most of
  the runs in this measurement — the known trap from earlier work in this
  repository. The output `.mscz` was checked for existence and non-zero size
  before being trusted, not the exit code.

**Probe validity check.** The comparison above is not a comparison that
would report success on nothing: a real round-tripped `.mscz` was unzipped,
one `<Chord><eid>` was deleted by hand, and the file was re-zipped. Running
the same comparison used above against that hand-mutated file reported
`Chord: survived=1 changed=1` and named the exact identifier
(`XM0f8eqOBUL_yul1asrUrNJ` → freshly re-minted), confirming the comparison
notices a genuinely lost identifier rather than passing regardless of input.

Not covered by any committed fixture, so not measured here: `RehearsalMark`
(no fixture in this repository contains one) and `.spanner` (already
recorded elsewhere in this phase as not persisting, for a reason unrelated
to MuseScore's round trip).
