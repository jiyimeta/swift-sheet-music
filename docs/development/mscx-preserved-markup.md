# MSCX preserved markup

**The property.** Reading a `.mscx` and writing it back does not delete the
parts of it this library does not model.

Before this existed, it did. The decoder skipped every element it did not
recognize and the encoder wrote only what the model held, so opening a
MuseScore score here and saving it erased fret diagrams, figured bass,
excerpts, `<Order>`, `<Synthesizer>`, chord stem directions, and most of
`<Style>` — silently, with no diagnostic and no test that could see it.

`Tests/SheetMusicTests/MSCXPreservationGateTests.swift` is the gate.

## What it is, and what it is not

`PreservedXML` (`Sources/SheetMusicCore/Score/PreservedXML.swift`) is an inert
mirror of an XML subtree that model values carry. Model types hold a
`preservedMarkup: [PreservedXML]`; `VoiceElement` additionally has a
`.preserved` case.

**It is fidelity, not semantics.** Preserved markup describes the file as it
was read. Editing the score can leave it stale — a preserved `<Excerpt>` still
describes the part layout of the *original* score, and nothing revalidates it.
Keeping it is judged better than deleting it, but that is a judgment, not a
guarantee. Two ways out:

- `MSCXEncoderOptions.emitPreservedMarkup = false` omits all of it on write.
- `Score.strippingPreservedMarkup()` clears every bag in the tree, including
  the `.preserved` voice elements.

**Nothing else reads it.** No layout, MIDI, playback, or editing pass looks at
a preserved subtree. It exists so `MSCXEncoder` can put back what `MSCXParser`
did not understand.

## Consumed sets

Each decoder declares the child tags it reads:

```swift
private static let consumedInstrumentChildren: Set = [
    "Articulation", "Channel", "Drum", …
]
```

and captures the rest with `node.preservedMarkup(consuming: consumedInstrumentChildren)`.

**Capturing only the UNCONSUMED children is what makes this safe under
editing.** Anything the model represents is never in a bag, so a preserved copy
can never resurrect content an edit removed, and can never contradict a value
the encoder writes from the model. The rejected alternative — keep every child
and subtract the encoder's output at write time — needs no declarations and
never drifts, but deleting one note of a three-note chord would have the third
note reappear from the bag.

Two rules for writing a consumed set:

- **Read the decoder body**, every `first("…")`, `all("…")`,
  `firstDouble` / `firstBool` / `firstInt` call, and every name-matched branch.
- **Include legacy spellings** the decoder accepts for older MuseScore
  generations — `<Style>` consumes both `Spatium` and `spatium`. A tag missing
  from the set would otherwise be written twice.

## Where preserved markup is written back

**Order-insensitive containers** (`<Score>`, `<Style>`, `<Part>`,
`<Instrument>`, `<Channel>`, the `<Staff>` declaration, `<Measure>`, `<Chord>`,
`<Note>`, …) append it after the encoder's own children, in source order, via
`appendPreservedMarkup(_:to:options:)`. MuseScore's reader dispatches these by
tag name, so position does not matter.

**`<voice>` is the exception.** A `<Symbol>` or `<FiguredBass>` written between
two chords means "attached at that tick"; appending it at the end of the bar
would move it. So a voice child becomes `VoiceElement.preserved` and rides the
element stream in position, like `.locationShift`. It occupies no tick budget —
both `tickCount` overloads answer `nil`.

### The encoder's own value wins

`appendPreservedMarkup` skips any tag the encoder already wrote for that node.
This is required, not an optimization: for a v3 target the encoder synthesizes
`<showInvisible>`, `<showFrames>`, `<LayerTag>`, and `<currentLayer>` with
fixed values, and no decoder reads them — so they are also sitting in preserved
markup, and appending blindly would write two of each.

`<Beam>` is the same rule in the voice stream. The decoder reads `<visible>`
from it *and* keeps the node, so its unmodeled `<l1>` / `<l2>` stem positions
survive; the encoder then suppresses its synthesized hidden `<Beam>` when a
preserved one already sits before that chord.

**That skip would equally hide a tag missing from a consumed set**, which would
otherwise show up as a double write. `MSCXPreservedMarkupTests.preservedNamesNeverCollide`
is what catches that drift: it intersects each bag's tag names with the children
of an encode made with `emitPreservedMarkup = false`.

## Tags that are never preserved

`PreservedMarkupPolicy.neverPreserved` holds them, each with its reason:

| tag | why |
|---|---|
| `eid`, `LastEID` | MuseScore 5 element identity. This encoder declares `version="4.60"`, and 4.6 does not use `<eid>`. An id duplicated or stranded by an edit is worse than an absent one — MuseScore regenerates them on load. |
| `programVersion`, `programRevision` | The encoder writes its own values for the format generation it targets. |

**The exclusion fires at a capture point, not inside a captured subtree.**
`<Note><LaissezVib><eid>` comes back, because `<LaissezVib>` is preserved whole
and its id rides along with the element it identifies — which keeps that
subtree internally consistent. What the exclusion is for is an id on an element
the model *does* represent, where an edit can strand it.

## The gate and its allowlist

The gate decodes each committed fixture, encodes it, and requires that every
`parent/child` element pair in the source still appears at least as often in
the output.

**Pairs, not bare tag names.** A bare name cannot tell a real loss from a
legitimate move: MuseScore 2 and 3 write `<Chord>` directly under `<Measure>`,
and this encoder always writes it under `<voice>`.

`MSCXPreservation.allowedLosses` maps a pair to the reason the loss is
accepted. Two tests hold it exactly equal to the measured loss set — one fails
on a loss that is not allowed, the other on an allowed loss no fixture produces
any more. An entry therefore cannot rot in place.

**A new entry needs a reason that names a decision, not a symptom.** "Not
implemented yet" is only acceptable when it also names what would finish it.
Several existing entries record losses that are real and are *not* fixable by
preserving them, which is worth saying out loud rather than hiding:

- `Instrument/instrumentId` — MuseScore writes the `id` ATTRIBUTE as the
  instrument-template id and the `<instrumentId>` ELEMENT as the MusicXML Sound
  ID, two different values, and this decoder collapses them. The element cannot
  ride in preserved markup because the encoder synthesizes it for percussion
  kits. Recovering the Sound ID needs `Instrument` to model it.
- `voice/KeySig` — a staff-head C major, which *is* modeled; the encoder omits
  it because MuseScore does not write a redundant natural-sign key there.
- `Style/Spatium` — the v4 encoder writes the lowercase spelling; the value
  round-trips.

## The corpus sweep, opt in

The committed corpus is 43 fixtures and contains no figured bass, no fret
diagram, and no excerpt at all — the very things this mechanism exists for. The
sweep runs the same comparison over a directory of real scores:

```bash
SM_MSCX_PRESERVATION_DIR=~/path/to/scores swift test --filter MSCXPreservationSweep
```

It is disabled when the variable is unset, and follows `MSCXIdempotencySweep`
exactly: a file that will not decode is reported and skipped, a file that
decodes but throws on encode is counted as `failed` and fails the sweep. It
prints its counts, because "no failure was reported" and "it measured every
score" are different facts. **Quote the counts, not the conclusion.**

## Its relationship to the idempotency gate

`docs/development/mscx-idempotency.md`'s 2-pass gate is the safety net for this
mechanism and must not be weakened. Preserved markup lands in pass 1's output;
pass 2 has to re-capture it into the same bags and write it to the same
positions. A stream element that moves by one position between passes, or a
consumed-set entry that causes a double write, shows up there as a byte
difference. Run both gates after any change to `Sources/SheetMusicMSCX/`.

## Known gaps

- **Attributes.** Only elements are preserved. An unconsumed *attribute* on an
  otherwise-modeled element is still dropped. MSCX uses attributes sparingly
  (`version`, `id`, `name`, `len`, and `open` / `useFlat` on
  `<StringData><string>`) and those are all consumed, so this has not bitten
  yet.
- **`<Staff>` body ordering.** `<VBox>` / `<HBox>` / `<TBox>` sit as siblings of
  `<Measure>`, where order is meaning, and the model has no `MeasureBase`-style
  sequence to hold them. Out of scope here; see
  `docs/musescore-model-parity.md` §4.4.
- **`<text>` inline markup.** `<b>`, `<i>`, `<font>`, `<sym>` inside a text
  element are flattened to a plain `String` by the decoder. Preserving them as
  markup would leave stale formatting behind the moment the text is edited; the
  fix is the `TextContent` work in `docs/musescore-model-parity.md` §7.1.
- **Root level.** Unknown children of `<museScore>` itself have no bag. Across
  the committed fixtures only `programVersion`, `programRevision`, and
  `LastEID` appear there and all three are excluded by policy, so nothing is
  lost today — but a file carrying, say, a `<Revision>` would need one.
