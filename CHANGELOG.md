# Changelog

All notable changes to this project are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Scanned (image-only) PDFs import. `PDFImporter.parse` and `parseWithGeometry` rasterize every page the
  vector walker finds no music on and read it through an optical music recognition detector — when, and only
  when, `PDFImportOptions.omrTileClassifier` is set. Left `nil`, the importer does exactly what it did before:
  no rasterization, no model load, no new code path. The decision is per page, so a typeset title page followed
  by scanned music needs no choice from the caller — though a page with no vector music on it, that cover
  included, does pay one detector pass (about 1.5 s per page in a Release build; many times that in Debug).
  `omrRenderDPI` (default 300) sets the resolution and is clamped, with a warning, below 72. A page that cannot be rasterized or read costs a warning and its own
  content, never the document. Nothing textual comes off a scanned page — there is no OCR.
- `SheetMusicOMRModel`, a new Apple-only product bundling the trained detector as a compiled Core ML model
  (~1.1 MB) behind `CoreMLTileClassifier`. Separately linkable, so a consumer that never reads scans carries
  none of it; `SheetMusicPDF` does not depend on it. `CoreMLTileClassifier(modelRoot:)` loads an external
  checkpoint instead. The portable half of the detector — tiling, head decoding, merging, and the assembly of
  detected glyphs with the classical-CV staff lines, stems and beams into the importer's own content model —
  lives in `SheetMusicPDF` behind the public `OMRTileClassifier` protocol, which is the whole platform seam an
  ONNX or other backend has to implement.
- `PDFImportOptions` and `PDFImportDiagnostic` are `Sendable`, so a host can build the options on one actor,
  parse on another, and carry the diagnostics back. `CoreMLTileClassifier()` is a synchronous `throws`
  initializer — the bundled model is precompiled and nothing in its load awaits; only `init(modelRoot:)`,
  which compiles at run time, stays `async`.
- `SM_PDF_OMR=1` on `swift run render-previews` reads the `SM_PDF` file with the bundled model.
- `Training/`: the Python pipeline that generates the synthetic dataset, trains the detector and exports the
  bundled model, with its own tests; `Scripts/mscz-corpus-prep.sh` / `mscz-corpus-eval.sh` score the raster
  path against a `.mscz` corpus's own answers.
- Five structural edit commands, the first group of the edit-command parity project
  (`docs/superpowers/specs/2026-09-02-edit-command-parity-design.md`): `SetLayoutBreak` sets or clears a line /
  page / section break on a measure; `SetBarLine` writes a measure's visible end-barline style (regular / double /
  end / dashed / dotted / heavy / double-heavy); `SetRepeatBarLines` writes a measure's `startRepeat` /
  `endRepeatCount`; `SetMeasureRepeat` turns 1, 2 or 4 empty bars into a measure-repeat group (`%` sign) or
  dissolves one back into measure rests; `MoveToVoice` moves a chord or rest to another voice at the same tick,
  splitting rests around it as needed. Reachable as `EditIntent.setLayoutBreak` / `.setBarLine` /
  `.setRepeatBarLines` / `.setMeasureRepeat` / `.moveToVoice`, wire cases 30–34. `MoveToVoice` no longer refuses a
  slot that follows a tuplet in its bar: a tuplet member stores its sounding length, so every tick walker was
  already ratio-aware and the refusal guarded nothing. `EditRefusal.Reason.tupletPrecedesSlot` is gone with it;
  the enum gained `invalidTransposition(semitones:)` and `invalidInterval(steps:)` for the range group below.
- Six range edit commands, the second group of the same project: `TransposeRange` moves every note in a range by
  ±1…24 semitones, optionally re-spelling the result in the key; `AddIntervalToSelection` adds a diatonic
  interval (Alt+1…9 above, Shift+Alt+1…9 below) to every chord; `DeleteRange` replaces each chord with a rest and
  collapses any bar-voice the deletes emptied; `SetAccidentalsInRange` applies one accidental — or clears the
  glyph — across a range; `SetDurationInRange` re-times every chord and rest to one duration; `RespellRange`
  re-spells a range enharmonically. Reachable as `EditIntent.transposeRange` / `.addIntervalToSelection` /
  `.deleteRange` / `.setAccidentalsInRange` / `.setDurationInRange` / `.respellRange`, wire cases 35–40. Each
  takes a `VoiceElementRange` whose bounds may be given in either order and whose band is every voice of the
  staves between them. All six are one `CompositeEditCommand` and therefore one undo step, built by a shared
  `RangeEditPlanner`: targets run in ascending onset order, each re-found by its tick in the score the previous
  step produced, so an onset a lengthening already swallowed is skipped (`[q q q q]` to half is `[h h]`, as in
  MuseScore) — and any refusal rolls the whole range back, leaving nothing written. A tie chain is one sounding
  note: pitch edits move it whole, with the accidental on its head alone.
- Nine mark edit commands, the third group of the same project: `SetClef` writes a clef change before a chord or
  rest (replacing one already there, or landing at index 0 as the bar's header clef when nothing timed precedes
  the target) and `RemoveClef` takes an explicit clef out; `SetTempo` writes, replaces or removes the tempo at a
  beat, taking a `SetTempo.Marking(beatsPerSecond:beatNote:beatDots:)` — the metronome mark alone, since `Tempo`
  has no text field, so a marking's words ("Allegro") are neither written nor kept; `SetStaffText` writes,
  renames or removes
  the staff text — or, with `isSystemText`, the system text — at a beat; `SetDynamic` writes a dynamic on a chord
  with MuseScore's default velocity for the subtype; `SetFermata` writes a fermata over a chord or rest with a
  `timeStretch`; `SetBreath` writes a breath mark or caesura after a chord; `SetJumps` and `SetMarkers` replace a
  bar's navigation jumps / markers on the canonical staff. Reachable as `EditIntent.setClef` / `.removeClef` /
  `.setTempo` / `.setStaffText` / `.setDynamic` / `.setFermata` / `.setBreath` / `.setJumps` / `.setMarkers`, wire
  cases 41–49. Every mark that can be present or absent is ONE intent whose payload is optional: a value writes or
  replaces, `nil` removes; an empty list clears for the two plural ones. Lane marks (tempo, staff text) are
  addressed by the chord or rest they sit on rather than by a raw tick, so a file-authored lane mark at a tick no
  chord starts is not reachable in this version. An intent that restates what the score already says plans to
  nothing and is refused rather than recorded as an empty undo step.
- `Dynamic.defaultVelocity(for:)` exposes MuseScore's dynamics table (the numbers the MSCX decoder already filled
  in for a `<Dynamic>` with no `<velocity>`) on `Dynamic` itself, where a host writing a dynamic can reach it.
- `EditRefusal.ExpectedKind.clef` (`RemoveClef` aimed at something that is not a clef) and
  `EditRefusal.Reason.emptyStaffText` (`SetStaffText` given text that is empty once trimmed).
- `RespellMode` (`.simplest` / `.preferSharps` / `.preferFlats`) and `PitchSpelling.tpc(forPitch:keySig:mode:)`,
  which returns the one tpc for a pitch inside the twelve-wide line-of-fifths window that mode places around the
  key — the seam `RespellRange` and `TransposeRange(respellInKey:)` both spell through.
- The reference family — `MeasureRef`, `PartRef`, `VoiceRef`, `VoiceElementRange`
  (`Sources/SheetMusicCore/Score/References/`) — gives every new intent's score location a named, resolvable type
  instead of a bare integer, with `Score.canonicalStaff` / `score.contains(_:)` / `score[part:]` / `score[voice:]`
  / `score[measure:staff:]` / `score[system:]` / `score.voiceElements(in:)` as the sole resolution seam. Each
  member's wire mirror is a nested struct with a reserved tag, so a future stable identity (SP0) can attach to it
  without moving a byte.
- `Measure.Flags` groups the seven measure-level fields MuseScore writes on the first staff only — layout breaks,
  markers, jumps, `startRepeat` / `endRepeatCount` — so they move, hash and hoist as one unit.
- Eight note- and chord-level edit commands, closing the parity spec's Note/chord group: `SetArticulation`
  (toggle one articulation kind on a chord), `SetGraceNotes` (replace both grace lists), `SetTremolo` (a
  `.between` span is refused when the next timed element of the voice is not a chord — the follower is named by
  adjacency, not stored), `SetArpeggio` (needs two notes to spread), `SetGlissando` (refused on a note with no
  following chord, since the destination is implicit), `SetDots` (0–3, delegating the retiming to
  `SetChordDuration` / `SetRestDuration`), `SetChordLine` and `SetNoteParentheses`. Each has an `EditIntent` case
  and a wire payload (indices 50–57), so an Android or wasm host can relay them as bytes. `setArpeggio` travels
  as a subtype alone and its planner compares only that, so re-sending a stretched arpeggio's subtype does not
  reset its `timeStretch`; `Arpeggio.timeStretch` / `userLen1` and `ChordLine.isWavy` stay reachable only by
  building the command directly.
- `EditRefusal.Reason.noNextChord(at:)`, `.chordTooSmall(at:noteCount:)` and `.notDottable(at:)`. All three
  carry the `VoiceElementID` they were asked about, and the first two gate the write only — clearing an
  arpeggio or a glissando is never refused.
- `NoteDuration.baseAndDots()`, the inverse of `dotted(_:)`, and `ChordArticulation.Kind.mscxToken` /
  `init(mscxToken:)` — the MSCX token table moved into Core where the wire can reach it, with both MSCX paths
  delegating to it.
- A second parity replay chain (`editReplay-parity/`) exercises the twenty-eight new commands, in sixty-one
  steps, through the same cross-platform golden suites (Swift, WebAssembly, Kotlin) as the existing chain,
  byte-pinned like it.

### Changed

- `parseWithGeometry` takes the same raster fallback as `parse`. Its geometry side-car carries no rects and no
  page size for a page read this way — the page's glyphs are positioned in the analysis frame, not the
  displayed page's user space, and a cursor silently a few points off the ink is worse than none — and an
  `info` diagnostic names those pages; vector pages keep their geometry untouched. The entry points that never
  rasterize, `parseUsingSwiftReader` and the Android entry, say so with an `info` diagnostic instead of
  ignoring the classifier silently.
- The tuplet reader pads a raster-detected beam's member window by the same endpoint pad every other reader
  of a beam's range applies: a fitted raster slab stops inside its outermost stems, so the raw range dropped
  an end note and the mark with it. Vector beams are read raw, as before — padding them too moved one real
  corpus score, and the 141-score vector corpus is byte-identical with the pad confined to raster beams.
- A staff whose clef never arrived is reported as a warning instead of being assumed treble in silence, and a
  key-signature block the reader turned down is reported with what it read. Diagnostics only; the score is
  unchanged.
- Pages read by the detector get a per-part clef consensus: a system-initial clef the detector was unsure
  about is resolved against the same part's other systems, since a part's clef is one fact re-engraved every
  system. Confined to detector-read pages, so vector output is untouched.
- The example Mac app's "Import Music PDF…" reads scans through the bundled model and runs the import off the
  main thread.

### Fixed

- A tempo saved through this package is no longer invisible in MuseScore 4. `MSCXEncoder` wrote a `<Tempo>` with
  its `<tempo>` alone, and MuseScore 4 draws a tempo marking only through its text, so every tempo this package
  wrote re-opened as an empty marking on the page. The encoder now derives the printed marking from the beat,
  dots and BPM and writes it as the `<sym>` markup MuseScore's own palette uses, with `<followText>1</followText>`
  beside it — which is also what lets the decoder recover the beat from the printed number, so encode → parse →
  encode is a fixed point. A file whose printed marking disagreed with its `<tempo>` re-emerges with the marking
  its `<tempo>` means.
- `Score+FermataHolds`' comment on where a fermata sits was backwards: MuseScore 4's MSCX writes it BEFORE the
  chord it holds, like MusicXML, not after. Only the comment was wrong — the resolver already searched forward
  first, and its backward fallback stays for producers that trail the fermata after the chord.
- Repeat barlines now render. Nothing in `SheetMusicLayout` turned `Measure.startRepeat` / `endRepeatCount` into
  barline geometry — only `MultiMeasureRestPlanner` read the flags — so every MuseScore-authored score with
  repeats rendered without repeat dots. `LayoutEngine+SystemBuild` now synthesizes start-/end-repeat barlines from
  the flags, without double-drawing where an explicit `.barLine` of the same subtype is already present.
- Measure flags now survive `RemovePart` and `MovePart`. Both re-anchor brackets and system elements when the
  canonical staff (part 0, staff 0) changes hands, but left layout breaks, markers, jumps and repeat flags on the
  demoted staff — invisible to layout and export, which read them from the first staff only. A new
  `MeasureFlagsHoist` pass moves the flag column onto the new canonical staff and clears the old one, with the
  inverse carrying both staves' pre-image columns so undo stays byte-exact.
- `SplitRest` remaps tuplet indices after a split. Splitting a rest inside a measure that also holds a tuplet
  later in the voice shifted every subsequent element right by one without adjusting the tuplets' stored index
  ranges, so a later `RemoveTuplet` or duration edit could target the wrong elements.
- `Arpeggio.isAscending` treated MuseScore subtype 4 as a *down* arpeggio. MuseScore's order is `3` bracket, `4`
  up-straight, `5` down-straight (`TConv`'s `ARPEGGIO_TYPES`), so a file using either straight arpeggio played its
  notes in the wrong order — 4 top-down and 5 bottom-up. Subtypes 0–3, which is everything in this repo's
  fixtures, are unaffected.
- `MeasureStructure.adjustSpannerOffsets` walked `.spanner` voice elements only, so a chord-anchored slur — whose
  begin side lives in `Chord.spanners`, not as its own voice element — kept a stale `nextMeasuresOffset` across an
  `InsertMeasure` or `DeleteMeasure` inside its span, leaving the slur pointing at the wrong end chord. The walk
  now moves both shapes by the same rule.

## [2.3.1] - 2026-08-31

### Fixed

- `GMDrumset` engraves every drum where MuseScore Studio engraves it. The table's lines came from nowhere
  anyone could name and agreed with MuseScore on five of twenty-seven pitches: the kick sat a line above the
  space it belongs in, every tom was two lines off, and the low floor tom was written stems-down in the feet
  voice although it is played by hand. Seven heads were wrong too — most visibly the open hi-hat, which wore
  the closed hi-hat's plain cross and so could not be told apart from it. All of it is now transcribed from
  `share/instruments/instruments.xml`'s `<Instrument id="drumset">`, the block MuseScore itself builds a
  Drumset part from, with `smDrumset` covering the four pitches that block omits.
- Nothing migrates: a score written before this carries its own `<Drum>` lines and keeps them, because its
  notes are already engraved where the file says. The new values reach newly authored kits — `Score.blank`'s
  drum part, a MIDI import's invented kit, and a host writing drums through `SetDrumsetEntry`.

## [2.3.0] - 2026-08-31

### Added

- `SetPartNames` renames a part: the long name engraved at the left of the first system, and the abbreviation
  engraved there on every system after it. Both names travel in one command, so a host editing both gets one
  undo step rather than two that can be taken back into a half-renamed score, and `nil` clears rather than
  leaving a name alone — a part with no abbreviation engraves no label from the second system on, which is a
  thing a score can want to say. Reachable as `EditIntent.setPartNames`, which resolves to nothing to apply
  when both names already read that way, and over the wire as case 29.
- `Part.trackName` and `Instrument.id` are deliberately untouched by the rename, so a part called "なおき" keeps
  playing the piano it is: the sound, the transposition and the drum kit all key off the id, and `trackName` is
  where a host reads the instrument's own name back from.

### Fixed

- A part rename now invalidates the systems that draw its label. `LayoutCache.SystemInputs` carried no part
  name, and a rename touches no measure and no system-lane element — so every other input stayed bit-identical,
  the cached system was served, and the staff kept its old name on screen. The label the system actually draws
  is part of the key now (the long name on the first system, the abbreviation on the others), which also
  re-wraps the system when a longer name widens its opening indent.
- `EditIntentCodec.decode` bounds nesting while it parses, not after. The depth limit only ever ran on the
  finished tree, so a deeply nested `composite` payload overflowed the stack building that tree and never
  reached the guard. On WebAssembly the overflow did not even crash there: the shadow stack is 128 KiB and
  wasm-ld's default layout puts `.bss` directly beneath it, so the recursion overwrote the allocator's own
  state and the process died later inside an unrelated `malloc`. Both bridges feed this decoder bytes from
  the host — the browser's from JavaScript — behind a `try?` that cannot catch a stack overflow. Encoded
  bytes are unchanged, and the accepted nesting depth (8) is unchanged.
- WebAssembly artifacts link with a 1 MiB shadow stack (`-z stack-size`) and `--stack-first`, so an overflow
  traps at the function responsible instead of silently corrupting static memory. This restored the
  WebAssembly CI job, which 2.2.0 shipped red.

## [2.2.0] - 2026-08-30

### Added

- `GMDrumset` publishes the General MIDI drum kit as one table — line, notehead, voice, stem and name per
  pitch — absorbing the three private functions the MSCX encoder held them in, and `GMPercussion.drumLineMap`
  becomes its lines-only projection.
- `Instrument.drumset`: a score's own drum kit, decoded whole from `<Drum>` instead of for its `<line>` alone,
  so an imported chart keeps the notehead, voice, stem, name and shortcut it was written with and re-encodes
  to them. `Instrument.drumLineMap` is unchanged as the lines-only view, readable and writable as before.
- `CreateVoice` / `SplitRest` / `SetNoteHead` / `SetDrumsetEntry` edit commands, with
  `EditIntent.createVoice(staff:measureIndex:voiceIndex:)` / `.splitRest(at:tickOffset:)` /
  `.setNoteHead(at:headType:)` / `.setDrumsetEntry(partIndex:pitch:entry:)` and `EditIntentCodec` wire support
  (indices 25…28) — what drum note entry needs to route a key to its own voice, write at a caret's tick, give a
  note a cross notehead, and repair a kit that never named the drum being written. `.createVoice` and
  `.setDrumsetEntry` both plan to nothing when the score already says what they would write.
- `Score.blank(_:)` + `BlankScoreTemplate`: build an empty score in code — any number of parts, each with
  its own staves, instrument names, GM program, transposition pair and optional drum kit, plus `.normal`
  bracket groups over part ranges (SATB, string quartet). `Part.init(blankPlan:id:measures:)` is the
  per-part half, reusable by a command that appends a part to an existing score.
- `GMPercussion.drumLineMap`: the GM drum pitch → staff-line table, promoted out of the MIDI importer so an
  imported kit and an authored one place the same drum on the same line.
- `InsertMeasure` / `DeleteMeasure`: structural edit commands that insert or remove a full measure column
  (every staff plus the parallel `SystemMeasure`), each other's inverse. Inserting or deleting bar 0
  re-homes the score-start key/time/clef signatures onto the new first bar, mirroring MuseScore, and both
  commands fix up any `Spanner.nextMeasuresOffset` that spans the edit point. `DeleteMeasure` refuses to
  remove a score's last measure (`EditRefusal.Reason.cannotDeleteOnlyMeasure`).
- `EditIntent.insertMeasure(at:)` / `.deleteMeasure(at:)`: the host-facing intents `ScoreEditSession` plans
  into `InsertMeasure` / `DeleteMeasure`, with `EditIntentCodec` wire support (indices 14…15).
- `AddPart` / `RemovePart`: structural edit commands that add or drop a whole part, each other's inverse. A
  new part is built through the same `Part.init(blankPlan:id:measures:)` a blank score uses, and its bars are
  measure rests carrying the score's signature skeleton — the key / time signature each existing bar declares,
  so a mid-score signature change stays consistent across staves. Clefs are not copied; the part declares its
  own. Brackets follow the global staff order in both directions: one whose span crosses the insertion point
  grows by the inserted staff count, and a removal shrinks it or re-anchors it onto the first staff it still
  covers (`Score.filtered(hidingStaves:)`'s pass, now shared). A system element anchored into a removed part
  re-anchors on the score's first staff rather than being dropped, so a tempo survives its instrument, and
  `RemovePart` refuses to remove a score's last part.
- `EditIntent.addPart(plan:at:)`: the host-facing intent `ScoreEditSession` plans into `AddPart`, carrying a
  `BlankScoreTemplate.PartPlan` — the recipe, not a built part, so both images construct the same one — with
  `EditIntentCodec` wire support (index 16).
- `MovePart`: reorders the parts — a removal followed by an insertion of the same `Part` value, so
  `MovePart(from: 0, to: 1)` over `[A, B, C]` gives `[B, A, C]`. Its own inverse in shape
  (`MovePart(from: to, to: from)`), carrying the pre-image of every bracket and system-element anchor so the undo
  is byte-exact. `originalStaff` addresses are re-stamped through the permutation, and each bracket follows its
  anchor staff carrying its declared span — spans are not rewritten, matching MuseScore's `Score::sortStaves`;
  capping a span at the system's end stays a draw-time concern of `LayoutEngine.buildBrackets`.
- `EditIntent.removePart(at:)` / `.movePart(from:to:)`: the host-facing intents `ScoreEditSession` plans into
  `RemovePart` / `MovePart`, with `EditIntentCodec` wire support (indices 17…18). `.movePart(from: n, to: n)`
  resolves to nothing to apply rather than pushing an undo entry that restores the score to itself.
- `EditRefusal.Reason.cannotRemoveLastPart` (`edit.cannotRemoveLastPart`): what `RemovePart` refuses a last-part
  removal with. It used to borrow `.cannotDeleteOnlyMeasure`; a host switching over the reason can now tell the
  two structural minimums apart.
- `ScoreEditSession.partIndexMapping` / `consumePartIndexMapping()` / `isPartMappingIdentity`: where every part
  that existed at the last consume point (or at `init`) is now, `nil` for one that was removed. A host keys
  per-part state — mixer strips, per-staff flags — by index, and add / remove / move renumber underneath it; this
  is the map to migrate that state through. Derived by diffing `Part.id` snapshots, so undo and redo need no
  special handling, and cumulative rather than per-edit, so a host reads it once when it is ready to write.
  Duplicate ids in the baseline (a malformed file) yield the identity mapping rather than a guess.

### Changed

- A `.composite` intent's members are now planned one after another, each against the score the members before it
  left — not all against the score the composite started from. Every planner that reads the score (the cross-bar
  planners, the `.measure` promotion, the full-measure collapse) is asking about the state its own command will
  meet, and a write into a voice an earlier member creates used to ask that question of a voice that was not there
  yet.
- `NotePreviewPolicy` in `SheetMusicAudioCore` now owns those decisions for
  both platforms: which audition supersedes which, how long a drum rings
  against a melodic note, and how long the audio graph has to keep rendering
  after a note-off. `AndroidPlaybackEngine` reaches it over JNI
  (`nativePreviewPolicy*`) and executes the plan it answers with; the MIDI
  messages each engine sends are still its own, because FluidSynth and
  AUMIDISynth genuinely differ there. Android previously held a hand-written
  copy of the Apple engine's state machine, which is how it came to be
  missing both of the behaviours above.
- Android's master-tuning RPN comes from the shared `MasterTuning`
  (`nativeMasterTuningControlChanges`) rather than a Kotlin port of the same
  arithmetic kept in step by golden assertions on each side. Goldens catch a
  change made twice and made differently; they say nothing about a change
  made once.

### Fixed

- Re-anchoring brackets no longer leaves a hole in the bracket gutter. `column` is a horizontal coordinate —
  a bracket's spine sits at `staffOriginX - 0.5 sp - column * sp` and the gutter is sized `maxColumn + 1` — so a
  group bracket left at column 1 after the brace at column 0 went away with its part drew one `sp` further left
  than anything needed and reserved a column nothing occupied. `Score.reanchoredBrackets` now renumbers the
  columns still occupied onto `0 ..< n`, which fixes `RemovePart` (whose result is saved to the file) and
  `filtered(hidingStaves:)` (whose result is only displayed) in one place. The renumbering is global rather than
  per anchor staff, so brackets that share a column keep sharing one.
- Note auditions on Android no longer go missing while notes are entered
  quickly, and no longer click. A new audition now supersedes the one it
  replaces and invalidates its pending end — without which the old note's
  end fired on its own schedule and silenced the new one, audible only when
  the two shared a channel and pitch, so it presented as intermittent. The
  output stream is also held open past the note-off for the note's release,
  which used to be cut off mid-decay on every audition sounded from an idle
  reader. The Apple engine has carried both behaviours for a long time.

## [2.1.0] - 2026-08-29

### Added

- Guitar bends. MuseScore 4 `<GuitarBend>` spanners decode into the note
  model (with `<fret>` / `<string>`), encode back with real endpoint
  `<location>` markers, lay out as angular or slight bend geometry, draw
  in both the Canvas and CALayer renderers, and play: a bend chain sounds
  as one note whose pitch-wheel curve follows the written shape, grace-note
  bends and tied chains included.
- Legacy MuseScore 3 bends. The older `<Bend>` element — a curve of
  `<point>` pairs rather than a spanner — decodes into a `LegacyBend`
  model, lays out and draws through the same renderers, plays through the
  pitch wheel, and is written back into MuseScore 4's writer slot.
- Slurs between chords. Chord-anchored slur spanners decode and encode
  (with computed end markers, and hidden slurs staying hidden), and arc
  through the tie attach pass rather than being dropped.
- `SM_VELOCITY_DIR=… swift run render-previews` writes a note-on velocity
  digest for every score under a directory: count, a fingerprint over
  every `(tick, pitch, velocity)` triple, and min / mean / max. Playback
  work had no before/after gate — a dynamics change can move every note
  in a corpus without moving a pixel, so the PNG diff sees nothing.

### Changed

- Hairpins play the dynamics written along them. A wedge climbs to each
  mark, arriving on the beat it is written on, and carries on from there:
  every level played is either a mark the score states or an interpolation
  between two of them. A mark that contradicts the wedge — a crescendo
  running into a quieter mark — is not climbed to; that stretch stays
  flat and the mark still sounds at its own tick.
- A hairpin with nothing to aim at no longer invents a level. Previously
  a wedge with no bracketing dynamic ramped by ±10; that number is in no
  score, and it compounds — 31 of the 72 hairpin-bearing scores in the
  test corpus carry hairpins and not one dynamic. MuseScore 3.6 leaves
  such a wedge silent (`Hairpin::veloChange` defaults to 0), and both
  MuseScore generations export it flat. Scores that relied on the old
  behavior now need the dynamic written in.
- The level a hairpin reaches holds until the next dynamic, and a second
  wedge starts from it, as in both MuseScore generations. A crescendo is
  no longer undone by its own last note.

### Fixed

- A hairpin's end is measured from the hairpin, not from the bar line.
  MuseScore's `<location>` is relative to the spanner's own tick, so a
  wedge written from beat 4 to the next downbeat carries
  `<measures>1</measures><fractions>-7/8</fractions>`; measuring that
  from the bar line put the end *before* the start and collapsed the ramp
  to a single tick, which played as no crescendo at all. 27 of 667 corpus
  scores change. `OttavaRanges` and the layout's `endAnchor` already
  resolved it correctly — this was the third copy of the rule.
- A tremolo under a hairpin swells across its own strokes. The velocity
  was sampled once at the chord onset, flattening exactly the notes meant
  to carry the swell — a drum roll under a crescendo is the case this is
  written for.
- A crowded hairpin no longer draws backwards. The wedge is built with
  its apex at its start and its mouth at its end, so a span whose ends
  cross comes out mirrored, and a crescendo reads on the page as a
  diminuendo. Wedges now keep MuseScore's one-spatium minimum.
- A closed `FluidSynthDriver` is inert rather than fatal on Android.
- Opening a MuseScore 1 file says so, instead of reporting a MusicXML
  root element that was never going to be there. MuseScore 1 keeps the
  score's children directly under `<museScore>`, so the reader failed on
  a missing `<Score>` and the `.mscz` path then replaced even that with
  the MusicXML fallback's complaint. A `.mscz` whose container yielded a
  `<museScore>` document now reports the MuseScore reader's verdict.
- A slur starting on a rest arcs below without the parity branch, and a
  grace-note slur drop is diagnosed rather than silent.
- `<location>` is written measures-first in every target version. The v4
  writer emitted fractions-first, which MuseScore reads either way but
  no MuseScore-written file spells.
- Dropped `<Bend>` / `<GuitarBend>` properties and unread `<location>`
  fields on a chord-anchored slur are reported as diagnostics rather
  than skipped silently.

### Notes

- `LayoutElement` gains `.guitarBend` and `.legacyBend`, and
  `TextStyleType` gains `.bend`. Both are public non-frozen enums, so a
  host switching over them exhaustively needs a `default` clause. No
  public symbol was removed and no signature changed.
- Known, unchanged in this release: `.mscz` containers written with ZIP
  data descriptors (bit 3) cannot be opened; one corpus score is unstable
  across a second encoder pass (a trailing `<Tempo>` `<location>` moves
  from `1/4` to `5/8`); tremolo stroke counts are a fixed count per
  subtype rather than MuseScore's duration ÷ stroke length.

## [2.0.1] - 2026-08-26

### Fixed

- The Android audio writer is joined before its `AudioTrack` is released.
  `OboeStream.close()` released the track straight after `stop()`, and `stop()`
  only *asked* the writer to end: it spends most of its life inside
  `AudioTrack.write(..., WRITE_BLOCKING)`, a blocking native call rather than a
  suspension point, so `cancel()` could not reach it. Freeing the track under a
  thread still writing to it crashed natively inside
  `BpBinder::onLastStrongRef` — intermittently, and with a backtrace naming
  teardown rather than whatever triggered it. The same window let the writer
  call back into its `Producer` after `close()` returned, while
  `AndroidPlaybackEngine.teardown` was already tearing down the synth and the
  metronome mixer, so one missing join exposed three objects. `pause()` /
  `flush()` now precede the cancel, since they are what actually returns a
  parked write, and the join is bounded so a writer stuck beyond this class's
  reach cannot hang the caller. Reached far more often by a host that
  re-prepares playback per edit than by one that only tears down on leaving.
- A 64th flag anchors back along the stem, so its Y gets its own bound in the
  PDF importer.
- The PDF importer reads 5, 7 and 9 tuplet digits, not only 3 and 6.

## [2.0.0] - 2026-08-25

### Fixed

- `LayoutOptionsWire.showsLyrics` declares its compatible default, so the
  generated Kotlin `data class` gives it one too. 1.15.0 appended the field
  without one, and although the wire stayed readable by hosts that had never
  heard of it, the generated constructor gained a required ninth parameter —
  so every Kotlin host stopped compiling against a release that was supposed
  to be compatible with it. `1` is the value the field's own documentation
  already names as the safe direction (anything but an explicit `0` shows
  lyrics, which is what every release before 1.15.0 did), so a host that
  omits it gets exactly its previous behaviour. Requires swift-wirelet's
  Kotlin emitter to carry declared defaults.

### Added

- A durable playback position on the WebAssembly bridge. `playerSecondsForPosition` and
  `positionAtPlayerSeconds` convert between player seconds and a `{measureIndex, tickInMeasure}`
  musical address, and `PlaybackEngine` now parks its transport on the address rather than on a time.
  Seconds depend on the tempo map and on note durations, so an edit changes what a stored second
  means; an address does not. Android already carried this — `ScoreCursor` crosses its JNI boundary
  in both directions — and the wasm surface lost it when the cursor round trip was folded into a
  single call.
- Rehearsal marks, staff descriptors and measure frames on the WebAssembly bridge, closing the three
  gaps against the Android surface that had no recorded reason to exist. `rehearsalMarkCount` /
  `rehearsalMark` carry each mark's text, measure and player-clock seek target — every mark the score
  has, with `-1` seconds for one whose cursor does not resolve, because a navigation index missing a
  letter is worse than an entry that cannot be seeked to. `staffDescriptorCount` /
  `staffDescriptor` flatten the parts/staves tree the way `mixerStrip` indexes. `measureFrame` takes
  a measure index rather than Android's encoded cursor, since a browser host holds one.
- **A virtualized viewer, with zoom.** The browser example keeps canvases only for the tiles near the
  viewport and drops the rest, so what it rasterizes is bounded by the viewport rather than by the
  score: 80.4 MB of canvas for a 1,757 mm fixture and 151.8 MB for a 149-part score become 18–37 MB
  for both. `planViewportTiles` and `reconcileMounts` are exported for hosts that want the same
  policy. Zoom re-rasterizes at the new scale instead of upscaling a bitmap, and preserves the
  document position under the top of the viewport; `staffSize` remains the separate control that
  re-engraves. Scrolling still does not redraw — the compositor pans the mounted canvases.
- **Editing in the browser.** `Score` gains `beginEditing` / `endEditing`, a typed `applyEdit` over all
  thirteen scalar `EditIntent` cases, `applyEditIntentBytes` for a relayed composite, `undo` / `redo`,
  `editState`, `hitTest` and `caretRect`. An accepted edit publishes back into the same handle, so
  every downstream consumer keeps working across it. `EditReplayScript`'s fourteen steps now replay
  through the browser facade against the same fingerprint chain the Apple host and the Android device
  assert, so "the browser edits what the app does" is pinned rather than assumed.
- **Band culling in the browser renderer.** `splitIntoBands` slices a page's draw program into
  self-contained horizontal bands — a port of Android's `ScoreBands.kt` — and `drawTile` paints a
  tile from only the bands whose ink reaches it. A page too tall for one canvas previously walked
  its whole command list once per tile; on a 1757 mm fixture a 100 mm tile now walks 10% of the
  page. `drawPage` is unchanged for pages that fit a single canvas.
- **Layout options on the WebAssembly bridge.** `computeLayout` takes a `LayoutOptions` struct —
  layout mode, staff size, break handling, multi-measure rests, invisible elements, lyrics,
  transposition, hidden staves and clef overrides — reaching the settings Android's display
  inspector has had. The browser facade fills every field from the vertical default, so a caller
  that passes none gets what it got before.
- **Playback in the browser.** `@jiyimeta/sheet-music-web/playback` plays a score, follows it with
  a cursor, and supports a measure-range loop with its highlight, a metronome, a count-in, a
  playback rate and a mixer (per-strip patch, level and mute). The synth is the host's: Swift
  renders the score and metronome SMFs and answers positional questions, and the default engine is
  spessasynth_lib, declared as an optional peer dependency so a viewer never downloads one. A
  different synth can be substituted by implementing `SynthHost`.
- `mixerStripCount` / `mixerStrip` on the WebAssembly bridge, and `Score.mixerStrips()` on the
  browser facade. `PlaybackEngine` asserts each strip's patch and level at load and after every
  transport move — the sequence carries neither, by design, so that a backward seek cannot replay
  them over a live override.
- Click-to-seek, and a count-in from anywhere rather than only a downbeat. `playerSecondsAtPoint`
  resolves a point in document millimetres to the nearest playable element (`nearestEngineCursor`,
  as on Android) and folds the cursor round trip into one call; `renderCountInMetronomeMidi` and
  `countInSeconds` now take a position on the player's clock, which is what lets `CountInBeats`
  schedule the partial lead-in a mid-bar start needs.
- Solo, master tuning and a replaceable metronome click on the browser mixer.
  `setStripSoloed` silences everything not soloed while remembering each strip's own mute
  underneath; `setMasterTuning` sends the MIDI master-tuning RPN built by
  `SheetMusicAudioCore.MasterTuning`, so an A4 calibration means the same thing here as on iOS and
  Android; `setMetronomeClickSoundFont` layers a bank from `buildClickSoundFont` ahead of the
  score's, on the metronome synth only.
- **Audio export in the browser.** `PlaybackEngine.exportWav()` renders the score — or a measure
  range — to 16-bit PCM offline and faster than real time, carrying the mixer as it stands. The
  mixer travels as a snapshot of the live synth rather than being re-applied, so the file cannot
  drift from what is being heard. `encodeWav` is exported separately, and `SynthHost.renderOffline`
  is the optional seam a custom synth implements — the counterpart of Apple's
  `SynthBackend.makeOfflineInstance`. WAV only for now: M4A and MP3 need WebCodecs or
  `MediaRecorder`.
- `gmInstrumentNames` / `gmInstrumentFamilies` on the WebAssembly bridge, and
  `SheetMusic.gmInstruments()` on the browser facade: the 128 General MIDI patches with their
  families, for a mixer's patch picker. Read out of `SheetMusicAudioCore.GMInstrument`, the same
  table the iOS and Android mixers show — Android loads it over JNI for the same reason.
- Eleven `@JS` entry points on the WebAssembly bridge behind that — `renderMidi`,
  `renderMetronomeMidi`, `renderCountInMetronomeMidi`, `countInSeconds`, `playbackSummary`,
  `metronomeBeats`, `cursorRectAtPlayerSeconds`, `playerSecondsForMeasure`,
  `measureIndexAtPlayerSeconds`, `loopPlayerSeconds`, `loopHighlightRects` — plus
  `buildClickSoundFont`, which the Android bridge has had since the metronome landed.
- `SheetMusicBridgeCore.PlaybackClock`: the projection between a browser sequencer's seconds clock
  and the notated score. Android round-trips through unrolled ticks because FluidSynth reports one;
  a Web Audio sequencer reports seconds, and `UnrolledTimeMap` already speaks them on both sides.
- `SheetMusicLoader`, a small static product holding the one decision about
  which parser a score payload belongs to. `ScoreLoader.sniff` /
  `loadScore(bytes:sourceFilename:)` / `loadScore(contentsOf:)` are the logic
  `ScoreBridge` used to own privately; `ScoreBridge` now delegates and keeps its
  API, and `SheetMusic` gains matching `loadScore(bytes:)` /
  `loadScore(contentsOf:)` overloads. It exists because a consumer that parses
  score files in its own image could not reach `ScoreBridge` at all — it lives in
  `SheetMusicBridgeCore`, which is not exported, and the one product that carries
  it is `.dynamic`, while a `Score` cannot cross between two `SheetMusicCore`
  copies. So such a consumer wrote the format table out again, and the copy fell
  behind: Folino's Android edit session read every stored score as a MuseScore
  container, and silently refused to open over the four other formats its own
  importer accepts. A static target compiles into each image, which is what lets
  one declaration serve them all. `sourceFilename` carries the MIDI title
  fallback that a byte-level entry point would otherwise drop.
- Kotlin codecs for the two editing-geometry payloads, `SelectionTint` and
  `EditCaretFrame`. `nativeEncodeDrawProgram` takes the first and
  `nativeEditingCaretFrame` answers with the second, but both live in
  `SheetMusicEditWire/Geometry` while the Android codegen only ever scanned
  `SheetMusicEditWire/Path` — so a Kotlin host could call either entry point and
  had no way to build or read its payload. Hand-writing one would have put a
  second spelling of a frozen schema in a second language, which is the thing a
  single shared wire product exists to prevent. The two types move into their own
  directory (a `schemaPaths` entry must resolve to exactly one directory, and the
  edit-*intent* vocabulary in the neighbouring `Intent/` must stay unemitted —
  Kotlin never builds an intent) and a new `editGeometry` source set emits them,
  models included. Byte agreement with the Swift codecs is pinned by
  `editCaretFrame-v1.bin` / `selectionTint-v1.bin` in the existing cross-language
  golden set.

### Changed

- **Breaking.** A tapped `.tuplet` now crosses `Score.engineCursorForFilteredTap` and
  `translateCursorForHiddenStaves` re-addressed like `.note` and `.rest`, instead of passing through
  in the rendered document's numbering. With a hidden staff ahead of a tuplet's own staff in the same
  part, a hit-test result fed into an edit intent named the wrong staff. Hosts holding a tuplet id
  across a visibility change now hold the full-score address; the `.tuplet` special-cases in the
  Android geometry bridge are gone with the mixed contract that forced them.
- `LayoutDocument.editingCaretRect` resolves a caret for a selected tuplet, anchored to the column of
  the bracket's first member. It previously returned nil, because it goes through `cursorFrame` and a
  playback head never sits on a bracket — correct for a playback head, wrong for an editing caret.
- `releaseScore` on the WebAssembly bridge also ends any open edit session, so a session cannot
  outlive its handle.
- **Breaking.** `computeLayout` on the WebAssembly bridge takes a `LayoutOptions` argument. There is
  no options-less overload: two entry points into the same engraver drift, and the browser facade
  supplies the defaults instead.
- **Breaking.** The WebAssembly bridge's byte-blob faces take and return `Uint8Array` rather than
  `number[]`. BridgeJS lowered a `[UInt8]` parameter one wasm import call per byte and lifted a
  `[UInt8]` return into a boxed JavaScript array; `loadScore` on a 1 MB score went from 41.8 ms to
  16.6 ms. The `[Double]` faces are unchanged — their payloads are small and cross once per user
  action.
- `pageBreaks` on the WebAssembly bridge derives its break policy from the options the document was
  laid out with, as Android does, instead of always honouring layout breaks. Previously unobservable
  because options could not be set; now it would answer with boundaries the document does not have.
- **Breaking.** `SheetMusicError.malformedScore` and
  `SheetMusicError.corruptedContainer` now carry a structured `ScoreFault`
  instead of a free-text reason, and `SheetMusicError.invalidEdit` now carries
  an `EditRefusal` with a typed refusal `reason`. Hosts should switch over the
  structured payloads and use their stable codes for presentation instead of
  matching English strings.
- `AudioMidiBridge` and `LoopHighlightTickResolver` moved from `SheetMusicAndroidJNI` to
  `SheetMusicBridgeCore`, so Android and WebAssembly share one implementation. The `native*` entry
  points stayed behind — jextract only makes a JNI symbol where the declaration physically sits.
  No behaviour change on Android.

### Fixed

- A layout computed while an edit lands is no longer cached against the edited
  handle. `nativeComputeLayout` reads the score at its start and files the
  document at its end without the edit lock, so an intent applied in between left
  a layout of the *old* score cached against a handle whose score was new —
  invisible to the fingerprint gate, which compares scores rather than layouts.
  `LayoutDocumentCache` now carries a per-handle generation: the compute stamps
  it before reading, `nativeApplyEditIntent` / undo / redo advance it through
  `invalidate`, and a store whose stamp has been superseded is refused, leaving
  the cache empty rather than stale. Empty is the right answer — the edit has
  already requested the recompute that repopulates it, and in the meantime
  `nativeEditingHitTest` returns nothing instead of naming an element the user
  did not tap, which since 1.11.0 would have become the target of the next edit.


## [1.15.0] - 2026-08-17

### Added

- `Score.fermataHolds()` — every fermata resolved to the chord it holds, merged across staves. It
  is now the single derivation of that anchoring: `MidiRenderer`'s tempo bookends and the
  notated-time API both read it, so the SMF's idea of a hold and the score's cannot drift apart.
- `MidiRenderer.swingOnsetShifts(score:)` — how far swing pushes each sounding chord's onset, for
  callers that need the audible attack without the renderer.

### Fixed

- `notatedDurationSeconds`, `seconds(at:)` and `cursor(atSeconds:)` count fermata holds. They summed
  each bar's tick length at its governing tempo and stopped there, so a score with fermatas reported
  as shorter than it plays and every elapsed / total readout drawn from them ran short by the sum of
  every hold.
- `PlaybackTimeline.frame(atTime:)` — the cursor's own lookup — follows the AUDIBLE onset, so the
  playhead steps onto a swung eighth when it sounds rather than up to a tenth of a beat early. The
  new `Frame.soundedTimeSeconds` carries it; `timeSeconds`, `frame(atTick:)`, `seconds(atTick:)` and
  `totalSeconds` are unchanged, so nothing that addresses the score by position moves.

### Added

- `sheet-music-compose-android` is published. Its publication block has been
  complete since the module landed, but every release so far ran only the two
  other publish tasks, so the module existed at no released coordinate and a
  consumer that wanted the score canvas or the playback-cursor overlay could not
  resolve it at all. **All three Android coordinates must now be pinned to the
  same version.** `DrawProgramReader` validates the draw-program version the
  native library produces, so a mismatched pair throws at the first strip drawn
  — on a device, in a feature nothing would connect back to a version line. The
  module's `proguard-consumer.pro` now records *why* it contributes no consumer
  keep rules, its keep-rule story being consumer-facing for the first time: it
  is ordinary Kotlin and Compose with no reflective entry point, no JNI
  registration and nothing looked up by name, and the rules that do matter
  belong to `sheet-music-android`, which owns the JNI boundary, and to the app.

- `ScoreViewOptions.lyricsVisible` (default `true`), with `showsLyrics` appended
  to `LayoutOptionsWire` as a ninth field for the Android bridge. The engraver's
  only lyric gate was MuseScore's per-element `visible` flag, which is the
  score's own authoring state rather than a display choice, so a host offering a
  "show lyrics" switch had nowhere to put it. Hiding removes the whole lyric row
  — the syllables, the hyphens between them, the melisma rule that follows a
  held syllable, and the continuation segments an earlier measure's melisma
  pushes into later ones — and nothing is routed to the invisible container
  either, so `showsInvisibleElements` cannot bring it back. The engraved
  document is therefore genuinely shorter, which is the point: a host fitting a
  fixed-height notation strip to the engraved height gets a different number,
  where a gate that suppressed the glyphs but kept their vertical slot would
  change nothing on screen. On the wire, anything other than an explicit `0`
  shows lyrics, so a host that has not been updated keeps the behaviour every
  earlier release had.

- `groupRawValue` on the staff-params wire (tag 13), carrying `Staff.group`. The
  only percussion signal the wire had was `isDrums`, derived from the part's
  `instrument.useDrumset` — but a pitched-percussion staff (timpani,
  glockenspiel) has `useDrumset == false` while its `<StaffType group="…">`
  still reads "percussion", so an Android host keying a drum-kit UI on `isDrums`
  alone over-offered exactly the staves Apple hides. Appending is safe for an
  **older** consumer meeting a **newer** payload — it skips the tag — and not
  the other way round: the generated decoder throws when a declared tag is
  absent, so a build carrying the new decoder must not meet a native library
  older than the field. The AAR and the `.so` ship in one artifact, so the only
  way to produce that is a partial version pin across the three coordinates.

- `nativeSecondsAtTick(scoreHandle, unrolledTick)`, bridging
  `PlaybackTimeline.seconds(atTick:)` — public and Android-compatible for
  several releases with no JNI symbol. The only position an Android host could
  read was `nativeFrameAtTick`, whose `timeSeconds` snaps to a frame onset, and
  interpolating two polled frames cannot recover the value in between because
  those times are themselves quantized: the result steps once per note however
  often it is sampled. The tick is in the same unrolled coordinates the
  FluidSynth player reports, fractional ticks included. An unknown handle
  returns `-1` rather than `0`, since `0` is a real position.

- `AndroidPlaybackEngine.audioClockPosition()`, returning the transport's tick
  together with `AudioTrack.getTimestamp()`'s frame position and the
  `System.nanoTime()` instant that frame was presented, so a host can
  extrapolate a playhead from the audio clock. `currentTimeSeconds` and
  `currentCursor` are written from a 33 ms poll, so their timestamp is when the
  poll observed the transport rather than when the audio was heard, and anything
  smoothing between polls inherited the poll's jitter. A read rather than a
  flow, on purpose — publishing it would put it back on the poll's cadence and
  lose the only thing it adds. Nullable, because `getTimestamp` is best-effort
  by contract (it reports nothing before enough audio has been written, and
  nothing at all on routes that carry no timestamp), so a host can tell "no
  better information" from "position zero". Purely additive: neither existing
  flow changes, and a host that never calls it behaves exactly as before.

### Changed

- The whole-score transpose clamp widens from ±7 to ±12 semitones. A diminished
  fifth either way was too narrow for what the feature exists for — moving a
  song out of its written key for a singer routinely needs an octave — and the
  MIDI coarse-tuning RPN carries ±64 semitones, so the old bound bought nothing.
  The clamp lives in three places and they move together: the Apple engine's
  `setTranspose`, `AndroidPlaybackEngine.setTranspose`, and the notation half in
  `LayoutOptionsWire.transposeDelta`. Widening only the audio side would leave a
  score sounding transposed past the narrower bound while still reading in the
  written key, which is worse than either limit alone. The doc comments that
  spelled out the old range — including the one on the wire field, which is
  mirrored into the generated Java — move with it.

### Fixed

- **Android:** the playback transport no longer confuses the notated score
  clock with the unrolled render it actually plays. `AndroidPlaybackEngine`
  reads notated ticks out of `frameForCursor`, `itemEndTick` and the timeline
  summary's `totalTicks`, but everything it hands the FluidSynth player
  (`seekTick`) or reads back from it (`currentTick`) is in the repeat- and
  jump-expanded coordinates of the rendered SMF — and the two were used
  interchangeably. The read direction was already translated (`frameAtTick`
  maps the player's tick back through the unroll); the write direction was not.
  On a score with a repeat this made A-B looping unusable rather than
  inaccurate: an A-B region placed *after* a repeat had its end compared against
  a player position that was already past it, so the wrap fired the instant the
  repeat finished — before a note of the selected region had sounded — and then
  seeked to the notated start tick, which in transport coordinates lands inside
  the repeat. The result cycled two bars the user had not selected and never
  reached the ones they had. `setLoopFullScore` truncated the same way, and the
  same misprojection sent `seek(ScoreCursor)`, `seek(toTimeSeconds)` and `skip`
  to the wrong measure once a repeat had been passed, while `skip` additionally
  fed a notated estimate to `frameAtTick`, which takes unrolled ticks. A score
  without a repeat plan is unaffected — the two clocks are the same map there,
  which is why this survived the Apple-side fix and every existing loop test.
  `loopRange` is unchanged and still notated: it is a region of the *score*, so
  that is what a host persists and maps back through its own measure table. The
  engine now caches the region's projection onto the transport alongside it,
  deriving the end as `start + notated span` rather than projecting the end tick
  separately, so a loop over a repeated bar covers that bar's own pass instead
  of swallowing the repeat's second take. The projection itself is
  `PlaybackUnroll.firstUnrolledTick(forNotated:)` — the rule the Apple engine
  already schedules by, now hoisted out of `PlaybackEngine` so both platforms
  share one implementation — reached through the new
  `nativeUnrolledTickForNotated` JNI entry point. `JniBridge` gains a matching
  member with an identity default, so a bridge predating the entry point keeps
  today's behaviour.

- **Android:** an offline audio export now reproduces the live engine's
  transpose and A4 calibration. Transposed playback is a tuning shift on the
  melodic channels rather than a re-render, so the SMF the exporter loads holds
  the *authored* pitches — and `ExportEngineSnapshot` carried the mixer, the
  metronome and the rate but no pitch state at all, while the exporter builds
  its own synth, which starts at concert pitch. A score transposed on screen
  therefore exported in its original key, and an A4 calibration was dropped the
  same way: silently, on every device, with the file itself the only evidence.
  The snapshot gains `masterTuningCents` and `transposeSemitones`, populated
  from the live engine where the mixer is captured, and `AudioExporter` applies
  them through the same MIDI Master Tuning RPN the live engine uses — melodic
  channels take calibration + transpose at 100 cents per semitone, percussion
  the calibration alone, so a transposed score's kit stays where it was written.
  That split is the one Apple's `PlaybackEngine+Export` already makes. Zero is
  skipped rather than sent as a no-op RPN, mirroring the live engine's guard at
  prepare, so an untuned export emits exactly the sequence it emitted before.

- **Android:** a Standard MIDI File can be imported. `MidiImporter` has always
  existed and Apple hosts call it directly, but the Android score bridge sniffed
  ZIP, `<museScore` and `<score-partwise>`/`<score-timewise>` only, so a `.mid`
  fell through to `loadScore`'s `.unknown` case and threw — which a host
  surfaces as a failure to load the score. The `MThd` header chunk is now one of
  four recognized magics and routes to `MidiImporter.parse`. This closes a
  parity gap rather than fixing a regression: `.mid` import has never worked
  through the Android bridge in any release. It adds no dependency and no native
  size — `SheetMusicAndroidJNI` already depends on `SheetMusicMIDI` for MIDI
  rendering — and the JNI signature is unchanged, so a host needs nothing beyond
  accepting the extension at its file picker. The importer's `sourceFilename`
  hint stays `nil`; the host titles the score from the picker's display name.

- `nativeCursorFrame` and `nativeLoopHighlightRects` no longer describe payloads
  that have not existed for several releases, in the direction that costs a
  consumer the most: both KDocs named a byte layout precise enough to write a
  reader from — a `u16` version word followed by microsecond `i64`s — and a
  reader written from either decodes garbage. `nativeLoopHighlightRects` had
  three mutually inconsistent accounts in circulation. The wire is wirelet TLV,
  and both now name the generated codec to decode with (`DecodedFrameCodec` and
  `RectCodec` respectively). `nativeMeasureFrame` refers to `nativeCursorFrame`
  for its format, so it is corrected with it. No signature and no wire change.

- `SheetMusicEngine.version` names this release. It still read `1.13.1` at tag
  `1.14.0` — that release commit changed only a CHANGELOG heading. Nothing was
  broken by it, since both images derive their stamp from the same constant and
  so agreed with each other, but the constant feeds the Android version-skew
  gate through `nativeEngineVersionStamp`, and a stamp that names the wrong
  release is exactly what a skew gate cannot afford.

- A `<MeasureRepeat>` bar now occupies its bar on `PlaybackTimeline`'s measure
  spine. The spine counted chords and breath pauses only, while
  `MidiRenderer.measureTicks` counts the marker's own duration, so every measure
  after a `𝄎` started a full bar early on the cursor's timeline and the playhead
  ran a measure ahead of the audio for the rest of the piece. `totalTicks` was
  short by a bar for a score ending on one, too.

- An A-B loop is now projected onto the transport's own coordinates before it is
  compared against or seeked with. `LoopRange` is a region of the score, so it is
  stored (and handed back to the host) in notated ticks — but the transport plays
  `MidiRenderer.render`'s UNROLLED sequence, where the same bar sits at one
  position per pass and generally at none of its notated ticks. On a score with a
  repeat, a region after it therefore wrapped a measure-play early and then
  replayed from wherever the sequence happened to be that many notated seconds
  in, i.e. a different passage than the one the host had highlighted. The new
  projection resolves the region's first occurrence and carries the span across,
  so a loop over a repeated bar covers that bar's own pass rather than swallowing
  the repeat's second take.

  The same confusion ran through every other transport move — `seek(to:)`,
  `play(from:)`, the count-in's base position and its metronome offset — which
  all handed a notated tick straight to the sequencer. `SynthBackend` gains
  `setUnrolledTimeMap(_:)` (default no-op, so existing conformers are unaffected)
  and `SwiftySynthBackend` runs both `seek(toTick:)` and `currentTick` through it,
  which is what lets the engine keep speaking notated ticks throughout.

- **Apple example apps:** exporting while a transposition was active wrote the
  file in the *authored* key. Every export entry point handed the raw loaded
  score to the serializer, so `Score.transposed(bySemitones:)` only ever reached
  the on-screen engraving — PDF, MSCX (MS4 / MS3), MSCZ and MIDI all silently
  reverted. The macOS app now serializes the transposed score for the file
  exports and the full display transform for PDF (a PDF is a rendering, so it
  matches the view, hidden staves and all; a saved `.mscx` / `.mscz` keeps the
  staves the source file marked `<show>0</show>` rather than dropping music on
  save). The iOS app's PDF export takes the same transform. Audio export is
  deliberately unchanged — the offline render reproduces transposition as a
  tuning shift from the engine snapshot, so transposing the score there too
  would double it.

  The library itself was never affected; `TransposedScoreExportTests` now pins
  that (transpose → encode → reparse keeps the keys and pitches for MSCX, MSCZ
  and MIDI) so a future regression is unambiguously attributable.

- A fermata is now one score-global tempo fact rather than a per-staff one, which
  fixes two bugs at once on any score that has both a fermata and a tempo marking.

  `render(score:)` realises a fermata's hold as a pair of tempo bookends around
  the held chord, and it used to build that pair separately for every staff,
  against the tempo markings `filterSystemElements` routes to *that* staff. A
  system-level `<Tempo>` goes to the canonical staff alone, so every other staff
  computed its hold against the 120 BPM default and emitted a CLOSE event
  restoring 120 BPM. Tempo metas are score-global once a sequencer merges the
  tracks, so that bogus restore outranked the real marking — a score marked
  ♩=79 after a fermata played the rest of the piece at 120 BPM. The bookends are
  now computed once, from the union of every staff's fermatas against the whole
  of `systemMeasures`, and emitted into the first track only.

- `PlaybackTimeline` folds the same fermata bookends into its own tempo map, via
  the new `MidiRenderer.fermataTempoBookends(score:)`. A fermata carries no
  notated duration, so a timeline built from `<Tempo>` markings alone never held
  — leaving the playback cursor running ahead of the audio by the hold's extra
  time, permanently, from the first fermata onward, and taking every elapsed-time
  read and A-B loop boundary with it.

## [1.14.0] - 2026-08-14

### Added

- `PlaybackEngine.AudioSessionPolicy`, a new `init` parameter that decides when
  the engine claims the process-wide `AVAudioSession`. `prepare(score:)` used to
  unconditionally take an exclusive `.playback` session, so a host that prepares
  a score when a screen merely *opens* interrupted whatever the user had playing
  in another app long before they asked for any sound — and a note-tap preview,
  which rides the session `prepare` left active, inherited that.

  - `.exclusiveOnPrepare` (default) is the previous behavior, unchanged.
  - `.mixUntilPlay` prepares with `.mixWithOthers` — other apps keep playing and
    `playPreview` mixes over them — and drops it on the first `play(...)`, so the
    interruption lands on the user's press of play. A re-prepare after that (a
    SoundFont hot-swap) does not demote the session back to mixing; `teardown()`
    resets the claim.
  - `.hostManaged` has the engine never touch `AVAudioSession`, for a host with
    its own session requirements (a tuner holding `.playAndRecord` for live pitch
    tracking) that would otherwise undo the engine's category write after every
    `prepare`.

  The 48 kHz preferred-rate pin that un-sticks a wedged system I/O rate now runs
  on the `.mixUntilPlay` escalation too, not only at prepare: while mixing, the
  app that already owns the route decides the rate, so going exclusive is the
  first moment the request can be granted.

### Fixed

- Key signatures are now placed against the clef in force, so an F-clef staff's
  accidentals sit a line lower than a G-clef staff's instead of on the treble
  positions. MuseScore keeps one 14-entry line table per clef
  (`ClefInfo::lines`, `engraving/dom/clef.cpp:50-83` — the first seven for
  sharps, the last seven for flats) and `TLayout::layoutKeySig` scans back for
  the clef segment at the key signature's own tick before placing a single
  glyph. This project had one hard-coded treble table, and
  `LayoutElement.keySignature` carried no clef for a renderer to consult, so
  every clef drew the treble cluster; a bass staff's E♭ major read a third too
  high. The tables are transcribed rather than derived because two of them are
  not the treble table shifted uniformly: the tenor (C4) and soprano (C1) rows
  raise individual accidentals by an octave to keep the cluster off ledger
  lines, so tenor F♯ sits *below* C♯. The three renderers (SwiftUI, CALayer,
  and the Android draw-command bridge) now all resolve their steps through
  `KeySignatureSteps` — the CALayer path had grown its own third copy of the
  treble table.
- Chord symbols imported from MuseScore no longer read a perfect fourth too
  high, and no longer lose their slash bass. Two independent defects on the
  same path:
  - The TPC → letter table was anchored one fifth away. `Tpc` starts at
    `TPC_F_BBB = -8` (`engraving/dom/pitchspelling.h:40-51`), putting the
    naturals at `F = 13, C = 14, …` — the origin `SheetMusicCore.PitchSpelling`
    and `PitchStaffPosition` already document — while `HarmonyRendering`
    assumed `F = 14`. Every root came out a fifth flatward: an imported `Fm7`
    rendered `B♭m7`, `E♭M7` rendered `A♭M7`. Confirmed against MuseScore 4.7.4
    itself, which writes `<root>13</root>` for an F root.
  - MuseScore 4.6 renamed the slash-bass tag from `<base>` to `<bass>` (and
    `<baseCase>` to `<bassCase>`) — compare `rw/read460/tread.cpp:2957-2986`
    with `rw/read410/tread.cpp:2991`. The decoder read only the historical
    spelling, so `Fm7/B♭` from a current MuseScore imported as `Fm7`. Both
    spellings are accepted now.
- MuseScore-v4 export no longer loses every chord symbol. We declare
  `version="4.60"`, so MuseScore reads the file with read460 — which does not
  recognize `<name>` / `<root>` / `<base>` as direct children of `<Harmony>`
  and drops them, leaving a `Harmony` with no `HarmonyInfo`, which
  `TWrite::write` then skips entirely. The v4 encoder now emits the
  `<harmonyInfo>` wrapper and the `<bass>` / `<bassCase>` spellings; the v3
  target keeps the flat layout its readers expect. Measured with MuseScore
  4.7.4: 0 of 4 chord symbols survived the round trip before, 4 of 4 after.
- Transposing a score now moves its chord symbols with the notes.
  `Score.transposed(bySemitones:)` shifted key signatures and chords but let
  `.harmony` fall through untouched, so a transposed lead sheet's symbols named
  the original key while the staff under them named the new one.
  `Harmony.rootTpc` / `bassTpc` now shift by the same fifths delta the notes
  use, preserving each root's degree in the key; `Harmony.name` is only the
  quality suffix and a text-only symbol (no root TPC) passes through unchanged.
- Grace notes now sit where MuseScore puts them, in both directions. MuseScore
  stores every grace of a chord — before *and* after type — in one vector and
  writes the whole vector **ahead of** the parent chord's own `<Chord>`
  (`TWrite::write(const Chord*, …)` iterating `Chord::graceNotes()`); its
  reader mirrors that, buffering every consecutive grace-type `<Chord>` and
  attaching the run to the **next** normal chord, splitting it by grace-type
  tag rather than by file position (`MeasureRead::readVoice`). This project
  did neither: the encoder wrote after-graces *behind* their owner and the
  decoder attached them by walking *backwards* to the most recent chord. The
  two were exact mirrors of each other, so this library's own round trip was
  byte-clean and no existing test could see any of it, while both directions
  of real MuseScore interop were wrong — an after-grace written on chord *N*
  was read by MuseScore as belonging to chord *N+1* (or dropped when no chord
  followed in the bar), and an after-grace in a genuine MuseScore file was
  read here as belonging to chord *N-1* (or dropped when its owner opened the
  bar). Settled against upstream fixtures rather than inferred:
  `midirenderer_data/grace_after.mscx` writes a `<grace8after/>` ahead of the
  very first chord of its measure, a position no "after-graces follow their
  owner" reading can explain.

  The split back out of that single run is asymmetric — `graceNotesBefore()`
  filters it forward, `graceNotesAfter()` filters it **in reverse** — so a
  multi-note Nachschlag was also being read (and played) back-to-front.
  Pinned against upstream's own playback expectation for
  `single_note_multi_appoggiatura_post`, whose file order is `<grace32after/>`
  A4 then `<grace16after/>` G4 but whose sounding order is F4 → G4 → A4.
  `Chord.graceNotesAfter` holds the sounding order, so it is reversed on the
  way in and out. Both fixtures are now in the test suite, which is the only
  kind of evidence that can answer these questions — this project's own
  parse → encode → parse round trip is blind to all of them by construction.

- A grace tie now names the right chord in the direction that leaves the
  parent. A grace shares its parent chord's tick, so "zero delta, same
  measure" is right only for the tie direction that stays inside the parent;
  sounding order fixes which that is. A before-grace sounds ahead of its
  parent, so its `tieBack` can only come from the *previous* main chord; an
  after-grace sounds past its parent, so its `tieForward` reaches the *next*
  one. Both were previously written as the zero-delta location, naming the
  parent — a partner MuseScore then fails to match, dropping the tie on
  reload. Where no such neighbour chord exists, no `<location>` is written at
  all rather than a confident guess, which could additionally mis-connect the
  tie to whatever note happens to sit at the named position.

- A tied Nachschlag — a main note tying forward into one of its own
  `graceNotesAfter` — now carries `<next><location><grace>N</grace></location>`,
  the mirror of the tied-acciaccatura fix shipped in 1.13.1. It was
  deliberately left out then: an after-grace was written behind its owner, so
  a computed ordinal would have named a grace of the wrong chord. The ordinal
  itself is now derived from the combined before + after file run rather than
  from the position within `graceNotesBefore` alone, which is what
  `Location::graceIndex` actually means.

- Ties involving a **multi-note** chord survive a reload — grace ties and
  ordinary chord-to-chord ties alike. MuseScore's endpoint match compares full
  `Location` equality including `m_note`, and no tie this project wrote emitted
  `<notes>`, so the comparison was always `0 − 0`. That is correct only when
  both tied notes are alone in their chords (or rank the same in both); any
  other pairing — a note that ranks second in one chord and is alone in the
  other, say — was silently dropped by MuseScore on reload. Both sides of both
  tie kinds now emit the delta. The index is the note's rank **by pitch**
  within its chord (`Chord::notes()` is kept pitch-sorted by `Chord::add`), not
  its position among the `<Note>` elements, which this project's `ChordNotes`
  does not sort. A tie leaving the last chord of a measure needs the next
  measure's first chord to measure against, which the measure-at-a-time encoder
  cannot see on its own; `Staff.encodeTopLevel` now supplies that one-measure
  look-ahead.

  Known gap: a tie between a grace of one chord and a note of the
  *neighbouring* chord — a Nachschlag tied into the next note — is written
  correctly on the grace's own side but not on the other, whose `<location>`
  would need `<grace>` naming an ordinal in a chord it has no view of. Such a
  tie is still dropped on reload, as it was before.

- The count-in works again on the SwiftySynth backend — the path every live
  playback takes — where it had two bugs a host reported together: it never
  counted at all while a loop was active, and when it did count it clicked
  with the score SoundFont's GM wood block instead of the host's click
  samples. "Repeat whole score" pushes a whole-score loop into the engine, so
  for anyone practising with repeat on, the count-in simply did nothing.

  Both came from the same decision. The backend path built its count-in by
  shifting the SCORE SMF behind a click track baked into it. That click
  therefore played on the score synth — which loads the score's SoundFont; the
  metronome synth is the one holding `metronomeSoundfontURL` — and it left
  every score-tick read (seek, loop wrap, end detection) speaking a shifted
  coordinate space, which is why a loop had to suppress the count-in rather
  than compose with it.

  The count now runs the way the Android engine already ran it: the score's
  SMF is the ordinary un-shifted build, `plan.beats` fill `[0, preRollTicks)`
  ahead of the body on the METRONOME transport, and the backend holds the
  score transport for the pre-roll (`SynthBackend.play(afterCountInSeconds:)`)
  while that transport counts. The hold is counted in frames on the render
  thread, so the downbeat lands where the count says it does rather than on
  whichever buffer noticed a deadline had passed, and the pre-roll is forced
  audible through the mute flag — counting in is an explicit request, not the
  metronome toggle.

  `SynthBackend` gains `play(afterCountInSeconds:)` (default: plain `play()`)
  and `loadMetronomeSequence(_:offsetSeconds:)`, the offset being how far
  ahead of the score transport a count-in sequence runs. The AUMIDISynth path
  (offline export) is unchanged — it routes its pre-roll track to the
  metronome AU and was always correct.
- An `AVAudioSession` interruption no longer leaves `PlaybackEngine.state`
  claiming `.playing`. When another app started non-mixing playback — opening
  Music while a score played in the background — iOS deactivated this app's
  session and the `AVAudioEngine` stopped rendering, but nothing reached the
  transport: the sequencer / backend was still nominally started, so a host's
  play button kept showing "pause" (and its Now Playing entry kept claiming to
  be playing) for audio that had already gone silent. The engine now observes
  `AVAudioSession.interruptionNotification` and pauses on `.began`, for every
  `AudioSessionPolicy`. `.ended` is left to the host: whether to resume — and
  whether resuming is even wanted while the interrupter is still playing — is an
  app-level decision, so a host already driving resume from its own session
  observation is unaffected.

  Relatedly, under `.mixUntilPlay` an audition now always sounds on a mixing
  session — `playPreview` / `previewNoteOn` put the category back and hand the
  exclusive claim in, unless they are overlaid on live playback. Previously the
  exclusive category a `play(...)` escalated to stayed in place for the rest of
  the engine's life, and the engine re-activates the session implicitly whenever
  it starts its `AVAudioEngine` to sound a note — so once a score had been
  played, a single tap-audition cut off whatever else was playing. That happens
  with no interruption to react to: iOS does not interrupt an app that is not
  making a sound, so a paused engine holding an exclusive category is never told
  that another app has taken over. Only an explicit `play(...)` takes the route
  back.

## [1.13.1] - 2026-08-13

### Fixed

- Scores with grace notes now survive a save. The MSCX encoder writes grace
  notes back out — `Chord.graceNotesBefore` / `graceNotesAfter` were decoded
  but never encoded — `rg -i grace Sources/SheetMusicMSCX/Encoders/` returned
  nothing — so a parse → encode → parse round trip silently dropped every
  acciaccatura / appoggiatura / grace4-32(after) in a score. Grace chords are
  now emitted as their own `<Chord>` siblings (immediately before the parent
  for the "before" types, immediately after for the "after" types), carrying
  their own un-scaled duration — they never consume tuplet or voice-cursor
  time, matching the decoder.

  Also: `Voice.encodeChord`'s tuplet-unscaling rebuilt `Chord` from an
  explicit field list, with a comment warning that new fields must be
  propagated there by hand or silently dropped on encode — that rebuild is
  itself what dropped the grace fields. Replaced with a copy-and-mutate
  (`var unscaledChord = chord; unscaledChord.duration = …`), which forwards
  every field by construction and closes this class of bug for any future
  `Chord` field.

  A follow-up review flagged that a grace note tied forward into its main
  note — the single most common grace-tie figure — encoded the tie's
  `<Spanner type="Tie"><next>` with no `<location>` child at all. Checked
  against MuseScore Studio's own source rather than assumed: a grace chord
  shares its parent chord's tick, so this is a zero-delta, same-measure tie,
  and MuseScore's writer represents that as a *present but empty*
  `<location/>` (every field equals its default and is elided) — not as an
  absent `<location>`. The distinction matters on reload: MuseScore Studio's
  reader treats an absent `<location>` as "position unknown" and silently
  drops the tie, so the previous output would have lost the tie the moment a
  real user reopened the file in MuseScore Studio, even though this
  library's own round trip couldn't see the problem (its decoder only checks
  for `<next>` / `<prev>`, not their contents). Fixed the grace side by
  giving the grace encoder the same zero-delta `TieLocation` the ordinary
  same-measure tie path already knows how to write, in both tie directions.

  A second review pass caught that a tie reconnects on reload only when
  *both* endpoint records match — the grace side alone was not enough. The
  main note's side of the same tie was still written by the ordinary
  chord-to-chord path, which computes its location from the *previous real
  chord*'s duration: the wrong partner entirely when that tie is actually to
  one of the chord's own `graceNotesBefore`, producing either a wrong
  fraction or (when the tied grace opens the piece, with no previous chord
  at all) the same tie-losing bare `<prev/>` this release already fixed on
  the grace side. MuseScore instead writes `<prev><location><grace>0</grace>
  </location></prev>` — `<grace>` names which of the chord's own graces the
  tie belongs to (`Location::graceIndex`), and carries no `<fractions>`
  (also zero, also elided). Since this project's tie model is presence-only
  (no pointer from a tie to its partner note), the encoder now recognizes
  the shape structurally: a chord whose note has `tieBack` set, matched by
  pitch against a `graceNotesBefore` note with `tieForward` set. The match
  is used only when unambiguous — a chord without matching grace notes, or
  where the pitch match isn't unique, is byte-identical to before this
  paragraph, which a chord-shaped regression suite now pins alongside the
  positive cases.

  **Narrower than it may sound: single-note chords only.** MuseScore's
  endpoint match also compares each side's note index within its own chord
  (`Location::note`), and neither this fix nor the grace side emits a
  `<notes>` delta, so the comparison is always `0 - 0`. That is correct
  exactly when both the tied main note and the tied grace note are the only
  note in their respective chords — the common case this fix targets. A
  multi-note main chord whose tied note sits at index ≥ 1 (or a multi-note
  grace chord likewise) still drops the tie on reload. Not a regression —
  the pre-fix bare `<prev/>`/`<next/>` failed those cases identically — but
  a complete fix needs `<notes>` deltas computed on both tie sides, which is
  a separate, non-trivial change and not done here.

  **Known gap, left in place rather than guessed at:** the mirror direction
  — a main note tying forward into its own trailing `graceNotesAfter` note
  (a tied Nachschlag) — is not fixed. Investigating it surfaced an issue in
  the grace-writing fix above, new with this release rather than
  pre-existing: this encoder places a chord's `graceNotesAfter` `<Chord>`
  elements *after* that chord in the file, but MuseScore's own writer places
  every grace — before or after type alike — *before* the chord it
  decorates, with the type tag controlling only rendering and playback
  timing, not file position. MuseScore's reader buffers grace-type chords
  and attaches the whole run to the *next* normal chord it finds, with no
  flush at the end of a voice/measure — so an after-grace written where this
  encoder puts it is either displaced onto the following chord, or, if none
  follows, silently dropped on reload with nothing to report. Either way
  this affects an after-grace's read-time attachment independent of any tie.
  A tie location computed against this project's current placement would
  look confident and be wrong, so the ordinary (already non-reconnecting)
  location is left in place for that direction instead. Fixing the
  underlying placement — which affects every score with an after-grace,
  independent of ties — is a larger, separate change and needs its own
  follow-up.

- The engine version stamp (`SheetMusicEngine.version`) is bumped to
  `1.13.1`, matching this release. It had been left at `1.12.0` since that
  tag — this constant is the entire basis of the Android version-skew gate
  (two copies of the engine loaded in one process compare it before opening
  an edit session), so a stale value meant the gate was comparing the wrong
  thing.

- The metronome strip's volume reaches an injected `SynthBackend`. Such a
  backend mixes its own click, and the volume stopped at the AUMIDISynth
  `MetronomeController` — so on the backend path the click always mixed at
  unity: the strip could mute the click but not turn it down, while offline
  export (AUMIDISynth) obeyed the same slider. Measured, not inferred: before
  this, rendering the same click at volume 1.0 and 0.25 gave a byte-identical
  peak.

  `SynthBackend` gains `setMetronomeVolume(_:)`, defaulted to a no-op in the
  protocol extension so existing conformers are source-compatible, and
  `SwiftySynthBackend` scales its metronome mix by it (skipping the mix
  entirely at zero gain, as it already does while muted). The host-facing API
  is unchanged — `PlaybackEngine.setVolume(forChannel: .metronome, to:)`
  already expressed this.

  Not addressed here: on the backend path the click is mixed into the
  backend's output and therefore rides `masterGain`, where the AUMIDISynth
  metronome deliberately joins the master stage after it. Equalizing that
  needs the backend to expose a second output node, and is a design question
  (should the click follow the score's gain?) rather than a slip.

## [1.13.0] - 2026-08-12

### Fixed

- A host-supplied metronome click (`MetronomeClickProvider.clickSamples` /
  `.soundFont`) is heard during playback on an injected `SynthBackend`. Such a
  backend renders the metronome on a synth of its own, and `SwiftySynthBackend`
  built that synth from the SCORE's SoundFont — so the resolved click SF2 only
  ever reached the AUMIDISynth `MetronomeController`, which never sounds on the
  backend path, and playback clicked with the score font's GM notes 76 / 77
  (Hi / Low Wood Block) instead of the host's samples. Offline export, still on
  AUMIDISynth, used the custom click all along, so the two disagreed. Present
  since v1.1.0, which decoupled the metronome onto its own transport.

  The click SoundFont now travels with the score's: `SynthBackend.prepare`
  takes a `metronomeSoundfontURL` (**source-breaking** for out-of-tree
  conformers — pass `nil` to keep the old sharing), `PlaybackEngine` fills it
  from the same `MetronomeClickResolver` the AUMIDISynth path uses, and
  `SwiftySynthBackend` loads it into the metronome synth. `nil` — a
  `.defaultGM` host, or none at all — still shares the score font, so the GM
  wood block remains the fallback.

  The metronome tests that covered this asserted `peak > 0`, which a wood block
  satisfies as readily as a click sample; the new coverage discriminates by
  duration instead.

## [1.12.0] - 2026-08-12

### Fixed

- The editing caret's band and the editing hit-test's on-staff gate
  follow the staff's own line count. Both were written against
  `StaffMetrics.staffHeight`, which is 4 sp for every staff — the height
  of a FIVE-line one — and 1.11.0 is the release that made that false:
  it reads `Staff.lineCount`, draws each staff its own number of lines,
  and stacks staves by their own height. So on a 3-line staff the caret
  ran 2 sp past the bottom line and the gate reached into the next
  staff's paper, where a tap was rescued to a note in the staff above
  it; on a 1-line staff, whose own height is zero, the band was the
  right 6 sp but hung 2 sp too low, straddling nothing. Both now measure
  through `StaffLineGeometry.barLineSpanY(sp:)` — the same per-staff
  span the barline, the playback cursor and the loop highlight already
  use, including MuseScore's ±2 sp special case for a single line
  (`dom/barline.cpp:256-291`), which is what keeps the caret a visible
  column there. Five-line staves are unchanged.

- The range-selection box's two edges follow the end staves' line counts
  too, for the same reason and through the same span. Measured with
  `StaffMetrics.staffHeight` the box overshot a three-line bottom staff
  by 2 sp, and around a one-line staff it enclosed the paper below the
  single line rather than the line itself. Five-line staves are
  unchanged.

### Added

- A ninth `EditIntent` case, `.writeRest(at:duration:)`, wire discriminator 13 — the rest key's own meaning: make
  this timed slot a rest of THIS length, whatever is in it now. Over a rest that is the re-time `.setRestDuration`
  already did; over a note it is the delete paired with the re-time, as one undo step. A length outrunning the bar
  is spelled as a run of rests across the barline, and one filling the bar from beat one is promoted to `.measure`,
  both from the same planners `.setRestDuration` uses.

  Not expressible as `.composite([.delete, .setRestDuration])`, which is what makes it a case rather than a
  convenience: `.delete` collapses a bar it empties into a single measure rest, so the re-time would then be
  splicing a bar that had already lost the subdivision — throwing away the very length the caller was stating.
  `.delete` keeps its collapse, because a delete key means "empty this" while this means "make it this long", and
  the two want opposite spellings of the same underlying edit.

  The payload is the existing `SlotDurationIntentWire`, shared with `.setRestDuration` and `.setChordDuration`: the
  three really do carry the same two scalars, and the discriminator is the only thing telling them apart on the
  wire.

### Changed

- `DurationInterpretation` moved from `SheetMusicLayout` down into `SheetMusicCore`. Splitting a written duration
  into a base value plus augmentation dots is arithmetic over `NoteDuration` — the type never touched layout, and
  its old home put it out of reach of anything that depends on Core without depending on layout, which is exactly
  what a platform-neutral editing core is. **Not source-breaking:** `SheetMusicLayout` now carries
  `@_exported import SheetMusicCore`, so every existing `import SheetMusicLayout` call site resolves the name
  unchanged. That re-export is worth having on its own — `SheetMusicLayout`'s public API is written in Core's
  vocabulary (`Score`, `ScoreItemID`, `StaffAddress`, `NoteDuration`), so a consumer already needs those names in
  scope, and `SheetMusicUI` has said so one layer up since before this.

## [1.11.0] - 2026-08-12

### Fixed

- Soloing a part no longer silences the metronome. The mixer built a
  metronome strip alongside the instrument strips and then applied one
  rule to all of them — "while any channel is soloed, every non-soloed
  channel is silent" — but nothing ever solos the click, so the moment a
  user soloed a part to practise it the click went with it, with the
  host's metronome toggle still reading "on". The metronome is now off
  the solo bus, the way a DAW's click is: it answers to its own mute
  alone, and it can't silence the instruments either. Solo between
  instruments is unchanged. This also settles a split inside this
  package — the Android engine never put the click in `mixerChannels`,
  so only the Apple engine had the bug.

- A drum strip's kit can be changed, and the score's authored kit is
  applied at all. A program change on the GM drum channel selects the
  KIT, but `loadProgram` refused channel 9 outright and
  `rebuildMixerChannels` reported `program: nil` for a `useDrumset`
  strip — so a host's kit picker changed nothing, and, because
  `postProcessForMIDISynth` strips the SMF's tick-0 program for every
  mixer-managed channel and the drum channel is one, the kit the score
  asked for never arrived either: every drum part played whatever the
  SoundFont's default kit happened to be. The strip now reports its
  program, the change reaches the synth (bank 128 on the percussion unit
  for the AUMIDISynth path; a plain program change for the SwiftySynth
  backend, whose percussion channel already interprets it as the kit),
  and the new `MixerChannel.isDrums` tells a host to offer the drum
  catalog rather than the melodic one. `program == nil` now means the
  metronome and nothing else.

- A mixer strip reports the instrument that drives it, rather than the
  part's own label. The instrument name read `<longName>` first, but
  MuseScore prints `longName` at the left of the staff — it is the PART's
  label, and an arranger routinely sets it to the voice ("Soprano 1", or
  just "S") while `<trackName>` keeps the instrument ("ボーカル",
  "ピアノ"). So a strip answered "which instrument is this" with the part's
  own name; that then equalled the part label, the parenthesised suffix
  was suppressed as a stutter, and a part which genuinely changed
  instrument mid-score showed a row that never said what it was. The
  order is now `trackName` → `longName` → `id`. Scores whose two names
  agree — including the `instrument-change` fixture, so the committed
  `instrumentParams-v1.bin` golden is unmoved — are unaffected.

- The SwiftUI Canvas renderer — which backs PDF export and the paged view
  — draws grace chords. It had never drawn them at all, so a grace note
  was simply missing from an exported page while the CALayer renderer on
  screen showed it.

- The Android modules build again. `SheetMusicEditWire`, added in this
  release, is also the wirelet codegen's schema scan root for
  `:SheetMusicAudioAndroid`, and moving the score-address codecs into it
  stopped seven Kotlin codecs — `ScoreItemID`, `NoteID`, `RestID`,
  `TupletID`, `VoiceElementID`, `StaffAddress`, `ClefAnchor` — from being
  generated, while the generated `ScoreCursorCodec`/`AudioExportRangeCodec`
  and `AndroidPlaybackEngine` kept referencing them. Nothing on the Apple
  side could see it: the whole Swift suite stayed green while the AAR would
  not compile. The target is now split into `Path/` (scanned) and `Intent/`,
  with a second wirelet source set covering the former; Kotlin package names
  are unchanged.

### Added

- `MixerChannel.isSoloable`, `false` for the metronome. Hosts hide the
  solo control on a strip that reports `false`, the same way a `nil`
  `program` hides the program picker. `PlaybackEngine.setSoloed` ignores
  a channel that isn't on the solo bus, so `isSoloed` can never read back
  `true` there whatever the host sends.

- `MixerChannel.isDrums`, so a host offers the drum-kit catalog rather
  than the melodic one on a strip whose program is a kit. Distinct from
  the `program == nil` test it replaces, which now identifies only the
  metronome — see the drum-kit fix above.

- `MixerChannel.partName` and `MixerChannel.instrumentName`, beside the
  composed `name`. A mixer laid out in groups titles the group with the
  part and labels the row with the instrument, and neither is recoverable
  from `name`: it drops the instrument entirely for a part that has one,
  so a host splitting on the parentheses would get nothing back for
  exactly those strips. Both halves are reported whatever `name` shows.
  `partName` is empty and `instrumentName` is `nil` on the metronome,
  which belongs to no part.

- `LiveChannelPlan.labels(for:in:)` returns those three as a
  `StripLabels`, and is now the single implementation of the naming rule.
  It was written twice — `PlaybackEngine+Mixer.stripName` and
  `AudioMidiBridge.instrumentParams`, the latter carrying a comment
  promising it "mirrors stripName exactly". Both call the shared function
  now, so the Apple mixer and the Android wire cannot drift apart; the
  committed `instrumentParams-v1.bin` golden holds the wire byte-identical
  across the lift.

- `EditIntent` and `ScoreEditSession` let a host relay a scalar edit — a note write, a duration change, a delete,
  or several bundled into one undo step — to a second copy of the score, so an Android host can keep a mirror
  session in step with its own authoritative one. `Score.stableFingerprint` is a deterministic 64-bit digest of
  the mutable musical content, for confirming two copies agree.
- `ScoreEditSession.lastRefusalReason` reports why the last `apply` call returned `false` — the only diagnostic
  available when a mirror session and its authoritative counterpart disagree.
- Seven JNI entry points expose an edit session to Android: `nativeBeginEditSession`, `nativeApplyEditIntent`,
  `nativeEditUndo`, `nativeEditRedo`, `nativeEndEditSession`, `nativeScoreFingerprint`, and
  `nativeEngineVersionStamp`.
- `HandleTable.replace` swaps the value behind an existing handle and reports whether the write landed, so a
  handle released mid-edit is told apart from one that isn't.
- `SheetMusicEngine.version` and `SheetMusicEngine.versionStamp` provide a build identity. On Android two
  separately linked images of the engine coexist in one process — the host app's and its library's — and a
  mismatch (a stale `.so`) can cause silent score divergence. `versionStamp` lets a host compare its own
  compiled-in stamp against the one it reads from the library over JNI before opening an edit session, so it can
  refuse to open one on a mismatch instead of risking a corrupted score. No host does this comparison yet; that is
  downstream work this library only makes possible.
- The note-input planning logic moved into `SheetMusicCore/Editing/Planners/`, `public`, so `ScoreEditSession` can
  reach it directly instead of Folino's `EditorViewModel` being the only caller: `MeasureAccidentals` (accidental
  renotation after a pitch/spelling change), `CrossBarInputPlanner` (a note or rest write that overruns its bar
  chains a tied continuation into the next one instead of refusing), `FullMeasureRestCollapse` (a delete that
  empties a bar collapses to one `.measure` rest), `NoteInputPlanner`, `TiePlanner`, `IntervalPlanner`,
  `StaffStepPitch`, `ElementNavigator` (`TiePlanner` depends on its `nextTimedElement`/`previousTimedElement`, so
  it moved too), and `RestDurationPromotion` (a rest write that exactly fills its bar from beat one is promoted to
  the `.measure` spelling, matching the rest key's own behavior).
- Seven new `EditIntent` cases and their `EditIntentWire` discriminators (5…11, appended after the five SP0
  cases): `.setNotePitch`, `.setAccidental`, `.addNoteToChord`, `.removeNoteFromChord`, `.setTie`,
  `.createTuplet`, `.removeTuplet`. Together with the five SP0 cases (`.inputNote`, `.setRestDuration`,
  `.setChordDuration`, `.delete`, `.composite`), every edit `ScoreEditSession` can plan is now reachable from a
  relayed intent.
- An eighth new `EditIntent` case, `.writeNote(at:pitch:tpc:duration:)`, wire discriminator 12 — the letter key on a
  slot that ALREADY holds a note: re-pitch it and re-time it in one undo step. Distinct from `.inputNote`, which
  targets a rest, and deliberately not expressible as `.setChordDuration` followed by `.setNotePitch`: when the
  length outruns the bar the note is spelled as a tied chain, the chain is planned by cloning one chord into every
  link, and the two-intent form would therefore retune only the chain's head and leave its tail tied to it at the
  old pitch.
- `TiePlanner.tieChain(containing:in:)` returns every notehead a note is tied to, in voice order, including itself —
  walked in both directions, so the chain is the same whichever member the caller holds, and an untied note comes
  back as a chain of one. Within a chord the n-th tie out pairs with the n-th tie in (the rule `MidiRenderer`
  already resolves tied pitches by), not the n-th in-chord index, which would pair the wrong voices whenever only
  some of a chord's notes are tied.
- A new Android-gated `SheetMusicEditWire` library product carries every wire codec Folino's own `FolinoEditorJNI`
  would otherwise have had to hand-duplicate: `EditIntentCodec`, `PathIDCodecs`, `StaffAddressCodec`,
  `ScoreItemIDCodec`, `ClefAnchorCodec`, and the new `EditGeometryCodec` (`SelectionTintCodec`,
  `EditCaretFrameCodec`). It links as its own `.so`-independent target — `SheetMusicAndroidJNI` and a consuming
  app both statically pull it in, so what has to match between the two images is the wire *schema*, not a shared
  runtime instance.
- `LayoutDocument.editingHitTest(at:activeVoice:)` answers "what score item is under this tap" — notehead, stem,
  or a near-miss rescued through a 44×44-point slop box gated to the tapped staff, with a same-slop-box voice
  preference — the same policy Folino's `EditorViewModel.displayedItem(at:)` implemented, now available to any
  `LayoutDocument` including one built on Android. `LayoutDocument.editingCaretRect(for:in:minimumWidth:)`
  answers the companion question, the rect an edit caret or selection outline should draw for one score item,
  narrowed to that item's own staff band.
- `nativeEncodeDrawProgram` re-derives a cached layout's draw program with a selection's notehead/accidental
  (not the whole chord), rest glyph, or tuplet marking recolored — without relaying out. An empty selection
  reproduces the untinted bytes exactly.
- Three new JNI entry points complete the editing surface Android needs: `nativeEditingHitTest`,
  `nativeEditingCaretFrame`, and `nativeEncodeDrawProgram` (re-tints a cached draw program from a selection,
  reproducing `nativeComputeLayout`'s page assembly exactly in every layout mode — vertical, horizontal, and
  paginated).
- `Score.stableFingerprint`'s walk was widened to see everything a planner's element copy carries: on `Note` —
  `accidentalBracket`, `accidentalRole`, `glissando`, `headType`, `parentheses`, `isSmall`, `play`, `visible`; on
  `Chord` — `arpeggio`, `lyrics`, `graceNotesBefore`/`graceNotesAfter` (content, not just count), `articulations`,
  `tremolo`, `chordLines`, `stemVisible`, `beamVisible`. See "Changed" below for what this means for a fingerprint
  stored before this release.
- Per-staff line counts. `SheetMusicCore.Staff.lineCount` carries
  MuseScore's `<StaffType><lines>`, so a 1-line or 3-line percussion staff
  keeps its own number of drawn lines end to end: the MSCX reader takes it,
  the MSCX writer writes it back, the MusicXML importer reads it from
  `<attributes><staff-details><staff-lines>`, and all three renderers draw
  it. It defaults to 5, and a five-line staff engraves byte-identically to
  before.
- `SheetMusicLayout.StaffLineGeometry` owns every line-count-dependent
  constant: the staff's drawn height, its top and bottom line in `step`
  units, where its ledger lines begin, its barline span, a rest's natural
  line, and MuseScore's whole-rest line move.
  `LayoutSystem.staffGeometries` carries one per staff, parallel to
  `staffOrigins`, and `LayoutSystem.geometry(atFlatIndex:)` reads it
  (falling back to `.standard`). Everything that used to derive a vertical
  from `StaffMetrics.staffHeight` — barline spans, the playback cursor,
  the loop highlight, the skyline band, ledger lines, the centered
  percussion clef and time signature — goes through this type now. Notes,
  pitched clefs and key signatures deliberately do not: MuseScore anchors
  those to the five-line reference frame however many lines are drawn.
- Ledger lines are engraved once by the layout engine
  (`SheetMusicLayout.LedgerLinePass`) and emitted as
  `LayoutElement.ledgerLine`, instead of being re-derived inside each
  renderer. Bounding a ledger line by the staff's own line count needs the
  staff identity, which only the engine still has.

### Changed

- `ScoreEditor` is no longer `@MainActor`. **Source-breaking:** a `@MainActor final class` is implicitly
  `Sendable`, and `ScoreEditor` no longer is, so a consumer storing one in a `Sendable` type, or capturing it in a
  `@Sendable` closure or a detached `Task`, will now fail to compile. The Android JNI process pumps no main run
  loop, so a main-actor hop from an entry point would be scheduled and never resumed; the editor has to be
  drivable synchronously from whatever thread calls in.
- `Selection/` — `ScoreSelection`, `ScoreHitTarget`, `ScoreHitTester`, `ScoreHitTester+Marquee`, and the newly
  extracted `SelectionExpansion` — moved from `SheetMusicUI` down to `SheetMusicLayout`, so an Android host (which
  cannot import `SheetMusicUI`, an Apple-only SwiftUI target) can hit-test and expand a selection too.
  **Source-breaking only for a consumer that imports `SheetMusicLayout` by name directly**: `SheetMusicUI` already
  carried (and still carries) a whole-module `@_exported import SheetMusicLayout`, so any existing `import
  SheetMusicUI` call site keeps compiling and resolving these four types unchanged — nothing to do there.
- `ScoreEditSession.apply` now plans every intent through the planners above instead of mapping it straight onto
  one command. **Source-behavior change, not source-breaking:** the same intent can now produce more commands
  bundled into the same undo step — an out-of-key pitch write may ride in with its own accidental repair, and a
  note or rest write that overruns its bar may chain a tied continuation across the barline instead of being
  refused. One `apply` call is still one undo step either way; a host that inspects the *count* or *shape* of the
  resulting commands (rather than treating them as opaque) is the only thing that could observe a difference.
- `.setChordDuration` reaches across the barline, as `.setRestDuration` already did. The engine refuses any
  single-slot lengthening that would cross a barline, so a host's length key read as dead at every barline — the
  very hole `CrossBarInputPlanner` was written to close on the input side. The chain is planned from the chord
  ALREADY in the slot, so its other notes, articulations, grace notes and ties survive into the continuation. No
  `.measure` promotion here, unlike the rest case: `.measure` is a rest-only spelling.
- `.setNotePitch` retunes the whole tie chain the named note belongs to, not that notehead alone. A tie says these
  noteheads are one sounding note, and `MidiRenderer` reads it that way — it carries the head's pitch through the
  chain — so retuning one member left two different pitches joined by a tie, unperformable and still sounding at
  the old pitch. The accidental lands on the chain's head alone, matching MuseScore and `MeasureAccidentals`, which
  skips tied-back notes when it renotates a measure. **Source-behavior change, not source-breaking:** an untied note
  is a chain of one and still plans to a bare `SetNotePitch`.
- **Every `Score.stableFingerprint` value changes** as a consequence of the widened walk above — this is not a
  bug, it is the point (the walk previously blind to a planner's own repairs now sees them). A host comparing a
  fingerprint it computed and stored under 1.10.1 or earlier against one computed under 1.11.0 will see them
  disagree even for an unedited score, and must re-baseline rather than treat the mismatch as drift.
- **Breaking.** `SheetMusicLayout.LayoutElement.barLine` carries a third
  associated value, `halfHeight: CGFloat` — the distance from the stroke's
  center Y to each of its ends — and
  `SheetMusicLayout.BarLineGeometry.halfHeightSp` is removed. The span is
  no longer a constant: a three-line staff spans ±1 sp, and a one-line
  staff spans ±2 sp about its single line rather than collapsing to a dot.
  Read `halfHeight` off the `.barLine` payload, or call
  `StaffLineGeometry.barLineSpanY(sp:)` where you have the staff's geometry
  but not the element.
- **Breaking.** `SheetMusicLayout.LayoutElement` gains `case ledgerLine`,
  which breaks exhaustive switches in consuming code. A renderer that
  ignores the new case draws no ledger lines at all — the engine no longer
  expects renderers to derive them for themselves.
- A `LayoutSystem` rebuilt by hand must forward `staffGeometries`. The
  parameter is defaulted to `[]` so the initializer stays
  source-compatible, and `[]` means "every staff is five-line" — so
  omitting it compiles, passes, and silently reverts that system's staves
  to five-line geometry. The two copy-shaped rebuilds the library needs
  are `LayoutSystem.addingSpanners(_:)` and `LayoutSystem.movedBy(dy:)`,
  which carry every field forward; prefer them to re-invoking `init`.

## [1.10.1] - 2026-08-12

### Fixed

- A tuplet whose members are all rests engraves its number and bracket.
  The emitter required at least one chord to anchor the marking against
  and returned early otherwise, so a triplet of rests printed as three
  plain rests with nothing saying three-in-the-time-of-two — the marking
  is the only thing that distinguishes them. Rests already widened the
  bracket's span; now they can carry it alone, and the vertical anchor
  falls back to the middle line, placing the bracket where a middle-line
  note would have put it. Sample `30-rest-tuplet` covers both the
  all-rest tuplet and the note-then-rests one.

- PDF import reads chords and note values correctly on scores engraved at
  a larger-than-typical staff size. The importer matched a notehead to its
  stem within a fixed ±7pt window, but a stem abuts its notehead's edge at
  a distance set by the music font — 1.2–1.3 staff spaces, measured over
  the whole reference corpus — so the window is only correct at one page
  scale. On a piano score engraved at a 5.95pt staff space every stem-up
  stem sat 7.41pt away, 0.41pt outside the window: 577 noteheads found no
  stem at all, each becoming its own one-note chord, and every value that
  depended on beam attachment collapsed to a quarter. The window is now
  1.4 staff spaces, which reproduces the old constant exactly at the
  corpus's most common staff space.

- PDF import produces the same `Score` for the same page regardless of
  the order the PDF's content stream happened to emit its glyphs.
  `buildScore` was sensitive to that order in about thirty places — not
  only comparators, but first-minimum scans, greedy consume-in-arrival
  loops, and readers that break at the first content glyph — so an
  identical glyph multiset in a different order could decode to a
  different score. The four glyph/path streams are now canonicalized once
  on entry (`WalkedContent.canonicalized()`), which makes every
  downstream array a function of the content; the order chosen (page,
  then bottom-up, then left-to-right, then a total order over the
  semantic and every remaining field) was decided by measuring both
  directions against the reference corpus.

- PDF import no longer drops noteheads on deep ledger lines. The
  capture band around a staff was exactly three staff spaces, and a piano
  bass routinely writes 3.0–4.5 spaces out; on one page 25 of 271
  noteheads were captured by no staff at all, which read as chords
  losing their lower notes. The band is now five spaces, the neighbouring
  staff still being excluded by the midpoint clamp that was added after
  the band was first narrowed.

- PDF import reads a chord that contains a SECOND as one chord. The
  engraver has to mirror one head of a second across the stem, so the two
  heads never share an x column, and the cluster rule demanded one within
  a fixed 2.5pt. The window is now 1.35 staff spaces — measured to sit
  between the mirror offset (1.2 sp) and the minimum note-to-note
  spacing (~1.5 sp) — and a mirrored head must also be at a different
  staff position, since merging a unison would delete a note.

- PDF import reads a chord's stem direction from the whole chord rather
  than from its lowest notehead, so a wide chord whose stem barely clears
  the near head is no longer read as pointing the other way (which put it
  in the wrong voice).

- PDF import matches a flag to the stem it hangs from. A flag attaches at
  the stem's bare end — measured over the reference corpus, 53,058 of the
  ~54,000 flags sharing a stem's x column sit within 0.04 staff spaces of
  that end — but the importer looked for it in a fixed 4–22pt window
  measured from the lead notehead. An engraving-correct stem is 28pt long
  at an 8pt staff space, outside that window, so the eighth read as a
  quarter; and on a CHORD the stem's bare end is a chord-height farther
  from the lead notehead, so a flagged chord lost its flag at any staff
  size.

- PDF import decides which note an augmentation dot belongs to by the
  notehead's own width rather than a fixed 12pt. Measured over the
  reference corpus, a note's own dot sits 0.8–1.2 notehead-advances to its
  right and nothing at all sits at 1.3–1.4, so the bound is now 1.35
  advances; 12pt was 1.0 advance on the largest staves (clipping real
  dots) and 2.5 on the smallest (admitting the following note's dot).

- PDF import reads a rest that sits outside the staff, recognizes the
  repeat dot MuseScore actually draws (`repeatDot` U+E044, never the
  combined `repeatDots` U+E043), and classifies seven glyph families the
  importer had names for but never produced.

## [1.10.0] - 2026-08-11

### Added

- Mid-score instrument changes are read, engraved, played and written
  back. `SheetMusicCore.InstrumentChange` models the instruction text
  plus the `Instrument` that takes over from that position, stored as a
  `SystemElement` on `Score.systemMeasures` — the same lift `<StaffText>`
  and `<RehearsalMark>` already take, so no tick map lives on `Part`.
  `Score.instrumentTimeline(forPart:)` derives the time-keyed view,
  mirroring how `Tempo` is stored as a system element and read through
  `TempoTimeline`. Both the MSCX and the MusicXML importers produce it:
  MSCX from `<InstrumentChange>` (and the encoder writes it back in
  MuseScore's own element order), MusicXML by synthesizing a change
  wherever consecutive notes reference a different `<score-instrument>`.
  A change whose instrument is unusable still engraves its text and
  contributes no timeline point, so a malformed reference can never
  silently re-instrument a part.

- Playback follows the score. `MidiRenderer` allocates one MIDI channel
  per change INSTANCE rather than per distinct instrument — that is what
  keeps the exported SMF MuseScore-exact, since three separate "to Piano"
  changes each embed their own `<Channel>` — and every note is emitted on
  the channel in force at its own tick. A tie chain sounds entirely on
  the channel in force at its head, so a change landing between a tie's
  head and tail cannot leave a stuck note. Every program change still
  sits at tick 0; nothing is emitted mid-stream.

- `SheetMusicMIDI.LiveChannelPlan` collapses the rendered multi-port
  channel set onto the 16 channels a live synth has. Within a part, two
  instruments share one live channel when their `InstrumentChannel`s
  agree on the six sounding fields; instances MuseScore gave different
  channel numbers to still merge, and an instance the author retuned in
  the mixer keeps its own. `MidiChannelRemap` applies the plan to a
  rendered `MidiFile`, and `SheetMusicAudioCore.InstrumentChannel` is now
  `Hashable`.

- The mixer has one strip per instrument. A part that changes instrument
  mid-score shows a strip for each, named after the instrument rather
  than the staff, on both Apple and Android. Auditioning a program from
  the mixer previews the instrument at the playback cursor.

- Line spanners are placed by the skyline autoplace pass instead of a
  fixed band under the staff. `buildSystem` now draws the segments
  itself, so a hairpin, ottava, pedal or text line enters the staff
  skyline before the lyric category the way MuseScore orders it
  (`systemlayout.cpp:1276-1297`) — a lyric clears the segment's actual
  position rather than a guessed reservation, and a segment pushed down
  by a collision reserves its own height so the system grows to hold it.
  The old `belowStaffSpannerCoverage` walk and the flat 7.4 sp verse-0
  floor it fed are gone; the corpus is byte-identical across the
  change, so the skyline subsumes the hack exactly.

- Trill, palm mute and let ring are modelled rather than falling
  through to a text line printing their own type name.
  `Spanner.Kind.trill` carries a `TrillPayload` whose `TrillType`
  (`trill`, `upprall`, `downprall`, `prallprall`) drives a symbol line
  — start sigil, fill copies sized off the real glyph advances, and an
  optional right-end cap — matching `TrillSegment::symbolLine`.
  `Spanner.Kind.palmMute` and `.letRing` take their style-default
  labels ("P.M." / "let ring") over a dashed line, overridable by an
  authored `<beginText>`. Placement follows MuseScore: trill above the
  staff, the other two below.

- `Spanner.beginText` and `Spanner.placement` carry MuseScore's
  `<beginText>` and `<placement>`. Both are `nil` when the author left
  the property styled, which is exactly what the absence of the element
  means upstream — MuseScore writes the tag only once the property
  stops being styled (`twrite.cpp:578`) — so a round trip no longer
  invents an override the file did not contain.

- `ScoreStyle.ottavaNumbersOnly` (MSCX `<ottavaNumbersOnly>`, C++
  `Sid::ottavaNumbersOnly`). When true — MuseScore's default — an
  octave line is labelled with the bare number rather than the full
  `8va` / `15ma` form, the alta/bassa distinction being carried by the
  line's side of the staff.

- Per-note velocity overrides. `Note.userVelocity` and
  `Note.velocityType` model MuseScore's `<velocity>` / `<veloType>`,
  and `Note.customizedVelocity(_:)` resolves the sounding velocity the
  way `Note::customizeVelocity` does: `0` means "no override",
  `.offset` applies a signed percentage to the dynamic's velocity, and
  `.user` replaces it outright. The decoder resolves an absent
  `<veloType>` from the file's own generation rather than from a single
  default, because MuseScore 3 defaulted to `.offset` and wrote the tag
  explicitly while MuseScore 4 defaults to `.user` and stops writing it.
  The MSCX encoder writes both back, and the MIDI renderer honours them.

- The MIDI importer preserves recorded noteOn velocities. It previously
  read a velocity only to tell an attack from a release and then
  discarded it, so — the import path emitting no `Dynamic`s — a
  dynamically shaped take came back uniformly mezzo-forte. The velocity
  now survives the pairing, voicing and cross-barline carry passes and
  is stamped on the note as an absolute override, as
  `setMusicNotesFromMidi` does upstream.

- The master output stage is selectable. `MasterOutputStage` offers
  `.none` (the new default), `.softClip` and `.peakLimiter`, and
  `PlaybackEngine` applies the chosen one after the master gain.
  `.none` is the default because it is the only setting under which the
  master gain behaves like a volume control the whole way up; the
  limiter this engine used to apply unconditionally holds its ceiling
  by *reducing* gain, so above unity the control runs backwards —
  measured on a steady sine, 8× drive lands 2.4 dB quieter than 1×.
  `.softClip` bends the peaks instead, trading a hard edge for
  progressive harmonic distortion.

- Level metering. `PlaybackEngine` can report a `MixLevel` per captured
  buffer, carrying `peak` and `rms` so a host can see both what clips
  and what sounds loud — their ratio is the crest factor, which is why
  a mix can sit at the ceiling and still feel quiet. The tap sits after
  the master gain and the metronome sum but *before* the output stage,
  so the reported level is the true pre-limiting one, and `peak` is
  unclamped so real overshoot past full scale is visible.

### Changed

- **Breaking.** `SheetMusicAudioCore.MixerChannel.Kind.staff(Int)` is
  replaced by `.instrument(partIndex:ordinal:)`. A mixer strip is a
  (part × distinct instrument) pair now, not a staff, so a grand staff
  still has one strip while a clarinet doubling on saxophone has two.
  `ordinal` indexes the part's deduped instruments in first-appearance
  order and is stable for a given score.

- **Breaking.** `SheetMusicCore.SystemElement` gains
  `case instrumentChange` and `SheetMusicCore.TextStyleType` gains
  `case instrumentChange`. Both break exhaustive switches in consuming
  code, and the latter also changes `allCases`' order.

- **Breaking.** `SheetMusicLayout.LayoutElement.staffText`'s
  `isSystemText: Bool` becomes `style: TextStyleType`. The flag could
  only say "staff or system"; a third text style needed a third value,
  and carrying the style type means the renderer reads its font and
  placement defaults from one table instead of inferring them.

- **Breaking (Android).** `MixerChannel.staffIndex` is gone, and
  `AndroidPlaybackEngine.setStaffMuted` / `setStaffSoloed` /
  `setStaffVolume` / `setStaffProgram` take `(partIndex, ordinal)` in
  place of `staffIndex` — the Kotlin mirror of the `MixerChannel.Kind`
  change above.

- `MidiRenderer.staffChannels(score:)` now explicitly reports each
  staff's part's ORDINAL-0 (tick-0) strip. It always meant "the channel
  this staff's track starts on"; with instrument changes that is one of
  several channels the track uses, so the accessor's contract is stated
  rather than implied.

### Fixed

- A hairpin's direction is read from its `<subtype>` rather than from
  the `type` attribute, and a spanner's variant is resolved from its
  payload rather than from the type string. The string form could not
  distinguish the variants MuseScore spells in the subtype, so a
  decrescendo could engrave as a crescendo.

- The autoplace category order matches MuseScore's. Ottavas and pedals
  are laid out and put into the skyline before lyrics
  (`systemlayout.cpp:1294-1295`); with the order inverted a pedal was
  pushed below the lyric rows instead of the lyrics clearing it. Text
  lines move up to just after hairpins, and a hairpin leaves the
  dynamics group to be placed individually — the pair is exempt from
  each other in the skyline, so sharing the group's single offset let
  one ledger-line note under a hairpin drag every dynamic on the staff
  down with it. The categories were inert placeholders until spanner
  segments began reaching the pass, which is why the error survived.

- A spanner's per-element `<placement>` and `numbersOnly` survive an
  MSCX round trip.

- A harmony's parentheses and root/bass case are engraved.
  `<leftParen/>`, `<rightParen/>`, `<rootCase>` and `<baseCase>` were
  decoded and round-tripped, but the renderer only ever read
  `harmony.name`, so `(C7)` engraved as `C7`. The re-casing touches the
  root and bass *letter* only, leaving the accidental markers alone, so
  `Bb` lowercases to `bb` — B flat — rather than reading as a double
  flat, and a wrapping paren is transparent to slice parsing so
  `(bVII)` keeps its leading accidental.

- A `<Spanner type="TextLine">` gets its label back. `<beginText>` is a
  `TextLineBase` property riding on the payload child of any
  line-shaped spanner, and the decoder dropped it, so an authored text
  line engraved with no text at all.

- An ottava's label is drawn as SMuFL glyphs rather than as text,
  which is what MuseScore does.

- **Android:** a part whose instrument declares one of MuseScore's
  "expressive" banks no longer plays silently. Those presets implement
  single-note dynamics by putting roughly 80 dB of attenuation under
  CC2 control; MuseScore streams CC2 while playing, this engine never
  sent it, and a MIDI channel starts at CC2 = 0 — so the preset sat at
  the fully attenuated end with no error reported anywhere. Android is
  the only backend that honours the score's declared bank, which is why
  Apple was unaffected.

- **Android:** both SoundFont caches notice when the bytes behind a URI
  change. They were keyed on identity that never changes when the file
  does, and refreshed only when their copy was missing, so a host that
  ships its SoundFont as an asset served the first copy it ever made
  forever — observed as a device playing a 215 MB font two months after
  a 32 MB one had been staged in its place. The driver now compares
  lengths, and the asset resolver re-extracts whenever the APK is newer
  than the copy; a provider that reports no length keeps the previous
  behavior rather than paying a multi-hundred-megabyte copy per launch.

- **PDF import:** a grand staff's two staves form a barline quorum. The
  consensus that rejects a vertical only one staff sees was gated to
  systems of three staves or more, so a piano grand staff — which is
  exactly two — always fell back to the raw union and any single-staff
  stray became a system-wide measure boundary. Upstream creates a
  barline on every staff of a real boundary
  (`measurelayout.cpp:1559-1583`), so two staves are a quorum. On the
  corpus's worst-scoring entry this took the measure count from 57 to
  the ground truth's 55 and positional pitch from 8% to 37%, and it is
  the only score in the 141-score gate that moved.

- **PDF import:** a chord's notes are ordered by pitch rather than by
  glyph arrival, so the same page yields the same `Score` whatever
  order its content stream happens to emit the noteheads in. Content
  order carries no musical convention to preserve, and ascending pitch
  is what MuseScore itself sorts a chord into (`Chord::add`).

- **PDF import:** noteheads drawn from the SMuFL optional range are
  recovered rather than dropped.

- **Android example:** the example app compiles again — its
  `ScoreViewModel` call site was never updated when `transposeSemitones`
  was added to `LayoutOptionsWire`. Nothing caught it: `swift test`
  does not build `Examples/`, and both the preflight script and CI stop
  at the library's `assembleRelease`.

## [1.9.0] - 2026-08-06

### Added

- `ScoreViewOptions.measureNumbers` chooses how often a measure-number
  label is engraved. The default `.systemStart` is what the engine did
  before — one label above the first measure of each system.
  `.interval(every:)` adds a label to every N-th measure, and
  `.everyMeasure` is `.interval(every: 1)`. System heads keep their
  label under every policy, so widening the interval never removes a
  number the reader could already see, and an anacrusis stays unlabeled
  because the exclusion lives in `Score.displayedMeasureNumber(at:)`.
  MuseScore spells this as `Sid::measureNumberSystem` +
  `Sid::measureNumberInterval`; the label still rides on the top staff
  only. `render-previews` reads it from `SM_MEASURE_NUMBERS`.

## [1.8.0] - 2026-08-02

### Added

- `Score.effectiveMeasureDuration(at:measureIndex:)` resolves what a
  `.measure` duration means in one measure on one staff. It reads that
  staff's own measure list, because `actualLength` — unlike the time
  signature — is per-measure and can differ between staves, and falls
  back to 4/4 for an out-of-range staff or measure. It walks the whole
  list, so a loop should keep using `effectiveMeasureDurations()` and an
  index.

### Fixed

- A PDF containing a tuplet exports an `.mscz` that can be reopened. The
  importer recognized the tuplet and baked the ratio into each member's
  duration, but emitted no `Tuplet` span. The MSCX encoder un-scales a
  member through its enclosing tuplet, so a member with none around it
  fell through to `<durationType>measure</durationType>`, which the Chord
  decoder refuses. Both scaling sites now record the ratio and voice
  assembly groups consecutive same-ratio members into a span — which also
  gets the bracket and number engraved. The breakage went unseen until
  imported PDFs started being written to disk as scores.

- Writing a note into an empty bar no longer produces a chord spelled
  `.measure`. `InputNote` built the new chord with the full-measure
  rest's own duration, and `.measure` is a rest-only spelling: layout
  resolved it against the bar and drew the note correctly, so the score
  looked right while `MSCXEncoder` trapped on save — a crash landing far
  from the edit that caused it. The bar's actual length is resolved on
  the way in instead; the inverse still restores the `.measure` rest as
  it was spelled, so undo leaves the empty bar exactly as it found it.

## [1.7.0] - 2026-08-02

### Added

- `FontMetricsProvider.leading(font:)` reports the extra vertical space a
  face asks for between consecutive lines, on top of `ascent + descent`.
  Only multi-line text consults it. The requirement ships with a default
  of 0, so existing conformers — the stub and Android's
  `SMuFLMetricsTable`-backed provider — keep compiling unchanged;
  `AppleFontMetricsProvider` returns `CTFontGetLeading`.

### Fixed

- Annotation text no longer runs past the end of a system. Nothing in the
  layout had ever moved an element horizontally: placement put a
  `<StaffText>` at its tick column plus the author's `<offset>` without
  consulting its width, so a text anchored near the final barline
  overflowed the page and the host clipped it. The new
  `HorizontalClampPass` pulls `.staffText` / `.systemText` / `.tempo` /
  `.rehearsalMark` back inside the system's bounds, shifting only as far
  as the overflow demands, and runs before the vertical pass so X is
  final when collisions are measured. Lyrics and `.harmony` are out of
  scope. Text that already fits is untouched.

- Multi-line annotations are measured line by line.
  `LayoutElementShape.textRect` handed a multi-line payload straight to
  `typographicWidth`, which laid every line out on one `CTLine`: the box
  came out as wide as the concatenation and one line tall, while the
  renderers stack the lines. The width is now the widest line and the
  height the whole stack, which also corrects the skyline's vertical box
  for those annotations.

- Seeking no longer flattens the mixer on the injected-backend path.
  `PlaybackEngine.seek(to:)` — and therefore `skip(by:)`, which every
  seek bar, lock-screen scrubber, and ±N-second button routes through —
  repositioned the transport without re-asserting the mixer. A backend
  seek resets the synth's channels to their GM defaults, and the tick-0
  CC 7 / programChange that would otherwise be chased back are stripped
  for mixer-managed channels precisely so the mixer stays the sole
  authority, so the user's per-staff volume, mute, solo, and program
  silently reverted on every seek until the next `play()` re-applied
  them. Every other backend-seek site already re-asserted; this one is
  now consistent with them.

- `SwiftySynthBackend` no longer drops the whole-score tuning on a seek.
  `MidiFileSequencer.seek` resets the synthesizer before it chases, just
  as `sequencer.play` does in `loadSequence`, so the RPN pair carrying
  the A4 calibration and the transpose was wiped with nothing in the SMF
  to restore it — a lock-screen skip or a loop wrap quietly returned
  playback to concert pitch. `setTuning` is contracted to persist across
  transport operations; the backend now re-asserts it after a seek, the
  same way `loadSequence` already did.

## [1.6.0] - 2026-07-29

### Added

- Tuplet marks are read from PDF. The importer detects a bracketed mark
  from its number and arms, anchors a beamed mark to its narrowest beam,
  and scales the members inside a detected mark's span — read before
  lyrics and before metric reconciliation, so a tuplet member is never
  re-valued afterwards and its digits are not mistaken for a lyric.

- `PlaybackEngine.timedPosition` pairs the current playback position with
  the host-clock instant it corresponds to, in a single read. Sampling a
  node's `lastRenderTime` next to a separately-read position admits up to
  one IO buffer (~23 ms) of unknown error; this has no interval between
  two reads to be wrong about, so a host aligning an independently
  captured recording against playback can project the score's time-0
  instant onto the shared host clock exactly. `nil` — never a wrong
  number — whenever a pairing is unavailable.

- `LayoutMeasure.hasSameRenderContent(as:)` reports whether two layout
  measures would draw identically once placed, ignoring their horizontal
  origin. A renderer that caches per-measure drawing uses it to decide
  between reusing, repositioning, and rebuilding.

- `PdfParseResultWire.playableElementCount` — how many chord/rest elements
  the PDF importer actually reconstructed, across every staff and voice.
  A PDF outside the importer's scope (a Chrome "print to PDF", a scan)
  still yields staff lines and measure cells, so the resulting `Score` is
  structurally valid and completely empty; a host that only checked "did
  the parse throw" would show the reader a playable transport that runs
  one second and plays silence. The count is reported as a fact, not a
  verdict — the host decides what is worth playing. Additive and
  defaulted, so existing construction sites are unaffected.

### Changed

- Note entry on a large score is roughly 9× faster end to end. On a
  1300-measure × 6-staff score in horizontal (no-wrap) layout, a
  one-note edit went from ~216 ms to ~24 ms per keystroke in a Release
  build; a cold layout of the same score went from 335 ms to 38 ms
  horizontally and from 427 ms to 36 ms vertically. Two independent
  causes:
  - `LayoutEngine`'s spacing pass was O(measures²).
    `aggregatedTickWeights` re-derived one measure's effective duration
    by walking its staff's entire measure list, once per measure — 97 %
    of a one-note edit's layout time on a 1300-measure score. The
    durations are now computed once per layout call and carried on the
    render context. The per-measure `LayoutCache` entry additionally
    shares one tick aggregation between the width pass and the placement
    pass instead of computing it twice.
  - Editing one note rebuilt the entire `CALayer` tree. Each measure's
    layers now live in their own container layer, and `ScoreView`
    rebuilds only the measures whose drawn content changed, repositioning
    the ones that merely shifted horizontally. An edit no longer calls
    the full system builder at all.

  Rendered output is unchanged: a layout digest over every bundled
  fixture and the rendered reference images are both byte-identical
  across the change.

### Fixed

- The per-measure layout cache could serve stale note positions. Its key
  covered a measure's own content but not the prevailing measure
  duration, which carries forward from earlier measures — so editing a
  time signature could leave a later measure containing a full-bar rest
  laid out against the old bar length.

- The Android AAR is published again. `android-publish.yml` triggered
  only on `v*` tags, but the tag prefix was dropped after 1.2.2, so no
  Android artifact was published for 1.2.3 through 1.5.1. The workflow
  now matches both spellings.

- PDF import accuracy, across several passes:
  - Text from a simple font is decoded through the font's own encoding
    rather than assumed Latin-1, and a CMap text run's origin is recorded
    at its start instead of one advance past it.
  - Lyrics snap by comparing syllable and notehead **centres**, and the
    candidate gate now uses the same centre the snap does, so the two
    can no longer disagree.
  - A staccato dot is no longer read as an augmentation dot; a lone whole
    rest is read as a measure rest rather than a whole note; fractional
    beams narrower than 4 pt are accepted; and the leading key/time
    region ends at content rather than at the first notehead.
  - Tier 4 shape matching measures a glyph against the staff, not just
    its own silhouette.

- `AVAudioSequencer.hostTimeForBeats:error:` raises an Objective-C
  exception — rather than populating its `NSError **` — in a window right
  at playback start, where `isPlaying` reports `true` before the
  underlying `MusicPlayer` is actually playing. Swift cannot catch an
  NSException and no pre-call guard closes the race, since `isPlaying` is
  itself the check that lies. The call now goes through a small
  Objective-C shim that folds the raising path and the documented
  error-pointer path into one failure result.

- The playback cursor skipped a centered rest based on a tick count; it
  now keys on `.measure` duration, which is what actually centers it.

## [1.5.1] - 2026-07-27

### Fixed

- `SheetMusicPDF` is now exported as a library product on Android as well
  as Apple. 1.5.0 made the importer buildable for Android but left the
  product inside the Apple-only block, so a cross-compiling consumer got
  *"product 'SheetMusicPDF' … not found in package 'swift-sheet-music'"*
  and could not reach `parseUsingSwiftReader`,
  `parseWithGeometryUsingSwiftReader` or `summaryUsingSwiftReader` at all.
  The target's Android shape already excludes every Apple-only file and
  depends only on Core + Layout, so exporting it pulls in no Apple
  framework.

## [1.5.0] - 2026-07-27

### Added

- The PDF importer's geometry side-car is now available on Android, so a
  host can draw a playback cursor on the original imported PDF and
  resolve taps on it back to score positions. Previously only the Apple
  front-end could produce it: `parseWithGeometry` lived in the
  PDFKit-gated entry point, and Android could only ask for a bare
  `Score`.
  - `PDFImporter.parseUsingSwiftReader(pdfData:options:)`,
    `parseWithGeometryUsingSwiftReader(pdfData:options:)` and
    `summaryUsingSwiftReader(pdfData:)` are the Foundation-only entry
    points driven by the pure-Swift PDF reader. They are compiled on
    **both** platforms — Android uses them as its only front-end, and on
    Apple they stay reachable so the test suite exercises the exact code
    Android runs. `PDFImporter+AndroidEntry` is now a thin re-export of
    them.
  - `PDFDocumentSummary` (page count + `/Title`) reads a PDF's metadata
    without decoding any notation, so a library can name an imported
    file without paying for a parse.
  - JNI: `nativeLoadScoreWithGeometryFromPDF`, `nativePdfCursorRect`,
    `nativePdfHitTest`, `nativePdfPageSizes` and
    `nativeReleasePdfGeometry`, with `PdfRectWire`, `PdfPageSizesWire`,
    `PdfDiagnosticWire` and `PdfParseResultWire` as their wire types.
    The geometry stays behind an opaque handle — only a rectangle or a
    cursor ever crosses the boundary, so cursor lookup and hit-testing
    are not re-implemented per platform. Every rectangle leaving and
    every point arriving is converted between PDF user space (y-up) and
    top-left page space on the Swift side, so a caller works in one
    convention.
  - Kotlin: `PdfScoreHandle` (score handle + geometry handle +
    importer diagnostics, releasing both on `close()`) and
    `PdfDiagnostic`.

- A tiered glyph-classification cascade for PDF import. The importer no
  longer depends on a PDF naming its glyphs the way MuseScore's Bravura
  export does: it extracts the embedded font program and encoding from
  the font dictionary, resolves a simple font's character codes to real
  glyph IDs, and classifies through a glyph-name table before falling
  back to shape matching against rasterized Bravura exemplars. Tier 4
  (shape matching) is **off by default** behind
  `PDFImportOptions.enableShapeMatching`; a per-font music-font gate
  keeps it from firing on text fonts. `RawGlyph` is replaced by the
  format-neutral `GlyphGeometry`, and glyphs are classified at front-end
  emission rather than downstream.

- MuseScore's skyline autoplace, ported as a system layout pass.
  `LayoutShape`, `Skyline` (north/south lines with a staff-line filter)
  and `AutoplaceRules` (distance and ignore tables) replace the four
  per-measure autoplace approximations, and autoplaced element shapes are
  now measured from font metrics.

- Android: transposed notation and playback, with drum staves exposed to
  hosts; count-in (pre-roll) before playback; and the metronome's MIDI is
  now shared, with Android's click rendered from it rather than from a
  parallel implementation.

- A corpus annotation-collision detector under `Tools`, which walks
  system spanners and uses true 2D AABB overlap.

### Fixed

- Layout: a hairpin no longer collides with the dynamic at its own
  start/end tick; a hidden mid-measure voice no longer draws a full-width
  bar; melismas bucket by their own row offset rather than raw Y; SMuFL
  runs are measured by glyph ink rather than the Bravura em box; the
  tempo beat glyph's ink is centred on its origin as `ScoreLayerBuilder`
  draws it; and grace chords are no longer double-shifted.

- PDF import: Tier 2 no longer reads ordinary digits as time-signature
  digits; the classifier cache is keyed by glyph ID as well as codepoint;
  a simple-font text run is placed at its start rather than its end; and
  `GlyphClassifier` gate races and full-Bravura rejection are fixed.

- Android: count-in sounds with the metronome switched off, and the
  metronome plays off a transport instead of firing clicks directly.

## [1.4.0] - 2026-07-25

### Added

- `Part.isVisibleInScore` — MuseScore's `<Part><show>` "hide instrument
  in the main score" flag is now decoded and modelled. It is read
  identically from MuseScore 3 (id-less `<Part>`, `<Staff id="N">`) and
  MuseScore 4 (`<Part id="N">`, id-less `<Staff>`) files, where `<show>`
  sits at the same position as a direct child of `<Part>`; absent or
  `<show>1</show>` decodes as visible. The encoder round-trips it,
  emitting `<show>0</show>` only for hidden parts (matching MuseScore,
  which omits it when visible). The flag is display-only: hosts drive
  the actual hiding through `Score.filtered(hidingStaves:)`, so the part
  stays in the model and in playback and a reader can reveal it.

### Fixed

- `Score.filtered(hidingStaves:)` mishandled brackets that span several
  single-staff parts (e.g. a five-part vocal group under one section
  bracket). It re-spanned brackets within a single part, clamping the
  span to that part's staff count — so hiding a staff below the group
  collapsed the whole bracket onto its anchor staff, and hiding the
  anchor's part dropped the bracket entirely. Bracket survival, span,
  and anchor are now recomputed over the global (flattened) staff order,
  so a cross-part bracket contracts correctly around hidden staves and
  re-anchors onto the first surviving staff when its own anchor is
  hidden. Staff- and part-dropping semantics are unchanged.

## [1.3.0] - 2026-07-24

### Added

- Fall, doit, plop and scoop — MuseScore's `<ChordLine>` — are now
  imported, laid out, drawn and exported. They previously vanished on
  import: the element was not modelled anywhere, so the MSCX decoder's
  permissive skip dropped it silently and nothing downstream could draw
  it. Covers all twelve palette variants (the default curved shapes, the
  straight "slide in/out" forms, and the wavy "rough" forms, which use
  the SMuFL `brassFallRoughShort` / `brassLiftShort` glyphs), on the
  SwiftUI Canvas renderer, the CALayer renderer and the Android draw
  program. `Chord.chordLines` carries them; both the `<Chord>`-level and
  `<Note>`-nested MSCX forms round-trip, including a user-dragged
  `<Path>`. Geometry is ported from MuseScore 4's
  `TLayout::layoutChordLine` and verified against its own PDF output.
  MIDI is deliberately unaffected — MuseScore's SMF export ignores chord
  lines too.
- Chord lines take part in horizontal spacing, mirroring upstream: a
  line widens the gap to its neighbour only when the two shapes
  vertically intersect, and never against a barline.

### Fixed

- `MSCXEncoder`'s chord rebuild in `encodeChord` no longer drops
  chord-attached fields it does not name explicitly.

## [1.2.6] - 2026-07-22

### Fixed

- Staves voiced through SF2 note-on modulators — most visibly
  MuseScore_General's Acoustic Grand Piano — no longer render near-silent on the
  SwiftySynth backend. Bumps swiftysynth 0.1.2 → 0.2.0 and enables
  `SynthesizerSettings.enableModulators`, so the synth applies each region's
  note-on velocity/key modulators (attenuation, filter cutoff/Q, pitch/LFO/
  envelope depths, tune, reverb/chorus sends) once at note start. swiftysynth's
  MeltySynth port had discarded these, collapsing the piano's velocity-crossfade
  layering; the ON-path loudness now matches FluidSynth 3.5.5 within ~0.2 dB.

## [1.2.5] - 2026-07-22

Fixes another defect in the injected-`SynthBackend` playback path introduced in
1.2.0, when live playback moved from AUMIDISynth to SwiftySynth. Hosts on the
built-in AUMIDISynth path were not affected.

### Fixed

- `PlaybackEngine.skip(by:)` now works on the injected `SynthBackend` path. It
  guarded on the AUMIDISynth `sequencer`, which is never built when a backend is
  injected (`play` returns early into `backendPlay`), so every relative seek was
  a silent no-op — a host's seek bar, the lock-screen scrubber
  (`changePlaybackPositionCommand`), and the ±N-second skip buttons were all
  dead. `skip(by:)` now routes its resolved target frame through `seek(to:)` when
  a backend is injected, reusing the same count-in pre-roll drop, loop snap, and
  `currentCursor` update as an absolute seek.

## [1.2.4] - 2026-07-20

### Changed

- `PlaybackEngine.setMasterGain(_:)` no longer caps the gain at 3.0. Negative
  values are still clamped to zero; there is no upper bound. The ceiling was a
  product decision in the wrong layer: how loud playback should be depends on
  the synth backend's output level and on what the host is trying to sound
  like, neither of which the engine can judge. A host calibrating a quiet
  backend against a louder reference can legitimately need more than 3×, and
  the cap left it with no recourse. The downstream peak limiter still prevents
  hard clipping, so the host owns the loudness/limiting trade-off.

## [1.2.3] - 2026-07-20

Fixes four defects in the injected-`SynthBackend` playback path introduced in
1.2.0, when live playback moved from AUMIDISynth to SwiftySynth. Hosts on the
built-in AUMIDISynth path were not affected by any of them.

### Fixed

- Playback now stops when it reaches the end of the score, and a whole-score
  repeat now loops. The cursor poll compared a frame-snapped tick against
  offset-valued boundaries: `SwiftySynthBackend.currentTick` is a
  `PlaybackTimeline.frame(atTime:)` lookup, `frames` carries note onsets only,
  and `frame(atTime:)` clamps to the last one — so the polled tick saturated at
  the final onset while both boundaries (`totalTicks` and the loop end from
  `itemEndTicks`) sit strictly past it. Neither was ever reached, so the engine
  stayed `.playing` forever with the cursor parked on the last note, and a loop
  covering the whole score never wrapped. End-of-score detection now asks the
  transport (`SynthBackend.isAtEnd`) instead of comparing against the timeline,
  and the loop wrap compares in score-space seconds.
- The playback cursor now tracks the audio on scores with repeats or jumps.
  The transport plays the unrolled render (repeats expanded) but its position
  was looked up directly in the notated timeline, so from the second
  measure-play onward the cursor ran a full measure-play ahead, then froze on
  the last frame once the unrolled position passed the notated duration.
- `currentTimeSeconds` / `currentTimeSecondsContinuous` — what a host publishes
  as elapsed playback time — carried the same drift and freeze, and
  `currentTimeSecondsContinuous` was additionally quantized to note onsets
  despite documenting itself as interpolating within a frame. All three backend
  reads now share one derivation from the transport's own clock.
- Playback through the SwiftySynth backend is 6 dB louder.
  `Synthesizer.masterVolume` was left at MeltySynth's C# default of 0.5, so
  every voice was attenuated before the engine's own gain stage. It now runs at
  unity and lets `setMasterGain` own the level.

### Added

- `SynthBackend.isAtEnd`, the transport's own end-of-sequence signal, with a
  default of `false` for backends that cannot report one.
- `PlaybackUnroll.Span` and `.spans` are now public, so an unrolled↔notated
  seconds projection can be built from another module.

## [1.2.2] - 2026-07-20

### Fixed

- Single-note audition through an injected `SynthBackend` (e.g. SwiftySynth)
  now sounds at the correct instrument and volume. A preview drives the synth
  directly rather than through the sequencer, so — unlike playback — it never
  received the mixer's program / channel volume: the async SoundFont load
  leaves the synth's channels at General-MIDI defaults at `prepare` time, and
  a prior playback's sequencer resets them too, so an audition sounded on
  program 0 (piano) at the default volume (near-inaudible for many parts).
  `playPreview` / `previewNoteOn` now re-assert the staff channel's program +
  volume immediately before each note-on.
- An injected-backend audition no longer clicks off its release tail, and a
  prior audition's tail no longer bleeds into the next one. Parking the audio
  engine right after the preview's note-off froze a software synth's render
  thread mid-release; the park is now deferred until the release tail has
  rendered out (a newer preview cancels the pending park). The AUMIDISynth
  path was unaffected and is unchanged.

### Changed

- Bumped the SwiftySynth dependency 0.1.1 → 0.1.2.

## [1.2.1] - 2026-07-19

### Fixed

- Glissandi that cross a measure boundary are now drawn. A glissando on the
  last chord of a measure — whose target is the first note of the next
  measure — was silently dropped, because line emission ran per-measure and
  only paired a note with the next chord *within the same measure*. Glissando
  geometry now resolves in a post-pass (mirroring tie resolution), pairing a
  note with the next chord of its voice across measure — and system —
  boundaries.
- Glissandi that cross a system break render as two legible segments: a
  labelled departure stub at the source note and an arrival stub reaching the
  target note, each held to a bounded staff-relative (pitch-space) slope
  clamped to ±1.5 sp so the line can never plunge across neighbouring staves.

### Added

- Sustained tap-preview API on `PlaybackEngine`: `previewNoteOn(pitch:onStaff:velocity:)`
  starts a held preview note (e.g. a bar press-hold) and `previewNoteOff(pitch:)`
  releases it — distinct from the existing fixed-duration
  `playPreview(noteID:in:duration:velocity:)`. Works on both the built-in
  AUMIDISynth path and an injected `SynthBackend` (e.g. SwiftySynth), and
  correctly interleaves with an in-flight tap preview in either order.
- Asynchronous SoundFont loading in `SwiftySynthBackend`: `prepare(soundfontURL:)`
  now reads + parses the SoundFont (tens to hundreds of MB) off the main actor
  instead of freezing the UI. `SynthBackend` gained `isReady` / `onReadyChanged`
  (with a synchronous-backend default), and `PlaybackEngine` surfaces
  `isPreparingSoundfont` and defers a play requested mid-load until the synth is
  ready. A superseding reload / teardown cancels the prior in-flight load. The
  AUMIDISynth path stays synchronous and always ready.

### Changed

- Bumped the `swiftysynth` dependency to 0.1.1, which bulk-copies the SoundFont
  sample chunk (per-sample read loop → single `memcpy`) — orders of magnitude
  faster to load a large font, especially in unoptimized debug builds.

## [1.1.1] - 2026-07-19

### Added

- Android JNI anchor primitives for freehand annotation: `nativeResolveAnchor`
  (a document-millimetre point → its `ResolvedAnchor`) and
  `nativeAnchorReferencePoint` (batched `[AnchorIdentity]` → `[AnchorRefPoint]`,
  with an `spMm == 0` sentinel per unresolved anchor so the array stays
  positionally aligned), plus their `SheetMusicJNI` Kotlin facade. Thin,
  app-agnostic wrappers over the shipped `SheetMusicLayout.resolveAnchor` /
  `anchorReferencePoint`, mirroring the `nearestCursor` bridge — the affine bake
  stays in the consumer's shared code.

## [1.0.0] - 2026-07-10

First public release.

### Added

- MuseScore `.mscx` / `.mscz` import and export, targeting MuseScore 4
  (default) or MuseScore-3.6.2-flavoured output
  (`MSCXEncoderOptions(targetVersion: .v3)`).
- MusicXML `.musicxml` / `.mxl` import.
- A typed, `Sendable` value-type score model (`SheetMusicCore`) with
  parse diagnostics (`parseWithDiagnostics`).
- Score → Standard MIDI File rendering, verified against MuseScore's own
  `midiexport_tests.cpp` fixtures via semantic-equivalence comparison.
- A pure-geometry layout engine (`SheetMusicLayout`) with a
  `FontMetricsProvider` dependency-injection seam.
- SwiftUI notation viewer (`SheetMusicUI`) with a moving playback cursor,
  and PDF export (`SheetMusicPDF`).
- AVFoundation-backed playback and audio-file export (`SheetMusicAudio`),
  including a configurable count-in / pre-roll click.
- Experimental PDF-score import.
- Android: the Foundation-only subset cross-compiled via the Swift Android
  SDK, plus Kotlin AAR modules for JNI bridging and FluidSynth + Oboe
  playback.

[Unreleased]: https://github.com/jiyimeta/swift-sheet-music/compare/2.1.0...HEAD
[2.1.0]: https://github.com/jiyimeta/swift-sheet-music/compare/2.0.1...2.1.0
[2.0.1]: https://github.com/jiyimeta/swift-sheet-music/compare/2.0.0...2.0.1
[2.0.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.15.0...2.0.0
[1.13.1]: https://github.com/jiyimeta/swift-sheet-music/compare/1.13.0...1.13.1
[1.13.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.12.0...1.13.0
[1.12.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.11.0...1.12.0
[1.11.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.10.1...1.11.0
[1.10.1]: https://github.com/jiyimeta/swift-sheet-music/compare/1.10.0...1.10.1
[1.10.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.9.0...1.10.0
[1.9.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.8.0...1.9.0
[1.8.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.7.0...1.8.0
[1.7.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.6.0...1.7.0
[1.6.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.5.1...1.6.0
[1.5.1]: https://github.com/jiyimeta/swift-sheet-music/compare/1.5.0...1.5.1
[1.5.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.3.0...1.4.0
[1.3.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.6...1.3.0
[1.2.6]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.5...1.2.6
[1.2.5]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.4...1.2.5
[1.2.4]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.3...1.2.4
[1.2.3]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.2...1.2.3
[1.2.2]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.0...v1.2.1
[1.1.1]: https://github.com/jiyimeta/swift-sheet-music/releases/tag/v1.1.1
[1.0.0]: https://github.com/jiyimeta/swift-sheet-music/releases/tag/v1.0.0
