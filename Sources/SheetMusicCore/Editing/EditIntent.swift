import SheetMusicFoundation

/// What a host asked the score to become — the unit of editing that crosses a process or image boundary.
///
/// An intent is deliberately *scalar*: identities and numbers only, never a slice of the score. That is what lets an
/// Android host relay one to a second copy of this module as a handful of bytes, and lets both copies plan it into
/// the same commands rather than shipping the commands themselves. The heavy commands — the ones carrying whole
/// `VoiceElement` subtrees — are built on each side from these scalars and never travel.
///
/// The case order below is documentation; `EditIntentWire` (`SheetMusicEditWire`) is the committed wire order — new
/// cases are appended to BOTH, at the end, and never renumbered.
public enum EditIntent: Sendable, Equatable {
    /// Write a note into a rest slot. `duration` retimes the slot in the same undo step; `nil` keeps the slot's
    /// current length.
    case inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?)
    case setRestDuration(at: VoiceElementID, duration: NoteDuration)
    case setChordDuration(at: VoiceElementID, duration: NoteDuration)
    case delete(at: VoiceElementID)
    /// Several intents as one undo step.
    indirect case composite([EditIntent])

    // Appended after the five cases above, which are wire indices 0…4 and must keep them.

    /// Retune one note within a chord. `accidental` is the glyph to display, or `nil` to suppress it.
    case setNotePitch(at: NoteID, pitch: Int, tpc: Int, accidental: Accidental?)
    /// Apply (or clear, when `accidental` is `nil`) an explicit accidental on a note, preserving its diatonic
    /// letter.
    case setAccidental(at: NoteID, accidental: Accidental?)
    /// Append a note to an existing chord.
    case addNoteToChord(at: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?)
    /// Drop one note from a chord. Removing the last note collapses the chord to a rest.
    case removeNoteFromChord(at: NoteID)
    /// Tie two adjacent notes, or remove a tie when both `sourceTieForward` and `targetTieBack` are `nil`.
    case setTie(from: NoteID, to: NoteID, sourceTieForward: Int?, targetTieBack: Int?)
    /// Convert the chord or rest at `at` into a tuplet of `actualNotes` members in the time of `normalNotes`.
    case createTuplet(at: VoiceElementID, actualNotes: Int, normalNotes: Int)
    /// Collapse the tuplet containing `at` back into a single chord or rest of the same tick span.
    case removeTuplet(at: VoiceElementID)

    /// Write a note into a slot that already holds a chord: re-pitch it, and re-time it to `duration` in the same
    /// undo step. `nil` keeps the slot's current length.
    ///
    /// Distinct from `.inputNote`, which targets a rest — and deliberately not a widening of it, because a rest slot
    /// and an occupied one differ in what "write a note here" has to do. The separation earns its keep at the
    /// barline: when `duration` outruns the bar this spells the note as a tied chain carrying the NEW pitch, which
    /// `.setChordDuration` followed by `.setNotePitch` cannot express. The chain is planned by cloning a chord, so
    /// the second intent would retune only the chain's head and leave its tail tied to it at the old pitch.
    case writeNote(at: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?)

    /// Make the timed slot at `at` a rest of `duration`, whatever is in it now — the rest key's own meaning, over a
    /// note as much as over a rest.
    ///
    /// Distinct from `.setRestDuration`, which only re-times a rest, and NOT expressible as
    /// `.composite([.delete, .setRestDuration])`: `.delete` collapses a bar it empties into one measure rest, which
    /// would throw away the very length this intent is stating and take the bar's remaining subdivision with it.
    /// The delete here is the plain one, on purpose. `.delete` keeps its collapse — that is right for ⌫, which is
    /// emptying the bar rather than stating a length.
    case writeRest(at: VoiceElementID, duration: NoteDuration)

    /// Insert a blank measure column before `index`; `index == measureCount` appends at the end.
    case insertMeasure(at: Int)
    /// Delete the measure column at `index`.
    case deleteMeasure(at: Int)

    /// Insert a new part built from `plan` before `index`; `index == parts.count` appends. The one intent that
    /// carries something other than scalars — a `PartPlan` is the instrument's identity and staff list, not a slice
    /// of the score, and both images build the same `Part` from it rather than shipping the built part across.
    ///
    /// An out-of-range `index` is refused as `.targetNotFound` by `AddPart.apply` rather than by the session's
    /// planner: one place states the range, and the answer is the same whether the command is reached through an
    /// intent or built directly.
    case addPart(plan: BlankScoreTemplate.PartPlan, at: Int)

    /// Remove the whole part at `index` — its instrument, its staves and their bars.
    ///
    /// Refused with `.cannotRemoveLastPart` when it would empty the score of parts, and with `.targetNotFound` for
    /// an index that names no part; both answers come from `RemovePart.apply`, so they are the same whether the
    /// command is reached through this intent or built directly.
    case removePart(at: Int)

    /// Move the part at `from` to `to` — a removal followed by an insertion, so `[A, B, C]` with
    /// `.movePart(from: 0, to: 1)` becomes `[B, A, C]`.
    ///
    /// Both indices name positions in the current parts array; unlike `.addPart`, `to == parts.count` is out of
    /// range, because a move cannot grow the score. `from == to` resolves to nothing to apply rather than pushing
    /// an undo entry that restores the score to itself.
    case movePart(from: Int, to: Int)

    /// Rename the part at `index`: the long name engraved at the left of the first system, and the abbreviation
    /// engraved there on every system after it.
    ///
    /// Both names travel together because a host editing both wants one undo step, not two that can be taken back
    /// separately into a half-renamed score. A host editing one passes the other's current value.
    ///
    /// `nil` clears rather than leaving the name alone — a part carrying no abbreviation engraves no label from
    /// the second system on, which is a thing a score can want to say. Resolves to nothing to apply when both
    /// names already read that way, the same rule `.movePart` applies to a move onto its own index. An
    /// out-of-range `index` is refused as `.targetNotFound` by `SetPartNames.apply`, so one place states the range.
    case setPartNames(at: Int, longName: String?, shortName: String?)

    /// Set the concert key in force from `measureIndex` to the next explicit key change (or the end of the
    /// score): writes/replaces the `.keySignature` on every non-percussion staff at that measure and
    /// re-spells accidental glyphs over the affected span, as one undo step.
    ///
    /// Resolves to nothing to apply when that key is already the one in force there — restating a key the score
    /// already declares would push an undo entry that restores the score to itself, the same rule `.movePart`
    /// applies to a move onto its own index. An out-of-range `measureIndex` is refused as `.targetNotFound` by
    /// `SetKeySignature.apply`, so one place states the range.
    case setKeySignature(measureIndex: Int, concertKey: Int)

    /// Remove the explicit key change at `measureIndex`, reverting its span to the previous key. Refused
    /// with `.cannotRemoveInitialSignature` at measure 0; plans to nothing when no explicit key change exists
    /// there.
    ///
    /// The span that reverts is re-spelled in the same undo step, for the same reason `.setKeySignature` re-spells
    /// its own: the bars after a removed change are byte-identical and yet every accidental in them is now judged
    /// against a different signature.
    case removeKeySignature(measureIndex: Int)

    /// Set the time signature in force from `measureIndex` to the next explicit time change (or the end of the
    /// score), RE-BARRING that region: its content is re-partitioned into bars of the new length, notes the new
    /// barlines cut are split and tied, and the score's measure count may change. One undo step.
    ///
    /// Resolves to nothing to apply when that meter is already the one in force there — the same rule
    /// `.setKeySignature` and `.movePart` apply to an edit that would restore the score to itself. Refused as a
    /// whole, with the score untouched, when the new barring would split a tuplet
    /// (`.rebarWouldSplitTuplet`) or slide a repeat sign off the barline it marks
    /// (`.rebarWouldDisplaceBarlineMarker`): a re-bar is one edit, so it either lands or it does not.
    case setTimeSignature(measureIndex: Int, numerator: Int, denominator: Int)

    /// Remove the explicit time change at `measureIndex`, re-barring its span back to the meter that was in force
    /// before it. Refused with `.cannotRemoveInitialSignature` at measure 0; plans to nothing when no explicit
    /// time change exists there.
    case removeTimeSignature(measureIndex: Int)

    /// Write `text` as the rehearsal mark at the head of `measureIndex` — replacing the mark that bar already
    /// carries, or creating one where it carried none. The text is trimmed of surrounding whitespace before it is
    /// written, and only the text changes: a renamed mark keeps the frame, color and offsets it was drawn with.
    ///
    /// Resolves to nothing to apply when that bar already carries this exact text — the same rule
    /// `.setKeySignature` and `.movePart` apply to an edit that would restore the score to itself. Text that is
    /// empty after trimming reaches `SetRehearsalMark.apply` and is refused there as `.emptyRehearsalMarkText`;
    /// an out-of-range `measureIndex` is refused there as `.targetNotFound`, so one place states each rule.
    case setRehearsalMark(measureIndex: Int, text: String)

    /// Remove the rehearsal mark at `measureIndex`. Plans to nothing when that bar carries none. No measure-0
    /// exception, unlike the signature removals: bar 1's mark is a mark like any other.
    case removeRehearsalMark(measureIndex: Int)

    /// Append a voice, filled with one full-measure rest, to `measureIndex` of `staff`.
    ///
    /// Plans to nothing when the measure already has that voice — the same rule `.setKeySignature` and
    /// `.movePart` apply to an edit that would restore the score to itself, and the one that lets a drum key
    /// compose `[createVoice, write]` unconditionally: a composite is all-or-nothing, so a refusal here would
    /// take the write with it. A voice index that would leave a hole below it is refused as `.targetNotFound` by
    /// `CreateVoice.apply`, so one place states the range.
    case createVoice(staff: StaffAddress, measureIndex: Int, voiceIndex: Int)

    /// Split the rest at `at` so a slot boundary falls `tickOffset` ticks into it, both halves spelled
    /// beat-aligned. What a column caret landing INSIDE a rest needs before anything can be written there, since
    /// every write command in this package targets a slot rather than a tick.
    ///
    /// An offset of zero, or one at or past the rest's own length, is refused as `.insufficientRoom` by
    /// `SplitRest.apply`; a slot holding a chord is refused as `.wrongElementKind`.
    case splitRest(at: VoiceElementID, tickOffset: Int)

    /// Write `headType` as one note's notehead override, or clear it with `nil`.
    ///
    /// Composed after `.inputNote` / `.addNoteToChord` — as one `.composite`, so it is one undo step — this is
    /// how a drum key writes a cross-head hi-hat: those two intents carry pitch and spelling only, and widening
    /// their wire payload would move byte layouts that are already committed.
    case setNoteHead(at: NoteID, headType: String?)

    /// Write `entry` as `pitch`'s row in the part's drum kit, or remove that row with `nil`.
    ///
    /// A drum key pressed for an instrument the open chart never used has no line to be drawn on, and the layout
    /// engine falls back to the pitched diatonic formula — putting the note somewhere no engraver would. Repairing
    /// that is a change to the score, so it travels as an intent like every other one, rather than as a mutation
    /// only one platform performs.
    ///
    /// An out-of-range `partIndex` is refused as `.targetNotFound` by `SetDrumsetEntry.apply`, so one place states
    /// the range.
    case setDrumsetEntry(partIndex: Int, pitch: Int, entry: DrumsetEntry?)

    // Appended for the edit-command parity project's structural group (spec 2026-09-02) — indices 30…34.

    /// Set or clear a layout-break flag (`.line`, `.page`, `.section`) on the measure column at `at`, on the
    /// canonical staff. Resolves to nothing to apply when that flag already reads `enabled` — the same rule
    /// `.setKeySignature` and `.movePart` apply to an edit that would restore the score to itself.
    case setLayoutBreak(at: MeasureRef, kind: LayoutBreakKind, enabled: Bool)

    /// Write `style` as the measure column's trailing barline, on every staff. `.normal` removes an explicit
    /// barline rather than writing one. Resolves to nothing to apply when the canonical staff's trailing barline
    /// already reads this way.
    case setBarLine(at: MeasureRef, style: BarLineStyle)

    /// Write the measure column's repeat flags: whether it opens a repeat, and how many times a repeat ending here
    /// plays (`nil` for no end repeat). Resolves to nothing to apply when both flags already match.
    case setRepeatBarLines(at: MeasureRef, startRepeat: Bool, endRepeatCount: Int?)

    /// Turn `numMeasures` consecutive empty bars of `staff` starting at `at` into a measure-repeat group, or (with
    /// `nil`) dissolve the group starting there back into measure rests. Resolves to nothing to apply when `nil` is
    /// asked for a bar that carries no group.
    case setMeasureRepeat(at: MeasureRef, staff: StaffAddress, numMeasures: Int?)

    /// Move the chord or rest at `at` to `to` — another voice of the same bar, at the same tick.
    case moveToVoice(at: VoiceElementID, to: VoiceRef)

    // Appended for the edit-command parity project's range group (spec 2026-09-02) — indices 35…40. Every range
    // intent expands to one `CompositeEditCommand` over `Score.voiceElements(in:)`, applied in ascending onset order
    // and re-resolved by tick (`RangeEditPlanner`); refusal on any element rolls back all of it.

    /// Move every note in `over` by `semitones` (−24…24); tie chains move whole. `respellInKey` re-spells each
    /// result to the simplest reading in the key in force. Resolves to nothing to apply for zero semitones or a
    /// range with no pitched note; refused as `.invalidTransposition` past two octaves.
    case transposeRange(over: VoiceElementRange, semitones: Int, respellInKey: Bool)

    /// Add a note `|steps|` diatonic degrees (1 unison … 9 ninth) above (positive) each chord's top note or below
    /// (negative) its bottom note. A pitch the chord already holds is skipped. Resolves to nothing to apply when no
    /// chord gains a note; refused as `.invalidInterval` outside ±1…±9.
    case addIntervalToSelection(over: VoiceElementRange, steps: Int)

    /// Turn every chord in `over` into a rest, collapsing each bar-voice left all-rests into one measure rest.
    /// Resolves to nothing to apply when the range holds no chord.
    case deleteRange(over: VoiceElementRange)

    /// Apply `accidental` to every note in `over` (letter kept, pitch moved), or clear the glyph with `nil`.
    /// Resolves to nothing to apply when every note already reads that way.
    case setAccidentalsInRange(over: VoiceElementRange, accidental: Accidental?)

    /// Set `duration` on every chord and rest in `over`, in ascending onset order, skipping onsets an earlier
    /// lengthening consumed. Refused whole as `.insideTuplet` when any element is inside a tuplet; resolves to
    /// nothing to apply when every element already has that length.
    case setDurationInRange(over: VoiceElementRange, duration: NoteDuration)

    /// Re-spell every note in `over` enharmonically per `mode`, pitches unchanged. Resolves to nothing to apply
    /// when every note is already spelled that way.
    case respellRange(over: VoiceElementRange, mode: RespellMode)

    // Appended for the edit-command parity project's mark group (spec 2026-09-02) — indices 41…49. Every mark
    // that can be present or absent is one intent whose payload is optional: the value writes or replaces, `nil`
    // removes ("nil clears", §3.1). System-lane marks (tempo, staff text) are addressed by the chord or rest they
    // sit on (§2.3); adjacent marks by the chord they attach to.

    /// Write `clef` before the chord or rest at `before`, replacing a clef already there. Resolves to nothing to
    /// apply when that clef already reads `clef`; refused as `.wrongElementKind` on a non-timed target.
    case setClef(before: VoiceElementID, clef: NotatedClef)

    /// Remove the explicit clef element at `at`. Refused as `.wrongElementKind` when it is not a clef.
    case removeClef(at: VoiceElementID)

    /// Write `marking` as the tempo at the beat of the chord or rest at `anchor`, or remove the tempo there with
    /// `nil`. Resolves to nothing to apply when the beat already carries exactly this marking, or when `nil` is
    /// asked of a beat with no tempo.
    case setTempo(anchor: VoiceElementID, marking: SetTempo.Marking?)

    /// Write `text` as the staff text (or, with `isSystemText`, the system text) at the beat of the chord or rest
    /// at `anchor`, or remove it with `nil`. Trimmed engine-side; empty after trimming is refused as
    /// `.emptyStaffText`. Resolves to nothing to apply when the text already reads this way.
    case setStaffText(anchor: VoiceElementID, text: String?, isSystemText: Bool)

    /// Write `subtype` as the dynamic on the chord at `at` (velocity from `Dynamic.defaultVelocity(for:)`), or
    /// remove it with `nil`. Resolves to nothing to apply when the chord already carries that subtype.
    case setDynamic(at: VoiceElementID, subtype: String?)

    /// Write a fermata of `subtype` with `timeStretch` over the chord or rest at `at`, or remove it with `nil`.
    /// Resolves to nothing to apply when both fields already match.
    case setFermata(at: VoiceElementID, subtype: String?, timeStretch: Double)

    /// Write a breath of `kind` with `pause` seconds after the chord at `after`, or remove it with `nil`.
    /// Resolves to nothing to apply when both fields already match.
    case setBreath(after: VoiceElementID, kind: Breath.Kind?, pause: Double)

    /// Replace the jumps of the measure column at `at` (on the canonical staff). Resolves to nothing to apply
    /// when the list is already equal.
    case setJumps(at: MeasureRef, jumps: [Jump])

    /// Replace the markers of the measure column at `at` (on the canonical staff). Resolves to nothing to apply
    /// when the list is already equal.
    case setMarkers(at: MeasureRef, markers: [Marker])

    // Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — indices 50…57. Every
    // payload here lives INSIDE the chord or note it addresses, so none of them moves an element index and none
    // needs the adjacency machinery the mark group built.

    /// Put `kind` on the chord at `at` (with `anchor`, or the encoder's default side when `nil`), or take every
    /// entry of that kind off it with `present: false`. Other kinds are untouched. Resolves to nothing to apply
    /// when the chord already reads exactly this way.
    case setArticulation(
        at: VoiceElementID, kind: ChordArticulation.Kind, anchor: ChordArticulation.Anchor?, present: Bool,
    )

    /// Replace BOTH grace lists of the chord at `at`. Two empty lists clear them. Resolves to nothing to apply
    /// when both lists already read this way.
    case setGraceNotes(at: VoiceElementID, before: [GraceChord], after: [GraceChord])

    /// Write `tremolo` on the chord at `at`, or remove it with `nil`. A `.between` span is refused as
    /// `.noNextChord` unless the next timed element of the voice is a sounding chord. Resolves to nothing to
    /// apply when the chord already carries this exact tremolo.
    case setTremolo(at: VoiceElementID, tremolo: Tremolo?)

    /// Spread the chord at `at` with an arpeggio of `subtype` (0 normal, 1 up, 2 down, 3 bracket, 4 up-straight,
    /// 5 down-straight), or remove it with `nil`. A write needs two notes (`.chordTooSmall`). Resolves to nothing
    /// to apply when the subtype already matches.
    ///
    /// `subtype: Int?` rather than an `Arpeggio` because an intent is scalar by construction (see the type's own
    /// doc comment) and `Arpeggio` carries `timeStretch`, `userLen1` and `elementProperties` the wire does not
    /// encode. The planner builds `Arpeggio(subtype:)` with its defaults; a host that needs a stretched arpeggio
    /// builds `SetArpeggio` directly.
    case setArpeggio(at: VoiceElementID, subtype: Int?)

    /// Write `glissando` on the note at `at`, or remove it with `nil`. A write is refused as `.noNextChord` when
    /// no sounding chord follows in the voice. Resolves to nothing to apply when the note already reads this way.
    case setGlissando(at: NoteID, glissando: Glissando?)

    /// Set the augmentation dots (0…3) of the chord or rest at `at`, delegating the retiming to
    /// `setChordDuration` / `setRestDuration`'s rules. Resolves to nothing to apply when the slot already carries
    /// that many.
    case setDots(at: VoiceElementID, dots: Int)

    /// Write one chord line (fall / doit / plop / scoop, curved or straight) on the chord at `at`, or clear the
    /// chord's lines with `nil`. Resolves to nothing to apply when the chord already carries exactly this one.
    case setChordLine(at: VoiceElementID, kind: ChordLine.Kind?, isStraight: Bool)

    /// Write the parentheses drawn around the notehead at `at`; `.none` removes them. Resolves to nothing to
    /// apply when the note already reads this way.
    case setNoteParentheses(at: NoteID, parentheses: NoteParentheses)

    // Appended for the edit-command parity project's visibility group (spec 2026-09-02) — indices 58…61. A
    // visibility flag is never absent, so these carry a plain `Bool` rather than the "nil clears" optional the mark
    // group uses; restating the flag the score already holds plans to nothing.

    /// Show or hide the element at `at` — any voice element that carries `ElementProperties` (a chord or rest, a
    /// clef, a barline, a key or time signature, a dynamic, a fermata, a breath, a spanner, a chord symbol). Refused
    /// as `.wrongElementKind(expected: .engravable)` on a measure repeat or a location shift.
    case setElementVisible(at: VoiceElementID, visible: Bool)

    /// Show or hide one notehead. Only the note's own flag moves — no cascade to the stem or beam (compose with
    /// `.setStemVisible` / `.setBeamVisible` for MuseScore's behavior).
    case setNoteVisible(at: NoteID, visible: Bool)

    /// Show or hide the stem (and flag) of the chord at `at`. Refused as `.wrongElementKind(expected: .chord)` on
    /// a rest.
    case setStemVisible(at: VoiceElementID, visible: Bool)

    /// Show or hide the beam of the group the chord at `at` belongs to. The planner re-targets to the group's
    /// LEADING chord, where the flag lives, so any member may be named; refused as `.notBeamed` when the chord is in
    /// no beam group.
    case setBeamVisible(at: VoiceElementID, visible: Bool)

    // Appended for the edit-command parity project's spanner group (spec 2026-09-02) — indices 62…72. Every
    // `set…` takes the RANGE it spans; the engine narrows that range to one voice and decides the storage form and
    // the end tick per kind. There is no "nil clears" here: a spanner is removed by `removeSpanner`, because the
    // removal targets a different location than the write — the `.spanner` element, or the chord holding the
    // slur — which is exactly the §3.1 exception `RemoveClef` already is. Re-issuing a `set…` at a position that
    // already carries a spanner of that kind is refused as `.duplicateSpanner`, not accepted and not
    // `.nothingToApply`, so a toggle button pairs a `set…` with `removeSpanner` rather than calling `set…` twice.

    /// Draw a slur over `over`. Refused as `.noNextChord` when the range is one element (nothing to slur to).
    case setSlur(over: VoiceElementRange)

    /// Draw a hairpin of `subtype` over `over`.
    case setHairpin(over: VoiceElementRange, subtype: Spanner.HairpinPayload.Subtype)

    /// Draw a pedal line over `over`.
    case setPedal(over: VoiceElementRange)

    /// Draw a volta over `over`, printing `endings` as its take-numbers and `text` as its label (or the endings'
    /// own default text when `nil`).
    case setVolta(over: VoiceElementRange, endings: [Int], text: String?)

    /// Draw an ottava of `subtype` over `over`.
    case setOttava(over: VoiceElementRange, subtype: Spanner.OttavaPayload.Subtype)

    /// Draw a text line over `over`, with `text` as its label (or no label when `nil`).
    case setTextLine(over: VoiceElementRange, text: String?)

    /// Draw a trill of `type` over `over`.
    case setTrill(over: VoiceElementRange, type: TrillType)

    /// Draw a vibrato of `type` over `over`.
    case setVibrato(over: VoiceElementRange, type: VibratoType)

    /// Draw a palm-mute line over `over`.
    case setPalmMute(over: VoiceElementRange)

    /// Draw a let-ring line over `over`.
    case setLetRing(over: VoiceElementRange)

    /// Remove the spanner of `kind` anchored at `at` — the `.spanner` element itself, or (for a slur) the chord
    /// carrying it. Refused as `.noSpannerAtLocation` when `at` carries no spanner of that kind.
    case removeSpanner(at: VoiceElementID, kind: Spanner.Kind)
}
