import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation
import Wirelet

/// Codec for `EditIntent` — the only thing that crosses the JNI boundary during an edit session.
///
/// Scalars only, by design: an intent names slots and numbers, never a slice of the score, so both images plan it
/// into the same commands instead of shipping the commands. See `EditIntent` for why that matters.
///
/// The `@WireFormatChoice` discriminator order is part of the format. Append new intents; never renumber.
///
/// ## Wire layout
///
/// Wirelet's TLV scheme (`Sources/Wirelet/WireFormat.swift` in `swift-wirelet`) resembles protobuf's wire format —
/// every field is a `tag` varint (`fieldNumber << 3 | wireType`) followed by its payload; signed integers are
/// zig-zag varints; nested structs, arrays, and choice enums are length-delimited (`varint(byteCount)` + that many
/// payload bytes), so they are self-delimiting and **not** fixed-width — every byte count below varies with the
/// actual field values, exactly like `ScoreItemIDCodec.swift` / `PathIDCodecs.swift`'s own tag-and-varint doc
/// comments describe for those sibling wire types. Field tags are assigned 1, 2, 3, … in declaration order; case
/// indices for a `@WireFormatChoice` enum are 0, 1, 2, … in declaration order.
///
/// **Unlike proto3, Wirelet has no default-skipping.** `WireFormatMacro.swift` emits `guard let _<field> else {
/// throw WireFormatError.unknownTag(...) }` for every non-optional stored property, and `WireFormatChoiceMacro.swift`
/// does the same for every case payload — there is no "omit a zero-valued scalar" shortcut. Every tag listed below
/// must be written on encode, including zero-valued ones (a committed golden fixture emits literal `08 00` / `10 00`
/// / `20 00` triples for exactly this reason), or decoding throws `unknownTag`. The one exception the macro allows
/// is an `Optional<T>` (`T?`) stored property, which this codec declares none of — every field below is mandatory.
///
/// `EditIntentWire` top-level bytes: `varint(payloadLength)` + payload, where payload is `varint(caseIndex)`
/// followed — for every case here, since none is payload-less — by `tag(1, lengthDelimited) +
/// associatedValue.encode()`. Case indices below are the committed order; `EditIntent`'s declaration order follows
/// it but is not the authority:
/// ```
/// 0 = inputNote(InputNoteIntentWire)
/// 1 = setRestDuration(SlotDurationIntentWire)
/// 2 = setChordDuration(SlotDurationIntentWire)
/// 3 = delete(VoiceElementIDWire)
/// 4 = composite(CompositeIntentWire)
/// 5 = setNotePitch(PitchWriteIntentWire)
/// 6 = setAccidental(SetAccidentalIntentWire)
/// 7 = addNoteToChord(AddNoteIntentWire)
/// 8 = removeNoteFromChord(NoteIDWire)
/// 9 = setTie(SetTieIntentWire)
/// 10 = createTuplet(CreateTupletIntentWire)
/// 11 = removeTuplet(VoiceElementIDWire)
/// 12 = writeNote(WriteNoteIntentWire)
/// 13 = writeRest(SlotDurationIntentWire)
/// 14 = insertMeasure(MeasureIndexIntentWire)
/// 15 = deleteMeasure(MeasureIndexIntentWire)
/// 16 = addPart(AddPartIntentWire)
/// 17 = removePart(PartIndexIntentWire)
/// 18 = movePart(MovePartIntentWire)
/// 19 = setKeySignature(SetKeySignatureIntentWire)
/// 20 = removeKeySignature(RemoveKeySignatureIntentWire)
/// 21 = setTimeSignature(SetTimeSignatureIntentWire)
/// 22 = removeTimeSignature(RemoveTimeSignatureIntentWire)
/// 23 = setRehearsalMark(SetRehearsalMarkIntentWire)
/// 24 = removeRehearsalMark(RemoveRehearsalMarkIntentWire)
/// 25 = createVoice(CreateVoiceIntentWire)
/// 26 = splitRest(SplitRestIntentWire)
/// 27 = setNoteHead(SetNoteHeadIntentWire)
/// 28 = setDrumsetEntry(SetDrumsetEntryIntentWire)
/// 29 = setPartNames(SetPartNamesIntentWire)
/// 30 = setLayoutBreak(SetLayoutBreakIntentWire)
/// 31 = setBarLine(SetBarLineIntentWire)
/// 32 = setRepeatBarLines(SetRepeatBarLinesIntentWire)
/// 33 = setMeasureRepeat(SetMeasureRepeatIntentWire)
/// 34 = moveToVoice(MoveToVoiceIntentWire)
/// 35 = transposeRange(TransposeRangeIntentWire)
/// 36 = addIntervalToSelection(AddIntervalToSelectionIntentWire)
/// 37 = deleteRange(DeleteRangeIntentWire)
/// 38 = setAccidentalsInRange(SetAccidentalsInRangeIntentWire)
/// 39 = setDurationInRange(SetDurationInRangeIntentWire)
/// 40 = respellRange(RespellRangeIntentWire)
/// 41 = setClef(SetClefIntentWire)
/// 42 = removeClef(RemoveClefIntentWire)
/// 43 = setTempo(SetTempoIntentWire)
/// 44 = setStaffText(SetStaffTextIntentWire)
/// 45 = setDynamic(SetDynamicIntentWire)
/// 46 = setFermata(SetFermataIntentWire)
/// 47 = setBreath(SetBreathIntentWire)
/// 48 = setJumps(SetJumpsIntentWire)
/// 49 = setMarkers(SetMarkersIntentWire)
/// 50 = setArticulation(SetArticulationIntentWire)
/// 51 = setGraceNotes(SetGraceNotesIntentWire)
/// 52 = setTremolo(SetTremoloIntentWire)
/// 53 = setArpeggio(SetArpeggioIntentWire)
/// 54 = setGlissando(SetGlissandoIntentWire)
/// 55 = setDots(SetDotsIntentWire)
/// 56 = setChordLine(SetChordLineIntentWire)
/// 57 = setNoteParentheses(SetNoteParenthesesIntentWire)
/// ```
///
/// Cases 5…11 were appended in SP1, 12…13 in SP2, 14…15 for M1 solo scratch creation, 16…18 for M2 ensemble
/// creation, 19…22 for M3 signature changes, 23…24 for M4 rehearsal marks, 25…28 for M6 drum note entry and 29
/// for part renaming; 0…4 predate them all and must keep their indices and byte layout. Cases 30…34 were appended
/// for the edit-command parity project's structural group (spec 2026-09-02). Cases 35…40 were appended for its
/// range group. Cases 41…49 were appended for its mark group. Cases 50…57 were appended for its note / chord
/// group.
///
/// `InputNoteIntentWire` fields, in tag order:
/// ```
/// tag 1: location     RestIDWire, see layout below
/// tag 2: pitch        i32, zig-zag varint
/// tag 3: tpc          i32, zig-zag varint
/// tag 4: hasDuration  u8, varint — 0 = keep the slot's length, 1 = retime it to `duration`
/// tag 5: duration     NoteDurationWire — present but ignored by the decoder when hasDuration == 0; the encoder
///                     always writes `kind = 1` (whole) with `numerator = denominator = 0` in that case, so a
///                     byte-for-byte parity check between platforms should expect that exact placeholder, not a
///                     zeroed-out discriminator
/// ```
///
/// `WriteNoteIntentWire` is `InputNoteIntentWire` with a `VoiceElementIDWire` location — the two intents differ in
/// what they may target (a rest slot versus an occupied one), not in what they carry:
/// ```
/// tag 1: location     VoiceElementIDWire, see layout below
/// tag 2: pitch        i32, zig-zag varint
/// tag 3: tpc          i32, zig-zag varint
/// tag 4: hasDuration  u8, varint — 0 = keep the slot's length, 1 = retime it to `duration`
/// tag 5: duration     NoteDurationWire — same `kind = 1` placeholder when hasDuration == 0
/// ```
///
/// `SlotDurationIntentWire` fields (shared by `setRestDuration` and `setChordDuration` — the discriminator case
/// index is what tells the two apart, not anything in this struct):
/// ```
/// tag 1: location  VoiceElementIDWire, see layout below
/// tag 2: duration  NoteDurationWire
/// ```
///
/// `delete` reuses `VoiceElementIDWire` directly as its payload — no wrapper struct.
///
/// `RestIDWire` and `VoiceElementIDWire` (`Sources/SheetMusicEditWire/Path/PathIDCodecs.swift`) share this field
/// layout — inlined here for convenience rather than only cross-referenced:
/// ```
/// tag 1: staff         StaffAddressWire, see layout below
/// tag 2: measureIndex  i32, zig-zag varint
/// tag 3: voiceIndex    i32, zig-zag varint
/// tag 4: elementIndex  i32, zig-zag varint
/// ```
///
/// `StaffAddressWire` (`Sources/SheetMusicEditWire/Path/StaffAddressCodec.swift`; the canonical `(partIndex: 0,
/// staffIndexInPart: 0)` value encodes to 5 bytes total once the varint length prefix and two 1-byte zig-zag
/// zeros are counted):
/// ```
/// tag 1: partIndex          i32, zig-zag varint
/// tag 2: staffIndexInPart   i32, zig-zag varint
/// ```
///
/// `CompositeIntentWire`:
/// ```
/// tag 1: members  [EditIntentWire] — length-delimited array; each element is itself a length-delimited,
///                 self-describing EditIntentWire record (same top-level shape as above, recursively)
/// ```
/// The element type is spelled `NestedEditIntentWire` in Swift — a forwarding wrapper that bounds the parse depth
/// — but its bytes are an `EditIntentWire`'s, so the framing above is what a decoder in any language sees.
///
/// The brief anticipated `@WireFormatChoice` might reject this recursion (an array of the very enum that
/// contains it) and planned a `[Data]`-of-already-encoded-children fallback for that case. It was not needed:
/// `Array`'s representation is a fixed-size (pointer-sized) reference to a heap buffer regardless of `Element`,
/// so wrapping the recursive member list in `CompositeIntentWire` never gives `EditIntentWire` a self-referential
/// *size*, and the macro expansion — which only emits code, it does not require a finite layout up front — went
/// through unmodified. No `indirect` was needed either, for the same reason.
///
/// `NoteDurationWire` — `NoteDuration` as a discriminator plus an optional fraction. `.fraction` is the only case
/// with a non-zero payload, so `numerator` / `denominator` are `0` for every other case:
/// ```
/// tag 1: kind        u8, varint — 1=whole 2=half 3=quarter 4=eighth 5=sixteenth 6=thirtySecond 7=sixtyFourth
///                    8=oneTwentyEighth 9=twoFiftySixth 10=measure 11=fraction
/// tag 2: numerator    i32, zig-zag varint — only meaningful when kind == 11
/// tag 3: denominator  i32, zig-zag varint — only meaningful when kind == 11
/// ```
/// This numbering is deliberately identical to `Score.stableFingerprint`'s duration walk (`ScoreFingerprint.swift`)
/// so the two never disagree about what a number means.
///
/// `NoteIDWire` (`Sources/SheetMusicEditWire/Path/PathIDCodecs.swift` — same layout as
/// `RestIDWire`/`VoiceElementIDWire` above, plus one field):
/// ```
/// tag 1: staff             StaffAddressWire, see layout above
/// tag 2: measureIndex      i32, zig-zag varint
/// tag 3: voiceIndex        i32, zig-zag varint
/// tag 4: elementIndex      i32, zig-zag varint
/// tag 5: noteIndexInChord  i32, zig-zag varint
/// ```
///
/// `AccidentalWire` — `Accidental?` as its raw-value string rather than a case index, because `Accidental`'s case
/// order is not this codec's to control:
/// ```
/// tag 1: present  u8, varint — 0 = no accidental (nil), 1 = raw names one
/// tag 2: raw      string — the `Accidental` raw value (e.g. "accidentalSharp"); "" when present == 0. A spelling
///                 the reader does not recognize throws rather than decoding as "no accidental".
/// ```
///
/// `OptionalIndexWire` — an `Int?` tie index; `.setTie`'s two forward/back links each carry one:
/// ```
/// tag 1: present  u8, varint — 0 = nil, 1 = value holds it
/// tag 2: value    i32, zig-zag varint — 0 when present == 0
/// ```
///
/// `PitchWriteIntentWire` (`setNotePitch`'s payload):
/// ```
/// tag 1: location    NoteIDWire, see layout above
/// tag 2: pitch       i32, zig-zag varint
/// tag 3: tpc         i32, zig-zag varint
/// tag 4: accidental  AccidentalWire, see layout above
/// ```
///
/// `SetAccidentalIntentWire` (`setAccidental`'s payload):
/// ```
/// tag 1: location    NoteIDWire, see layout above
/// tag 2: accidental  AccidentalWire, see layout above
/// ```
///
/// `AddNoteIntentWire` (`addNoteToChord`'s payload):
/// ```
/// tag 1: location    VoiceElementIDWire, see layout above
/// tag 2: pitch       i32, zig-zag varint
/// tag 3: tpc         i32, zig-zag varint
/// tag 4: accidental  AccidentalWire, see layout above
/// ```
///
/// `removeNoteFromChord` reuses `NoteIDWire` directly as its payload — no wrapper struct, the same pattern `delete`
/// uses for `VoiceElementIDWire`.
///
/// `SetTieIntentWire` (`setTie`'s payload):
/// ```
/// tag 1: source            NoteIDWire, see layout above
/// tag 2: target            NoteIDWire, see layout above
/// tag 3: sourceTieForward  OptionalIndexWire, see layout above
/// tag 4: targetTieBack     OptionalIndexWire, see layout above
/// ```
///
/// `CreateTupletIntentWire` (`createTuplet`'s payload):
/// ```
/// tag 1: location     VoiceElementIDWire, see layout above
/// tag 2: actualNotes  i32, zig-zag varint
/// tag 3: normalNotes  i32, zig-zag varint
/// ```
///
/// `removeTuplet` reuses `VoiceElementIDWire` directly as its payload — no wrapper struct, same pattern as `delete`.
///
/// `MeasureIndexIntentWire` (shared by `insertMeasure` and `deleteMeasure` — the discriminator case index is what
/// tells the two apart, not anything in this struct; same pattern as `SlotDurationIntentWire` above):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// ```
///
/// `AddPartIntentWire` (`addPart`'s payload):
/// ```
/// tag 1: plan       PartPlanWire, see layout below
/// tag 2: partIndex  i32, zig-zag varint
/// ```
///
/// `PartPlanWire` — `BlankScoreTemplate.PartPlan`. The two optional names follow `AccidentalWire`'s present-flag
/// pattern rather than becoming `Optional` stored properties, so every field here stays mandatory like the rest of
/// this file:
/// ```
/// tag 1:  instrumentID        string
/// tag 2:  hasLongName         u8, varint — 0 = nil, 1 = longName holds it
/// tag 3:  longName            string — "" when hasLongName == 0
/// tag 4:  hasShortName        u8, varint — 0 = nil, 1 = shortName holds it
/// tag 5:  shortName           string — "" when hasShortName == 0
/// tag 6:  staves              [StaffPlanWire] — length-delimited array, each element itself length-delimited
/// tag 7:  transposeDiatonic   i32, zig-zag varint
/// tag 8:  transposeChromatic  i32, zig-zag varint
/// tag 9:  gmProgram           i32, zig-zag varint
/// tag 10: isDrums             u8, varint — 0 / 1
/// ```
///
/// `StaffPlanWire` — `BlankScoreTemplate.StaffPlan`:
/// ```
/// tag 1: clefType      string — the MuseScore clef token ("G", "F", "PERC", …)
/// tag 2: isPercussion  u8, varint — 0 / 1
/// ```
///
/// `PartIndexIntentWire` (`removePart`'s payload — a part-index sibling of `MeasureIndexIntentWire`, kept separate
/// so neither struct's field has to be read as naming something it does not):
/// ```
/// tag 1: partIndex  i32, zig-zag varint
/// ```
///
/// `MovePartIntentWire` (`movePart`'s payload):
/// ```
/// tag 1: fromIndex  i32, zig-zag varint
/// tag 2: toIndex    i32, zig-zag varint
/// ```
///
/// `SetKeySignatureIntentWire` (`setKeySignature`'s payload):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// tag 2: concertKey    i32, zig-zag varint — -7…+7, sharps positive
/// ```
///
/// `RemoveKeySignatureIntentWire` (`removeKeySignature`'s payload):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// ```
///
/// `SetTimeSignatureIntentWire` (`setTimeSignature`'s payload):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// tag 2: numerator     i32, zig-zag varint — 1…63
/// tag 3: denominator   i32, zig-zag varint — 1, 2, 4, 8, 16 or 32
/// ```
///
/// `RemoveTimeSignatureIntentWire` (`removeTimeSignature`'s payload):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// ```
///
/// `SetRehearsalMarkIntentWire` (`setRehearsalMark`'s payload):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// tag 2: text          string — UTF-8, trimmed engine-side, never empty after trimming
/// ```
///
/// `RemoveRehearsalMarkIntentWire` (`removeRehearsalMark`'s payload). Byte-identical to
/// `RemoveTimeSignatureIntentWire` and deliberately its own struct, for the reason that one is separate from
/// `RemoveKeySignatureIntentWire`: the removals address different things and are free to diverge.
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// ```
///
/// `CreateVoiceIntentWire` (`createVoice`'s payload):
/// ```
/// tag 1: staff         StaffAddressWire, see layout above
/// tag 2: measureIndex  i32, zig-zag varint
/// tag 3: voiceIndex    i32, zig-zag varint
/// ```
///
/// `SplitRestIntentWire` (`splitRest`'s payload):
/// ```
/// tag 1: location    VoiceElementIDWire, see layout above
/// tag 2: tickOffset  i32, zig-zag varint — ticks from the START of the rest, never 0 and never its length
/// ```
///
/// `SetNoteHeadIntentWire` (`setNoteHead`'s payload):
/// ```
/// tag 1: location  NoteIDWire, see PathIDCodecs.swift
/// tag 2: hasHead   u8, varint — 0 = clear the override, 1 = write `head`
/// tag 3: head      string — UTF-8; the encoder writes "" when hasHead == 0, so a byte-for-byte parity check
///                  between platforms should expect that empty string, not an absent tag
/// ```
///
/// `SetPartNamesIntentWire` (`setPartNames`'s payload). Two optional strings, each spelled as the `has` + value
/// pair `SetNoteHeadIntentWire` uses — a cleared name and an empty one are different things here, since an empty
/// abbreviation would still be a name the score declares:
/// ```
/// tag 1: partIndex     i32, zig-zag varint
/// tag 2: hasLongName   u8, varint — 0 = clear the long name, 1 = write `longName`
/// tag 3: longName      string — UTF-8; the encoder writes "" when hasLongName == 0
/// tag 4: hasShortName  u8, varint — 0 = clear the abbreviation, 1 = write `shortName`
/// tag 5: shortName     string — UTF-8; the encoder writes "" when hasShortName == 0
/// ```
///
/// `SetDrumsetEntryIntentWire` (`setDrumsetEntry`'s payload). The one intent payload that carries a whole model
/// value rather than scalars naming one — a `DrumsetEntry` IS scalars, five of them plus an optional string, so it
/// is spelled out field by field here rather than shipped as a nested type only this intent would use:
/// ```
/// tag 1: partIndex    i32, zig-zag varint
/// tag 2: pitch        i32, zig-zag varint — 35…81
/// tag 3: hasEntry     u8, varint — 0 = REMOVE this pitch's row, 1 = write the fields below
/// tag 4: name         string — UTF-8; "" when hasEntry == 0
/// tag 5: head         string — UTF-8; "" when hasEntry == 0
/// tag 6: line         i32, zig-zag varint — MuseScore's line number, negative above the staff
/// tag 7: voiceIndex   i32, zig-zag varint
/// tag 8: stem         i32, zig-zag varint — MuseScore's own encoding: 1 = up, 2 = down
/// tag 9: hasShortcut  u8, varint
/// tag 10: shortcut    string — UTF-8; "" when hasShortcut == 0
/// ```
///
/// `SetLayoutBreakIntentWire` (`setLayoutBreak`'s payload):
/// ```
/// tag 1: measure  MeasureRefWire, see ReferenceCodecs.swift
/// tag 2: kind     u8, varint — 1=line 2=page 3=section, else throws
/// tag 3: enabled  u8, varint — 0 / 1
/// ```
///
/// `SetBarLineIntentWire` (`setBarLine`'s payload):
/// ```
/// tag 1: measure  MeasureRefWire, see ReferenceCodecs.swift
/// tag 2: style    string — BarLineStyle raw value; unknown throws
/// ```
///
/// `SetRepeatBarLinesIntentWire` (`setRepeatBarLines`'s payload):
/// ```
/// tag 1: measure         MeasureRefWire, see ReferenceCodecs.swift
/// tag 2: startRepeat     u8, varint — 0 / 1
/// tag 3: hasEndRepeat    u8, varint — 0 = no end repeat, 1 = endRepeatCount holds it
/// tag 4: endRepeatCount  i32, zig-zag varint — 0 when hasEndRepeat == 0
/// ```
///
/// `SetMeasureRepeatIntentWire` (`setMeasureRepeat`'s payload):
/// ```
/// tag 1: measure      MeasureRefWire, see ReferenceCodecs.swift
/// tag 2: staff        StaffAddressWire, see StaffAddressCodec.swift
/// tag 3: hasCount     u8, varint — 0 = clear the group, 1 = numMeasures holds it
/// tag 4: numMeasures  i32, zig-zag varint — 0 when hasCount == 0
/// ```
///
/// `MoveToVoiceIntentWire` (`moveToVoice`'s payload):
/// ```
/// tag 1: location     VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: destination  VoiceRefWire, see ReferenceCodecs.swift
/// ```
///
/// `TransposeRangeIntentWire` (`transposeRange`'s payload):
/// ```
/// tag 1: range         VoiceElementRangeWire, see ReferenceCodecs.swift
/// tag 2: semitones     i32, zig-zag varint — −24…24
/// tag 3: respellInKey  u8, varint — 0 / 1
/// ```
///
/// `AddIntervalToSelectionIntentWire` (`addIntervalToSelection`'s payload):
/// ```
/// tag 1: range  VoiceElementRangeWire, see ReferenceCodecs.swift
/// tag 2: steps  i32, zig-zag varint — ±1…±9, the interval number
/// ```
///
/// `DeleteRangeIntentWire` (`deleteRange`'s payload):
/// ```
/// tag 1: range  VoiceElementRangeWire, see ReferenceCodecs.swift
/// ```
///
/// `SetAccidentalsInRangeIntentWire` (`setAccidentalsInRange`'s payload):
/// ```
/// tag 1: range       VoiceElementRangeWire, see ReferenceCodecs.swift
/// tag 2: accidental  AccidentalWire, see layout above
/// ```
///
/// `SetDurationInRangeIntentWire` (`setDurationInRange`'s payload):
/// ```
/// tag 1: range     VoiceElementRangeWire, see ReferenceCodecs.swift
/// tag 2: duration  NoteDurationWire, see layout above
/// ```
///
/// `RespellRangeIntentWire` (`respellRange`'s payload):
/// ```
/// tag 1: range  VoiceElementRangeWire, see ReferenceCodecs.swift
/// tag 2: mode   u8, varint — 0 simplest / 1 prefer sharps / 2 prefer flats, else throws
/// ```
///
/// `SetClefIntentWire` (`setClef`'s payload):
/// ```
/// tag 1: target    VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: clefType  string — `NotatedClef.rawType` ("G", "F", "C3", …); a spelling `NotatedClef` does not emit
///                  throws, rather than collapsing to treble the way `NotatedClef(rawType:)` would
/// ```
///
/// `RemoveClefIntentWire` (`removeClef`'s payload):
/// ```
/// tag 1: location  VoiceElementIDWire, see PathIDCodecs.swift
/// ```
///
/// `SetTempoIntentWire` (`setTempo`'s payload):
/// ```
/// tag 1: anchor          VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasTempo        u8, varint — 0 = remove the tempo at the beat, 1 = write `marking`
/// tag 3: beatsPerSecond  f64, fixed-64 little-endian IEEE 754 — 0 when hasTempo == 0
/// tag 4: beatNote        NoteDurationWire, see layout above — the encoder writes the `kind = 3` (quarter)
///                        placeholder when hasTempo == 0, so a byte-for-byte parity check should expect it
/// tag 5: beatDots        i32, zig-zag varint — 0 when hasTempo == 0
/// ```
///
/// `SetStaffTextIntentWire` (`setStaffText`'s payload):
/// ```
/// tag 1: anchor        VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasText       u8, varint — 0 = remove the text at the beat, 1 = write `text`
/// tag 3: text          string — "" when hasText == 0
/// tag 4: isSystemText  u8, varint — 0 staff text / 1 system text
/// ```
///
/// `SetDynamicIntentWire` (`setDynamic`'s payload):
/// ```
/// tag 1: location    VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasDynamic  u8, varint — 0 = remove, 1 = write `subtype`
/// tag 3: subtype     string — the MSCX token ("pp", "mf", "sfz", …); "" when hasDynamic == 0
/// ```
///
/// `SetFermataIntentWire` (`setFermata`'s payload):
/// ```
/// tag 1: location     VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasFermata   u8, varint — 0 = remove, 1 = write
/// tag 3: subtype      string — the SMuFL name ("fermataAbove", …); "" when hasFermata == 0
/// tag 4: timeStretch  f64, fixed-64 little-endian IEEE 754 — 0 when hasFermata == 0
/// ```
///
/// `SetBreathIntentWire` (`setBreath`'s payload):
/// ```
/// tag 1: location   VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasBreath  u8, varint — 0 = remove, 1 = write
/// tag 3: kind       u8, varint — 0 breath mark / 1 caesura, else throws
/// tag 4: style      u8, varint — breath mark: 0 comma 1 tick 2 upbow 3 salzedo;
///                   caesura: 0 normal 1 short 2 thick 3 curved; else throws
/// tag 5: pause      f64, fixed-64 little-endian IEEE 754 — 0 when hasBreath == 0
/// ```
///
/// `JumpWire` (one element of `SetJumpsIntentWire.jumps`):
/// ```
/// tag 1: jumpTo       string — MuseScore's own token ("start", "segno", …), uninterpreted here
/// tag 2: playUntil    string
/// tag 3: continueAt   string
/// tag 4: playRepeats  u8, varint
/// tag 5: text         string
/// ```
///
/// `MarkerWire` (one element of `SetMarkersIntentWire.markers`):
/// ```
/// tag 1: kind   string — `Marker.Kind.rawValue`; an unknown kind throws
/// tag 2: label  string
/// tag 3: text   string
/// ```
///
/// `SetJumpsIntentWire` (`setJumps`'s payload):
/// ```
/// tag 1: measure  MeasureRefWire, see ReferenceCodecs.swift
/// tag 2: jumps    [JumpWire] — length-delimited array, each element itself length-delimited; an empty list is
///                 the tag with a zero length
/// ```
///
/// `SetMarkersIntentWire` (`setMarkers`'s payload):
/// ```
/// tag 1: measure  MeasureRefWire, see ReferenceCodecs.swift
/// tag 2: markers  [MarkerWire] — the `SetJumpsIntentWire.jumps` framing
/// ```
///
/// `SetArticulationIntentWire` (`setArticulation`'s payload):
/// ```
/// tag 1: location   VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: kind       string — `ChordArticulation.Kind.mscxToken`; an UNKNOWN token decodes to
///                   `.unknown(subtype:)` rather than throwing, the deliberate exception to the raw-string rule
/// tag 3: hasAnchor  u8, varint — 0 = no anchor written, 1 = `anchor` names one
/// tag 4: anchor     u8, varint — 0 above / 1 below, else throws; 0 when hasAnchor == 0
/// tag 5: present    u8, varint — 1 = write the mark, 0 = take every entry of that kind off
/// ```
///
/// `GraceNoteWire` (one element of `GraceChordWire.notes`):
/// ```
/// tag 1: pitch       i32, zig-zag varint
/// tag 2: tpc         i32, zig-zag varint
/// tag 3: accidental  AccidentalWire — present flag + raw string
/// ```
///
/// `GraceChordWire` (one element of `SetGraceNotesIntentWire.before` / `.after`):
/// ```
/// tag 1: graceType  string — `GraceType.mscxTag`; an unknown tag throws
/// tag 2: duration   NoteDurationWire
/// tag 3: notes      [GraceNoteWire] — the `SetJumpsIntentWire.jumps` framing, nested one level deeper; an empty
///                   inner list is the tag with a zero length
/// ```
///
/// `SetGraceNotesIntentWire` (`setGraceNotes`'s payload):
/// ```
/// tag 1: location  VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: before    [GraceChordWire]
/// tag 3: after     [GraceChordWire]
/// ```
///
/// `SetTremoloIntentWire` (`setTremolo`'s payload):
/// ```
/// tag 1: location     VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasTremolo   u8, varint — 0 = remove, 1 = write
/// tag 3: subtype      u8, varint — `Tremolo.Subtype.rawValue`: 1 r8, 2 r16, 3 r32, 4 r64; else throws
/// tag 4: span         u8, varint — 0 single / 1 between, else throws
/// tag 5: strokeStyle  u8, varint — 0 default, 1 traditional, 2 z; else throws
/// ```
///
/// `SetArpeggioIntentWire` (`setArpeggio`'s payload):
/// ```
/// tag 1: location     VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasArpeggio  u8, varint — 0 = remove, 1 = write
/// tag 3: subtype      i32, zig-zag varint — 0…5, MuseScore's whole ARPEGGIO_TYPES table; else throws
/// ```
///
/// `SetGlissandoIntentWire` (`setGlissando`'s payload):
/// ```
/// tag 1: location      NoteIDWire, see PathIDCodecs.swift
/// tag 2: hasGlissando  u8, varint — 0 = remove, 1 = write
/// tag 3: style         u8, varint — 0 chromatic, 1 diatonic, 2 whiteKeys, 3 blackKeys, 4 portamento; else throws
/// tag 4: visualType    u8, varint — 0 straight / 1 wavy, else throws
/// tag 5: easeIn        i32, zig-zag varint
/// tag 6: easeOut       i32, zig-zag varint
/// tag 7: hasText       u8, varint — an ABSENT text is not an empty one, so both shapes survive
/// tag 8: text          string — "" when hasText == 0
/// ```
///
/// `SetDotsIntentWire` (`setDots`'s payload):
/// ```
/// tag 1: location  VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: dots      i32, zig-zag varint — 0…3, else throws
/// ```
///
/// `SetChordLineIntentWire` (`setChordLine`'s payload):
/// ```
/// tag 1: location    VoiceElementIDWire, see PathIDCodecs.swift
/// tag 2: hasLine     u8, varint — 0 = clear the chord's lines, 1 = write one
/// tag 3: kind        u8, varint — `ChordLine.Kind.rawValue`: 1 fall, 2 doit, 3 plop, 4 scoop; else throws
/// tag 4: isStraight  u8, varint
/// ```
///
/// `SetNoteParenthesesIntentWire` (`setNoteParentheses`'s payload):
/// ```
/// tag 1: location     NoteIDWire, see PathIDCodecs.swift
/// tag 2: parentheses  u8, varint — 0 none, 1 left, 2 right, 3 both; else throws
/// ```
public enum EditIntentCodec {
    public static func encode(_ intent: EditIntent) -> Data {
        EditIntentWire(from: intent).encodeToData()
    }

    public static func decode(_ data: Data) throws -> EditIntent {
        try EditIntentWire(decoding: data).decoded()
    }
}

/// Real composites bundle at most two atomic edits (a range op wrapping two sub-commands). Anything nesting deeper
/// than this is either a bug on the writing side or a malformed payload, and refusing it is far cheaper than
/// discovering the hard way — via a stack overflow — that `CompositeIntentWire.members` has no built-in bound.
///
/// Applied twice, on purpose: `NestedEditIntentWire` stops the *parse* before it recurses, and
/// `CompositeIntentWire.decoded(depth:)` stops the model conversion afterwards. Only the first of those can
/// prevent the overflow; see `NestedEditIntentWire` for what happened when only the second existed.
private let maxCompositeIntentDepth = 8

/// `NoteDuration` as a discriminator plus an optional fraction. `.fraction` is the only case with a payload, so the
/// two numerator/denominator fields are zero for every other case.
@WireFormat
public struct NoteDurationWire {
    public var kind: UInt8
    public var numerator: Int32
    public var denominator: Int32

    public init(from value: NoteDuration) {
        switch value {
        case .whole:
            kind = 1
            numerator = 0
            denominator = 0
        case .half:
            kind = 2
            numerator = 0
            denominator = 0
        case .quarter:
            kind = 3
            numerator = 0
            denominator = 0
        case .eighth:
            kind = 4
            numerator = 0
            denominator = 0
        case .sixteenth:
            kind = 5
            numerator = 0
            denominator = 0
        case .thirtySecond:
            kind = 6
            numerator = 0
            denominator = 0
        case .sixtyFourth:
            kind = 7
            numerator = 0
            denominator = 0
        case .oneTwentyEighth:
            kind = 8
            numerator = 0
            denominator = 0
        case .twoFiftySixth:
            kind = 9
            numerator = 0
            denominator = 0
        case .measure:
            kind = 10
            numerator = 0
            denominator = 0
        case let .fraction(f):
            kind = 11
            numerator = Int32(f.numerator)
            denominator = Int32(f.denominator)
        }
    }

    /// Throws `WireFormatError.unknownChoiceDiscriminator` for a `kind` outside `1...11` — a duration that a
    /// newer writer understands and an older reader does not must not silently decode as some other duration.
    ///
    /// Also throws that same error for a non-positive `denominator` on a `kind == 11` payload. `Fraction.init`
    /// enforces `denominator > 0` with a `precondition` — a trap, not a throw — so a malformed wire payload with
    /// `denominator == 0` would otherwise kill the process on a path this codec's own tests advertise as returning
    /// `false`, not crashing.
    public func decoded() throws -> NoteDuration {
        switch kind {
        case 1: return .whole
        case 2: return .half
        case 3: return .quarter
        case 4: return .eighth
        case 5: return .sixteenth
        case 6: return .thirtySecond
        case 7: return .sixtyFourth
        case 8: return .oneTwentyEighth
        case 9: return .twoFiftySixth
        case 10: return .measure
        case 11:
            guard denominator > 0 else {
                throw WireFormatError.unknownChoiceDiscriminator(UInt32(bitPattern: denominator))
            }
            return .fraction(Fraction(numerator: Int(numerator), denominator: Int(denominator)))
        default: throw WireFormatError.unknownChoiceDiscriminator(UInt32(kind))
        }
    }
}

@WireFormatChoice
public enum EditIntentWire {
    case inputNote(InputNoteIntentWire)
    case setRestDuration(SlotDurationIntentWire)
    case setChordDuration(SlotDurationIntentWire)
    case delete(VoiceElementIDWire)
    case composite(CompositeIntentWire)
    // Appended in SP1 — indices 5…11. Never renumber 0…4.
    case setNotePitch(PitchWriteIntentWire)
    case setAccidental(SetAccidentalIntentWire)
    case addNoteToChord(AddNoteIntentWire)
    case removeNoteFromChord(NoteIDWire)
    case setTie(SetTieIntentWire)
    case createTuplet(CreateTupletIntentWire)
    case removeTuplet(VoiceElementIDWire)
    /// Appended in SP2 — index 12. Never renumber anything above it.
    case writeNote(WriteNoteIntentWire)
    /// Appended in SP2 — index 13. Shares `SlotDurationIntentWire` with `setRestDuration` / `setChordDuration`:
    /// the payload really is the same two scalars, and the discriminator is what tells the three apart.
    case writeRest(SlotDurationIntentWire)
    /// Appended for M1 solo scratch creation — index 14. Never renumber anything above it.
    case insertMeasure(MeasureIndexIntentWire)
    /// Appended for M1 solo scratch creation — index 15. Shares `MeasureIndexIntentWire` with `insertMeasure`: the
    /// payload really is the same one scalar, and the discriminator is what tells the two apart.
    case deleteMeasure(MeasureIndexIntentWire)
    /// Appended for M2 ensemble creation — index 16. Never renumber anything above it.
    case addPart(AddPartIntentWire)
    /// Appended for M2 ensemble creation — index 17.
    case removePart(PartIndexIntentWire)
    /// Appended for M2 ensemble creation — index 18.
    case movePart(MovePartIntentWire)
    /// Appended for M3 signature changes — index 19. Never renumber anything above it.
    case setKeySignature(SetKeySignatureIntentWire)
    /// Appended for M3 signature changes — index 20.
    case removeKeySignature(RemoveKeySignatureIntentWire)
    /// Appended for M3 signature changes — index 21.
    case setTimeSignature(SetTimeSignatureIntentWire)
    /// Appended for M3 signature changes — index 22.
    case removeTimeSignature(RemoveTimeSignatureIntentWire)
    /// Appended for M4 rehearsal marks — index 23. Never renumber anything above it.
    case setRehearsalMark(SetRehearsalMarkIntentWire)
    /// Appended for M4 rehearsal marks — index 24.
    case removeRehearsalMark(RemoveRehearsalMarkIntentWire)
    /// Appended for M6 drum note entry — index 25. Never renumber anything above it.
    case createVoice(CreateVoiceIntentWire)
    /// Appended for M6 drum note entry — index 26.
    case splitRest(SplitRestIntentWire)
    /// Appended for M6 drum note entry — index 27.
    case setNoteHead(SetNoteHeadIntentWire)
    /// Appended for M6 drum note entry — index 28.
    case setDrumsetEntry(SetDrumsetEntryIntentWire)
    /// Appended for part renaming — index 29. Never renumber anything above it.
    case setPartNames(SetPartNamesIntentWire)
    /// Appended for the edit-command parity project's structural group (spec 2026-09-02) — index 30. Never
    /// renumber anything above it.
    case setLayoutBreak(SetLayoutBreakIntentWire)
    /// Appended for the edit-command parity project's structural group (spec 2026-09-02) — index 31. Never
    /// renumber anything above it.
    case setBarLine(SetBarLineIntentWire)
    /// Appended for the edit-command parity project's structural group (spec 2026-09-02) — index 32. Never
    /// renumber anything above it.
    case setRepeatBarLines(SetRepeatBarLinesIntentWire)
    /// Appended for the edit-command parity project's structural group (spec 2026-09-02) — index 33. Never
    /// renumber anything above it.
    case setMeasureRepeat(SetMeasureRepeatIntentWire)
    /// Appended for the edit-command parity project's structural group (spec 2026-09-02) — index 34. Never
    /// renumber anything above it.
    case moveToVoice(MoveToVoiceIntentWire)
    /// Appended for the edit-command parity project's range group (spec 2026-09-02) — index 35. Never renumber
    /// anything above it.
    case transposeRange(TransposeRangeIntentWire)
    /// Appended for the edit-command parity project's range group (spec 2026-09-02) — index 36. Never renumber
    /// anything above it.
    case addIntervalToSelection(AddIntervalToSelectionIntentWire)
    /// Appended for the edit-command parity project's range group (spec 2026-09-02) — index 37. Never renumber
    /// anything above it.
    case deleteRange(DeleteRangeIntentWire)
    /// Appended for the edit-command parity project's range group (spec 2026-09-02) — index 38. Never renumber
    /// anything above it.
    case setAccidentalsInRange(SetAccidentalsInRangeIntentWire)
    /// Appended for the edit-command parity project's range group (spec 2026-09-02) — index 39. Never renumber
    /// anything above it.
    case setDurationInRange(SetDurationInRangeIntentWire)
    /// Appended for the edit-command parity project's range group (spec 2026-09-02) — index 40. Never renumber
    /// anything above it.
    case respellRange(RespellRangeIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 41. Never renumber
    /// anything above it.
    case setClef(SetClefIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 42. Never renumber
    /// anything above it.
    case removeClef(RemoveClefIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 43. Never renumber
    /// anything above it.
    case setTempo(SetTempoIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 44. Never renumber
    /// anything above it.
    case setStaffText(SetStaffTextIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 45. Never renumber
    /// anything above it.
    case setDynamic(SetDynamicIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 46. Never renumber
    /// anything above it.
    case setFermata(SetFermataIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 47. Never renumber
    /// anything above it.
    case setBreath(SetBreathIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 48. Never renumber
    /// anything above it.
    case setJumps(SetJumpsIntentWire)
    /// Appended for the edit-command parity project's mark group (spec 2026-09-02) — index 49. Never renumber
    /// anything above it.
    case setMarkers(SetMarkersIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 50. Never
    /// renumber anything above it.
    case setArticulation(SetArticulationIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 51. Never
    /// renumber anything above it.
    case setGraceNotes(SetGraceNotesIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 52. Never
    /// renumber anything above it.
    case setTremolo(SetTremoloIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 53. Never
    /// renumber anything above it.
    case setArpeggio(SetArpeggioIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 54. Never
    /// renumber anything above it.
    case setGlissando(SetGlissandoIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 55. Never
    /// renumber anything above it.
    case setDots(SetDotsIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 56. Never
    /// renumber anything above it.
    case setChordLine(SetChordLineIntentWire)
    /// Appended for the edit-command parity project's note / chord group (spec 2026-09-02) — index 57. Never
    /// renumber anything above it.
    case setNoteParentheses(SetNoteParenthesesIntentWire)

    /// One `switch` over every intent, past the length rule and for the same reason `decoded(depth:)` states: the
    /// compiler's insistence that every case be encoded here is the only thing standing between an appended
    /// intent and a payload that never reaches the far side.
    public init(from intent: EditIntent) { // swiftlint:disable:this function_body_length
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            self = .inputNote(InputNoteIntentWire(location: location, pitch: pitch, tpc: tpc, duration: duration))
        case let .setRestDuration(location, duration):
            self = .setRestDuration(SlotDurationIntentWire(location: location, duration: duration))
        case let .setChordDuration(location, duration):
            self = .setChordDuration(SlotDurationIntentWire(location: location, duration: duration))
        case let .delete(location):
            self = .delete(VoiceElementIDWire(from: location))
        case let .composite(intents):
            self = .composite(CompositeIntentWire(from: intents))
        case let .setNotePitch(location, pitch, tpc, accidental):
            self = .setNotePitch(
                PitchWriteIntentWire(location: location, pitch: pitch, tpc: tpc, accidental: accidental),
            )
        case let .setAccidental(location, accidental):
            self = .setAccidental(SetAccidentalIntentWire(location: location, accidental: accidental))
        case let .addNoteToChord(location, pitch, tpc, accidental):
            self = .addNoteToChord(
                AddNoteIntentWire(location: location, pitch: pitch, tpc: tpc, accidental: accidental),
            )
        case let .removeNoteFromChord(location):
            self = .removeNoteFromChord(NoteIDWire(from: location))
        case let .setTie(source, target, sourceTieForward, targetTieBack):
            self = .setTie(
                SetTieIntentWire(
                    source: source, target: target,
                    sourceTieForward: sourceTieForward, targetTieBack: targetTieBack,
                ),
            )
        case let .createTuplet(location, actualNotes, normalNotes):
            self = .createTuplet(
                CreateTupletIntentWire(location: location, actualNotes: actualNotes, normalNotes: normalNotes),
            )
        case let .removeTuplet(location):
            self = .removeTuplet(VoiceElementIDWire(from: location))
        case let .writeNote(location, pitch, tpc, duration):
            self = .writeNote(WriteNoteIntentWire(location: location, pitch: pitch, tpc: tpc, duration: duration))
        case let .writeRest(location, duration):
            self = .writeRest(SlotDurationIntentWire(location: location, duration: duration))
        case let .insertMeasure(index):
            self = .insertMeasure(MeasureIndexIntentWire(measureIndex: index))
        case let .deleteMeasure(index):
            self = .deleteMeasure(MeasureIndexIntentWire(measureIndex: index))
        case let .addPart(plan, index):
            self = .addPart(AddPartIntentWire(plan: plan, partIndex: index))
        case let .removePart(index):
            self = .removePart(PartIndexIntentWire(partIndex: index))
        case let .movePart(from, to):
            self = .movePart(MovePartIntentWire(fromIndex: from, toIndex: to))
        case let .setKeySignature(measureIndex, concertKey):
            self = .setKeySignature(
                SetKeySignatureIntentWire(measureIndex: measureIndex, concertKey: concertKey),
            )
        case let .removeKeySignature(measureIndex):
            self = .removeKeySignature(RemoveKeySignatureIntentWire(measureIndex: measureIndex))
        case let .setTimeSignature(measureIndex, numerator, denominator):
            self = .setTimeSignature(SetTimeSignatureIntentWire(
                measureIndex: measureIndex, numerator: numerator, denominator: denominator,
            ))
        case let .removeTimeSignature(measureIndex):
            self = .removeTimeSignature(RemoveTimeSignatureIntentWire(measureIndex: measureIndex))
        case let .setRehearsalMark(measureIndex, text):
            self = .setRehearsalMark(SetRehearsalMarkIntentWire(measureIndex: measureIndex, text: text))
        case let .removeRehearsalMark(measureIndex):
            self = .removeRehearsalMark(RemoveRehearsalMarkIntentWire(measureIndex: measureIndex))
        case let .createVoice(staff, measureIndex, voiceIndex):
            self = .createVoice(CreateVoiceIntentWire(
                staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex,
            ))
        case let .splitRest(location, tickOffset):
            self = .splitRest(SplitRestIntentWire(location: location, tickOffset: tickOffset))
        case let .setNoteHead(location, headType):
            self = .setNoteHead(SetNoteHeadIntentWire(location: location, headType: headType))
        case let .setDrumsetEntry(partIndex, pitch, entry):
            self = .setDrumsetEntry(SetDrumsetEntryIntentWire(
                partIndex: partIndex, pitch: pitch, entry: entry,
            ))
        case let .setPartNames(partIndex, longName, shortName):
            self = .setPartNames(SetPartNamesIntentWire(
                partIndex: partIndex, longName: longName, shortName: shortName,
            ))
        case let .setLayoutBreak(measure, kind, enabled):
            self = .setLayoutBreak(SetLayoutBreakIntentWire(measure: measure, kind: kind, enabled: enabled))
        case let .setBarLine(measure, style):
            self = .setBarLine(SetBarLineIntentWire(measure: measure, style: style))
        case let .setRepeatBarLines(measure, startRepeat, endRepeatCount):
            self = .setRepeatBarLines(SetRepeatBarLinesIntentWire(
                measure: measure, startRepeat: startRepeat, endRepeatCount: endRepeatCount,
            ))
        case let .setMeasureRepeat(measure, staff, numMeasures):
            self = .setMeasureRepeat(SetMeasureRepeatIntentWire(
                measure: measure, staff: staff, numMeasures: numMeasures,
            ))
        case let .moveToVoice(location, destination):
            self = .moveToVoice(MoveToVoiceIntentWire(location: location, destination: destination))
        case let .transposeRange(range, semitones, respellInKey):
            self = .transposeRange(TransposeRangeIntentWire(
                range: range, semitones: semitones, respellInKey: respellInKey,
            ))
        case let .addIntervalToSelection(range, steps):
            self = .addIntervalToSelection(AddIntervalToSelectionIntentWire(range: range, steps: steps))
        case let .deleteRange(range):
            self = .deleteRange(DeleteRangeIntentWire(range: range))
        case let .setAccidentalsInRange(range, accidental):
            self = .setAccidentalsInRange(SetAccidentalsInRangeIntentWire(range: range, accidental: accidental))
        case let .setDurationInRange(range, duration):
            self = .setDurationInRange(SetDurationInRangeIntentWire(range: range, duration: duration))
        case let .respellRange(range, mode):
            self = .respellRange(RespellRangeIntentWire(range: range, mode: mode))
        case let .setClef(target, clef):
            self = .setClef(SetClefIntentWire(target: target, clef: clef))
        case let .removeClef(location):
            self = .removeClef(RemoveClefIntentWire(location: location))
        case let .setTempo(anchor, marking):
            self = .setTempo(SetTempoIntentWire(anchor: anchor, marking: marking))
        case let .setStaffText(anchor, text, isSystemText):
            self = .setStaffText(SetStaffTextIntentWire(anchor: anchor, text: text, isSystemText: isSystemText))
        case let .setDynamic(location, subtype):
            self = .setDynamic(SetDynamicIntentWire(location: location, subtype: subtype))
        case let .setFermata(location, subtype, timeStretch):
            self = .setFermata(SetFermataIntentWire(location: location, subtype: subtype, timeStretch: timeStretch))
        case let .setBreath(location, kind, pause):
            self = .setBreath(SetBreathIntentWire(location: location, kind: kind, pause: pause))
        case let .setJumps(measure, jumps):
            self = .setJumps(SetJumpsIntentWire(measure: measure, jumps: jumps))
        case let .setMarkers(measure, markers):
            self = .setMarkers(SetMarkersIntentWire(measure: measure, markers: markers))
        case let .setArticulation(location, kind, anchor, present):
            self = .setArticulation(SetArticulationIntentWire(
                location: location, kind: kind, anchor: anchor, present: present,
            ))
        case let .setGraceNotes(location, before, after):
            self = .setGraceNotes(SetGraceNotesIntentWire(location: location, before: before, after: after))
        case let .setTremolo(location, tremolo):
            self = .setTremolo(SetTremoloIntentWire(location: location, tremolo: tremolo))
        case let .setArpeggio(location, subtype):
            self = .setArpeggio(SetArpeggioIntentWire(location: location, subtype: subtype))
        case let .setGlissando(location, glissando):
            self = .setGlissando(SetGlissandoIntentWire(location: location, glissando: glissando))
        case let .setDots(location, dots):
            self = .setDots(SetDotsIntentWire(location: location, dots: dots))
        case let .setChordLine(location, kind, isStraight):
            self = .setChordLine(SetChordLineIntentWire(location: location, kind: kind, isStraight: isStraight))
        case let .setNoteParentheses(location, parentheses):
            self = .setNoteParentheses(
                SetNoteParenthesesIntentWire(location: location, parentheses: parentheses),
            )
        }
    }

    /// `depth` counts how many `composite` levels enclose this node — 0 at the top of a decode. Only the
    /// `.composite` branch advances it; every other case is a leaf and ignores it. See `CompositeIntentWire.decoded`
    /// for the bound this enforces.
    ///
    /// One `switch` over every discriminator on purpose, past the length rule: splitting it would need a `default`
    /// or a second exhaustive switch, and the compiler's insistence that every wire case be decoded here is the
    /// only thing standing between an appended case and a payload that decodes as silence.
    public func decoded(depth: Int = 0) throws -> EditIntent { // swiftlint:disable:this function_body_length
        switch self {
        case let .inputNote(wire):
            let decoded = try wire.decoded()
            return .inputNote(at: decoded.at, pitch: decoded.pitch, tpc: decoded.tpc, duration: decoded.duration)
        case let .setRestDuration(wire):
            let decoded = try wire.decoded()
            return .setRestDuration(at: decoded.at, duration: decoded.duration)
        case let .setChordDuration(wire):
            let decoded = try wire.decoded()
            return .setChordDuration(at: decoded.at, duration: decoded.duration)
        case let .delete(wire):
            return .delete(at: wire.decoded())
        case let .composite(wire):
            return try .composite(wire.decoded(depth: depth))
        case let .setNotePitch(wire):
            let decoded = try wire.decoded()
            return .setNotePitch(
                at: decoded.location, pitch: decoded.pitch, tpc: decoded.tpc, accidental: decoded.accidental,
            )
        case let .setAccidental(wire):
            let decoded = try wire.decoded()
            return .setAccidental(at: decoded.location, accidental: decoded.accidental)
        case let .addNoteToChord(wire):
            let decoded = try wire.decoded()
            return .addNoteToChord(
                at: decoded.location, pitch: decoded.pitch, tpc: decoded.tpc, accidental: decoded.accidental,
            )
        case let .removeNoteFromChord(wire):
            return .removeNoteFromChord(at: wire.decoded())
        case let .setTie(wire):
            let decoded = wire.decoded()
            return .setTie(
                from: decoded.source, to: decoded.target,
                sourceTieForward: decoded.sourceTieForward, targetTieBack: decoded.targetTieBack,
            )
        case let .createTuplet(wire):
            let decoded = wire.decoded()
            return .createTuplet(
                at: decoded.location, actualNotes: decoded.actualNotes, normalNotes: decoded.normalNotes,
            )
        case let .removeTuplet(wire):
            return .removeTuplet(at: wire.decoded())
        case let .writeNote(wire):
            let decoded = try wire.decoded()
            return .writeNote(at: decoded.at, pitch: decoded.pitch, tpc: decoded.tpc, duration: decoded.duration)
        case let .writeRest(wire):
            let decoded = try wire.decoded()
            return .writeRest(at: decoded.at, duration: decoded.duration)
        case let .insertMeasure(wire):
            return .insertMeasure(at: wire.decoded())
        case let .deleteMeasure(wire):
            return .deleteMeasure(at: wire.decoded())
        case let .addPart(wire):
            let decoded = wire.decoded()
            return .addPart(plan: decoded.plan, at: decoded.partIndex)
        case let .removePart(wire):
            return .removePart(at: wire.decoded())
        case let .movePart(wire):
            let decoded = wire.decoded()
            return .movePart(from: decoded.fromIndex, to: decoded.toIndex)
        case let .setKeySignature(wire):
            let decoded = wire.decoded()
            return .setKeySignature(measureIndex: decoded.measureIndex, concertKey: decoded.concertKey)
        case let .removeKeySignature(wire):
            return .removeKeySignature(measureIndex: wire.decoded())
        case let .setTimeSignature(wire):
            let decoded = wire.decoded()
            return .setTimeSignature(
                measureIndex: decoded.measureIndex,
                numerator: decoded.numerator, denominator: decoded.denominator,
            )
        case let .removeTimeSignature(wire):
            return .removeTimeSignature(measureIndex: wire.decoded())
        case let .setRehearsalMark(wire):
            let decoded = wire.decoded()
            return .setRehearsalMark(measureIndex: decoded.measureIndex, text: decoded.text)
        case let .removeRehearsalMark(wire):
            return .removeRehearsalMark(measureIndex: wire.decoded())
        case let .createVoice(wire):
            let decoded = wire.decoded()
            return .createVoice(
                staff: decoded.staff, measureIndex: decoded.measureIndex, voiceIndex: decoded.voiceIndex,
            )
        case let .splitRest(wire):
            let decoded = wire.decoded()
            return .splitRest(at: decoded.location, tickOffset: decoded.tickOffset)
        case let .setNoteHead(wire):
            let decoded = wire.decoded()
            return .setNoteHead(at: decoded.location, headType: decoded.headType)
        case let .setDrumsetEntry(wire):
            let decoded = wire.decoded()
            return .setDrumsetEntry(
                partIndex: decoded.partIndex, pitch: decoded.pitch, entry: decoded.entry,
            )
        case let .setPartNames(wire):
            let decoded = wire.decoded()
            return .setPartNames(
                at: decoded.partIndex, longName: decoded.longName, shortName: decoded.shortName,
            )
        case let .setLayoutBreak(wire):
            let decoded = try wire.decoded()
            return .setLayoutBreak(at: decoded.measure, kind: decoded.kind, enabled: decoded.enabled)
        case let .setBarLine(wire):
            let decoded = try wire.decoded()
            return .setBarLine(at: decoded.measure, style: decoded.style)
        case let .setRepeatBarLines(wire):
            let decoded = wire.decoded()
            return .setRepeatBarLines(
                at: decoded.measure, startRepeat: decoded.startRepeat, endRepeatCount: decoded.endRepeatCount,
            )
        case let .setMeasureRepeat(wire):
            let decoded = wire.decoded()
            return .setMeasureRepeat(at: decoded.measure, staff: decoded.staff, numMeasures: decoded.numMeasures)
        case let .moveToVoice(wire):
            let decoded = wire.decoded()
            return .moveToVoice(at: decoded.location, to: decoded.destination)
        case let .transposeRange(wire):
            let decoded = wire.decoded()
            return .transposeRange(
                over: decoded.range, semitones: decoded.semitones, respellInKey: decoded.respellInKey,
            )
        case let .addIntervalToSelection(wire):
            let decoded = wire.decoded()
            return .addIntervalToSelection(over: decoded.range, steps: decoded.steps)
        case let .deleteRange(wire):
            return .deleteRange(over: wire.decoded())
        case let .setAccidentalsInRange(wire):
            let decoded = try wire.decoded()
            return .setAccidentalsInRange(over: decoded.range, accidental: decoded.accidental)
        case let .setDurationInRange(wire):
            let decoded = try wire.decoded()
            return .setDurationInRange(over: decoded.range, duration: decoded.duration)
        case let .respellRange(wire):
            let decoded = try wire.decoded()
            return .respellRange(over: decoded.range, mode: decoded.mode)
        case let .setClef(wire):
            let decoded = try wire.decoded()
            return .setClef(before: decoded.target, clef: decoded.clef)
        case let .removeClef(wire):
            return .removeClef(at: wire.decoded())
        case let .setTempo(wire):
            let decoded = try wire.decoded()
            return .setTempo(anchor: decoded.anchor, marking: decoded.marking)
        case let .setStaffText(wire):
            let decoded = wire.decoded()
            return .setStaffText(anchor: decoded.anchor, text: decoded.text, isSystemText: decoded.isSystemText)
        case let .setDynamic(wire):
            let decoded = wire.decoded()
            return .setDynamic(at: decoded.location, subtype: decoded.subtype)
        case let .setFermata(wire):
            let decoded = wire.decoded()
            return .setFermata(at: decoded.location, subtype: decoded.subtype, timeStretch: decoded.timeStretch)
        case let .setBreath(wire):
            let decoded = try wire.decoded()
            return .setBreath(after: decoded.location, kind: decoded.kind, pause: decoded.pause)
        case let .setJumps(wire):
            let decoded = wire.decoded()
            return .setJumps(at: decoded.measure, jumps: decoded.jumps)
        case let .setMarkers(wire):
            let decoded = try wire.decoded()
            return .setMarkers(at: decoded.measure, markers: decoded.markers)
        case let .setArticulation(wire):
            let decoded = try wire.decoded()
            return .setArticulation(
                at: decoded.location, kind: decoded.kind, anchor: decoded.anchor, present: decoded.present,
            )
        case let .setGraceNotes(wire):
            let decoded = try wire.decoded()
            return .setGraceNotes(at: decoded.location, before: decoded.before, after: decoded.after)
        case let .setTremolo(wire):
            let decoded = try wire.decoded()
            return .setTremolo(at: decoded.location, tremolo: decoded.tremolo)
        case let .setArpeggio(wire):
            let decoded = try wire.decoded()
            return .setArpeggio(at: decoded.location, subtype: decoded.subtype)
        case let .setGlissando(wire):
            let decoded = try wire.decoded()
            return .setGlissando(at: decoded.location, glissando: decoded.glissando)
        case let .setDots(wire):
            let decoded = try wire.decoded()
            return .setDots(at: decoded.location, dots: decoded.dots)
        case let .setChordLine(wire):
            let decoded = try wire.decoded()
            return .setChordLine(at: decoded.location, kind: decoded.kind, isStraight: decoded.isStraight)
        case let .setNoteParentheses(wire):
            let decoded = try wire.decoded()
            return .setNoteParentheses(at: decoded.location, parentheses: decoded.parentheses)
        }
    }
}

@WireFormat
public struct InputNoteIntentWire {
    public var location: RestIDWire
    public var pitch: Int32
    public var tpc: Int32
    /// 0 = keep the slot's length, 1 = retime it to `duration`.
    public var hasDuration: UInt8
    public var duration: NoteDurationWire

    public init(location: RestID, pitch: Int, tpc: Int, duration: NoteDuration?) {
        self.location = RestIDWire(from: location)
        self.pitch = Int32(pitch)
        self.tpc = Int32(tpc)
        if let duration {
            hasDuration = 1
            self.duration = NoteDurationWire(from: duration)
        } else {
            hasDuration = 0
            self.duration = NoteDurationWire(from: .whole)
        }
    }

    public func decoded() throws -> (at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?) {
        try (
            at: location.decoded(),
            pitch: Int(pitch),
            tpc: Int(tpc),
            duration: hasDuration != 0 ? duration.decoded() : nil,
        )
    }
}

/// `.writeNote`'s payload — `InputNoteIntentWire` with a `VoiceElementIDWire` location.
///
/// A separate struct rather than a shared one with a "which kind of ID" flag: the two IDs have different field
/// counts, and a flag would make the decoder's answer depend on a byte that could disagree with the discriminator.
/// The duplication is five stored properties; the ambiguity would be a silent misdecode.
@WireFormat
public struct WriteNoteIntentWire {
    public var location: VoiceElementIDWire
    public var pitch: Int32
    public var tpc: Int32
    /// 0 = keep the slot's length, 1 = retime it to `duration`.
    public var hasDuration: UInt8
    public var duration: NoteDurationWire

    public init(location: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?) {
        self.location = VoiceElementIDWire(from: location)
        self.pitch = Int32(pitch)
        self.tpc = Int32(tpc)
        if let duration {
            hasDuration = 1
            self.duration = NoteDurationWire(from: duration)
        } else {
            hasDuration = 0
            self.duration = NoteDurationWire(from: .whole)
        }
    }

    public func decoded() throws -> (at: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?) {
        try (
            at: location.decoded(),
            pitch: Int(pitch),
            tpc: Int(tpc),
            duration: hasDuration != 0 ? duration.decoded() : nil,
        )
    }
}

@WireFormat
public struct SlotDurationIntentWire {
    public var location: VoiceElementIDWire
    public var duration: NoteDurationWire

    public init(location: VoiceElementID, duration: NoteDuration) {
        self.location = VoiceElementIDWire(from: location)
        self.duration = NoteDurationWire(from: duration)
    }

    public func decoded() throws -> (at: VoiceElementID, duration: NoteDuration) {
        try (at: location.decoded(), duration: duration.decoded())
    }
}

/// One member of a `CompositeIntentWire`: an `EditIntentWire` whose *parse* is bounded by
/// `maxCompositeIntentDepth`.
///
/// The bound has to live here, not on `decoded(depth:)`. `EditIntentCodec.decode` is
/// `EditIntentWire(decoding:).decoded()` — the whole tree is built from bytes first, and that build
/// (`EditIntentWire` ⇄ `CompositeIntentWire` ⇄ its member array) is mutually recursive with no limit of its own,
/// so `decoded(depth:)`'s guard could only ever fire on a tree that already exists. A payload nesting deeper than
/// the stack allows never reached it.
///
/// On WebAssembly that was not a clean crash. The shadow stack is 128 KiB (wasm-ld's default; the Swift wasm SDK
/// sets none), one nesting level of this parse costs 8-10 KiB, and wasm-ld's default layout places `.bss` directly
/// below the stack — so the overflow did not trap, it overwrote the allocator's own state, and the failure
/// surfaced later as an out-of-bounds trap inside an unrelated `malloc`. `try?` at the two bridge call sites
/// cannot catch that. 20 levels was enough; the browser bridge takes these bytes from JavaScript.
///
/// Every `WireFormat` requirement forwards to `EditIntentWire`, so the encoding is unchanged in both directions —
/// `Array`'s conformance calls `encode(into:)` per element and `Element(from:)` per element, and both are the
/// wrapped type's own. This type exists only to own the counter.
public struct NestedEditIntentWire: WireFormatEncodable, WireFormatDecodable {
    /// How many `composite` levels enclose the value currently being parsed. Task-local rather than a global so
    /// two concurrent decodes cannot see each other's count.
    @TaskLocal private static var parseDepth = 0

    public var wire: EditIntentWire

    public init(_ wire: EditIntentWire) {
        self.wire = wire
    }

    public static var wireType: WireType {
        EditIntentWire.wireType
    }

    public func encode(into writer: inout WireFormatWriter) {
        wire.encode(into: &writer)
    }

    public func encodePayload(into writer: inout WireFormatWriter) {
        wire.encodePayload(into: &writer)
    }

    public init(from reader: inout WireFormatReader) throws {
        wire = try Self.descending { try EditIntentWire(from: &reader) }
    }

    public init(decodingPayload reader: inout WireFormatReader) throws {
        wire = try Self.descending { try EditIntentWire(decodingPayload: &reader) }
    }

    /// Runs `parse` one level deeper, refusing before it recurses rather than after.
    private static func descending(_ parse: () throws -> EditIntentWire) throws -> EditIntentWire {
        let depth = parseDepth + 1
        guard depth <= maxCompositeIntentDepth else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(depth))
        }
        return try $parseDepth.withValue(depth, operation: parse)
    }
}

@WireFormat
public struct CompositeIntentWire {
    /// Held as `NestedEditIntentWire` rather than `EditIntentWire` so the parse itself is depth-bounded; the bytes
    /// are identical either way. See `NestedEditIntentWire` for why the bound cannot live in `decoded(depth:)`.
    public var members: [NestedEditIntentWire]

    public init(from intents: [EditIntent]) {
        members = intents.map { NestedEditIntentWire(EditIntentWire(from: $0)) }
    }

    /// Refuses to decode past `maxCompositeIntentDepth` levels of nesting. This is the model-side half of the
    /// limit `NestedEditIntentWire` already applied to the parse; it stays because it is what `EditIntent` — not
    /// the wire — promises, and it is the half `ScoreEditSession`'s planner mirrors. `depth` is this composite's
    /// own nesting level; each member is one level deeper.
    public func decoded(depth: Int) throws -> [EditIntent] {
        guard depth < maxCompositeIntentDepth else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(depth))
        }
        return try members.map { try $0.wire.decoded(depth: depth + 1) }
    }
}

/// `Accidental` as its raw-value string. Variable length, and deliberately not an index: `Accidental`'s cases are
/// declared in a source order this codec does not control, so an index would silently re-point the day someone
/// inserts a case. A spelling the reader does not know throws rather than decoding as "no accidental" — a silent
/// nil would put a different glyph on the mirror than the authoritative score carries.
@WireFormat
public struct AccidentalWire {
    /// 0 = no accidental (`nil`), 1 = `raw` names one.
    public var present: UInt8
    public var raw: String

    public init(from value: Accidental?) {
        if let value {
            present = 1
            raw = value.rawValue
        } else {
            present = 0
            raw = ""
        }
    }

    public func decoded() throws -> Accidental? {
        guard present != 0 else { return nil }
        guard let accidental = Accidental(rawValue: raw) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return accidental
    }
}

/// A signed tie index, or its absence. `Int?` has no wire form of its own here, and `-1` is not safe as a sentinel
/// because `SetTie` treats the value as opaque.
@WireFormat
public struct OptionalIndexWire {
    public var present: UInt8
    public var value: Int32

    public init(from value: Int?) {
        if let value {
            present = 1
            self.value = Int32(value)
        } else {
            present = 0
            self.value = 0
        }
    }

    public func decoded() -> Int? {
        present != 0 ? Int(value) : nil
    }
}

@WireFormat
public struct PitchWriteIntentWire {
    public var location: NoteIDWire
    public var pitch: Int32
    public var tpc: Int32
    public var accidental: AccidentalWire

    public init(location: NoteID, pitch: Int, tpc: Int, accidental: Accidental?) {
        self.location = NoteIDWire(from: location)
        self.pitch = Int32(pitch)
        self.tpc = Int32(tpc)
        self.accidental = AccidentalWire(from: accidental)
    }

    public func decoded() throws -> (location: NoteID, pitch: Int, tpc: Int, accidental: Accidental?) {
        try (
            location: location.decoded(),
            pitch: Int(pitch),
            tpc: Int(tpc),
            accidental: accidental.decoded(),
        )
    }
}

@WireFormat
public struct AddNoteIntentWire {
    public var location: VoiceElementIDWire
    public var pitch: Int32
    public var tpc: Int32
    public var accidental: AccidentalWire

    public init(location: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?) {
        self.location = VoiceElementIDWire(from: location)
        self.pitch = Int32(pitch)
        self.tpc = Int32(tpc)
        self.accidental = AccidentalWire(from: accidental)
    }

    public func decoded() throws -> (location: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?) {
        try (
            location: location.decoded(),
            pitch: Int(pitch),
            tpc: Int(tpc),
            accidental: accidental.decoded(),
        )
    }
}

@WireFormat
public struct SetAccidentalIntentWire {
    public var location: NoteIDWire
    public var accidental: AccidentalWire

    public init(location: NoteID, accidental: Accidental?) {
        self.location = NoteIDWire(from: location)
        self.accidental = AccidentalWire(from: accidental)
    }

    public func decoded() throws -> (location: NoteID, accidental: Accidental?) {
        try (location: location.decoded(), accidental: accidental.decoded())
    }
}

@WireFormat
public struct SetTieIntentWire {
    public var source: NoteIDWire
    public var target: NoteIDWire
    public var sourceTieForward: OptionalIndexWire
    public var targetTieBack: OptionalIndexWire

    public init(source: NoteID, target: NoteID, sourceTieForward: Int?, targetTieBack: Int?) {
        self.source = NoteIDWire(from: source)
        self.target = NoteIDWire(from: target)
        self.sourceTieForward = OptionalIndexWire(from: sourceTieForward)
        self.targetTieBack = OptionalIndexWire(from: targetTieBack)
    }

    public func decoded() -> (source: NoteID, target: NoteID, sourceTieForward: Int?, targetTieBack: Int?) {
        (
            source: source.decoded(),
            target: target.decoded(),
            sourceTieForward: sourceTieForward.decoded(),
            targetTieBack: targetTieBack.decoded(),
        )
    }
}

@WireFormat
public struct CreateTupletIntentWire {
    public var location: VoiceElementIDWire
    public var actualNotes: Int32
    public var normalNotes: Int32

    public init(location: VoiceElementID, actualNotes: Int, normalNotes: Int) {
        self.location = VoiceElementIDWire(from: location)
        self.actualNotes = Int32(actualNotes)
        self.normalNotes = Int32(normalNotes)
    }

    public func decoded() -> (location: VoiceElementID, actualNotes: Int, normalNotes: Int) {
        (location: location.decoded(), actualNotes: Int(actualNotes), normalNotes: Int(normalNotes))
    }
}

/// Shared by `insertMeasure` and `deleteMeasure` — the discriminator case index is what tells the two apart, not
/// anything in this struct.
@WireFormat
public struct MeasureIndexIntentWire {
    public var measureIndex: Int32

    public init(measureIndex: Int) {
        self.measureIndex = Int32(measureIndex)
    }

    public func decoded() -> Int {
        Int(measureIndex)
    }
}

/// One staff of a `BlankScoreTemplate.PartPlan`.
@WireFormat
public struct StaffPlanWire {
    /// The MuseScore clef token stored into `Staff.defaultClefType` ("G", "F", "G8vb", "C3", "PERC", …).
    public var clefType: String
    /// 0 / 1 — a drum / unpitched staff.
    public var isPercussion: UInt8

    public init(from plan: BlankScoreTemplate.StaffPlan) {
        clefType = plan.clefType
        isPercussion = plan.isPercussion ? 1 : 0
    }

    public func decoded() -> BlankScoreTemplate.StaffPlan {
        BlankScoreTemplate.StaffPlan(clefType: clefType, isPercussion: isPercussion != 0)
    }
}

/// `BlankScoreTemplate.PartPlan` — the instrument identity and staff list a new part is built from.
///
/// Deliberately not scalars-only like the rest of this file's payloads: a plan is the *recipe* for a part, not a
/// slice of the score, so both images build the same `Part` from it and the built part never travels. The two
/// optional names use `AccidentalWire`'s present-flag pattern rather than `Optional` stored properties, keeping
/// every field in this file mandatory.
@WireFormat
public struct PartPlanWire {
    public var instrumentID: String
    /// 0 = `longName` is nil, 1 = it holds one.
    public var hasLongName: UInt8
    public var longName: String
    /// 0 = `shortName` is nil, 1 = it holds one.
    public var hasShortName: UInt8
    public var shortName: String
    public var staves: [StaffPlanWire]
    public var transposeDiatonic: Int32
    public var transposeChromatic: Int32
    public var gmProgram: Int32
    /// 0 / 1 — a drum kit.
    public var isDrums: UInt8

    public init(from plan: BlankScoreTemplate.PartPlan) {
        instrumentID = plan.instrumentID
        hasLongName = plan.longName == nil ? 0 : 1
        longName = plan.longName ?? ""
        hasShortName = plan.shortName == nil ? 0 : 1
        shortName = plan.shortName ?? ""
        staves = plan.staves.map(StaffPlanWire.init(from:))
        transposeDiatonic = Int32(plan.transposeDiatonic)
        transposeChromatic = Int32(plan.transposeChromatic)
        gmProgram = Int32(plan.gmProgram)
        isDrums = plan.isDrums ? 1 : 0
    }

    public func decoded() -> BlankScoreTemplate.PartPlan {
        BlankScoreTemplate.PartPlan(
            instrumentID: instrumentID,
            longName: hasLongName != 0 ? longName : nil,
            shortName: hasShortName != 0 ? shortName : nil,
            staves: staves.map { $0.decoded() },
            transposeDiatonic: Int(transposeDiatonic),
            transposeChromatic: Int(transposeChromatic),
            gmProgram: Int(gmProgram),
            isDrums: isDrums != 0,
        )
    }
}

/// `addPart`'s payload.
@WireFormat
public struct AddPartIntentWire {
    public var plan: PartPlanWire
    public var partIndex: Int32

    public init(plan: BlankScoreTemplate.PartPlan, partIndex: Int) {
        self.plan = PartPlanWire(from: plan)
        self.partIndex = Int32(partIndex)
    }

    public func decoded() -> (plan: BlankScoreTemplate.PartPlan, partIndex: Int) {
        (plan: plan.decoded(), partIndex: Int(partIndex))
    }
}

/// `removePart`'s payload. Byte-identical to `MeasureIndexIntentWire`, and deliberately not shared with it: the two
/// index different things, and a codec whose field names lie about what they address is a decode away from a bug
/// nothing catches.
@WireFormat
public struct PartIndexIntentWire {
    public var partIndex: Int32

    public init(partIndex: Int) {
        self.partIndex = Int32(partIndex)
    }

    public func decoded() -> Int {
        Int(partIndex)
    }
}

/// `movePart`'s payload.
@WireFormat
public struct MovePartIntentWire {
    public var fromIndex: Int32
    public var toIndex: Int32

    public init(fromIndex: Int, toIndex: Int) {
        self.fromIndex = Int32(fromIndex)
        self.toIndex = Int32(toIndex)
    }

    public func decoded() -> (fromIndex: Int, toIndex: Int) {
        (fromIndex: Int(fromIndex), toIndex: Int(toIndex))
    }
}

/// `setKeySignature`'s payload — which bar declares the key, and which key it declares.
@WireFormat
public struct SetKeySignatureIntentWire {
    public var measureIndex: Int32
    /// `KeySignature.concertKey`: -7 (C♭) … +7 (C♯), sharps positive. Zig-zag varint, so the flat keys cost the
    /// same one byte the sharp ones do.
    public var concertKey: Int32

    public init(measureIndex: Int, concertKey: Int) {
        self.measureIndex = Int32(measureIndex)
        self.concertKey = Int32(concertKey)
    }

    public func decoded() -> (measureIndex: Int, concertKey: Int) {
        (measureIndex: Int(measureIndex), concertKey: Int(concertKey))
    }
}

/// `removeKeySignature`'s payload. Byte-identical to `MeasureIndexIntentWire` and deliberately its own struct: the
/// three measure-index intents that share that one are all structural (insert / delete a whole column), while this
/// one addresses what a bar *declares*, and the two families are free to diverge — a courtesy or a scope flag would
/// land here and nowhere near `insertMeasure`.
@WireFormat
public struct RemoveKeySignatureIntentWire {
    public var measureIndex: Int32

    public init(measureIndex: Int) {
        self.measureIndex = Int32(measureIndex)
    }

    public func decoded() -> Int {
        Int(measureIndex)
    }
}

/// `setTimeSignature`'s payload — which bar declares the meter, and which meter it declares.
///
/// The two halves travel as separate fields rather than as one packed number: a host picks them independently,
/// and the range each is valid over (`1…63` over `1, 2, 4, 8, 16, 32`) is stated by `SetTimeSignature.apply`,
/// which both images reach from these same scalars.
@WireFormat
public struct SetTimeSignatureIntentWire {
    public var measureIndex: Int32
    public var numerator: Int32
    public var denominator: Int32

    public init(measureIndex: Int, numerator: Int, denominator: Int) {
        self.measureIndex = Int32(measureIndex)
        self.numerator = Int32(numerator)
        self.denominator = Int32(denominator)
    }

    public func decoded() -> (measureIndex: Int, numerator: Int, denominator: Int) {
        (measureIndex: Int(measureIndex), numerator: Int(numerator), denominator: Int(denominator))
    }
}

/// `removeTimeSignature`'s payload. Byte-identical to `RemoveKeySignatureIntentWire` and deliberately its own
/// struct, for the reason that one is separate from `MeasureIndexIntentWire`: the two removals address different
/// declarations and are free to diverge.
@WireFormat
public struct RemoveTimeSignatureIntentWire {
    public var measureIndex: Int32

    public init(measureIndex: Int) {
        self.measureIndex = Int32(measureIndex)
    }

    public func decoded() -> Int {
        Int(measureIndex)
    }
}

/// `setRehearsalMark`'s payload — which bar carries the mark, and what it reads.
///
/// `text` is the only string an edit intent has ever carried besides `PartPlanWire`'s names, and it is free-form on
/// purpose: a mark is "A", "1サビ", "Coda" — whatever the composer wrote. The engine trims it and refuses an empty
/// result, so no length or character rule is stated here.
@WireFormat
public struct SetRehearsalMarkIntentWire {
    public var measureIndex: Int32
    public var text: String

    public init(measureIndex: Int, text: String) {
        self.measureIndex = Int32(measureIndex)
        self.text = text
    }

    public func decoded() -> (measureIndex: Int, text: String) {
        (measureIndex: Int(measureIndex), text: text)
    }
}

/// `removeRehearsalMark`'s payload. Byte-identical to `RemoveTimeSignatureIntentWire` and deliberately its own
/// struct, for the reason that one is separate from `RemoveKeySignatureIntentWire`: the removals address different
/// things and are free to diverge.
@WireFormat
public struct RemoveRehearsalMarkIntentWire {
    public var measureIndex: Int32

    public init(measureIndex: Int) {
        self.measureIndex = Int32(measureIndex)
    }

    public func decoded() -> Int {
        Int(measureIndex)
    }
}

/// `createVoice`'s payload — which measure of which staff grows a voice, and which index it takes.
@WireFormat
public struct CreateVoiceIntentWire {
    public var staff: StaffAddressWire
    public var measureIndex: Int32
    public var voiceIndex: Int32

    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        self.staff = StaffAddressWire(from: staff)
        self.measureIndex = Int32(measureIndex)
        self.voiceIndex = Int32(voiceIndex)
    }

    public func decoded() -> (staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        (staff: staff.decoded(), measureIndex: Int(measureIndex), voiceIndex: Int(voiceIndex))
    }
}

/// `splitRest`'s payload — the rest, and how far into it the new slot boundary falls.
@WireFormat
public struct SplitRestIntentWire {
    public var location: VoiceElementIDWire
    public var tickOffset: Int32

    public init(location: VoiceElementID, tickOffset: Int) {
        self.location = VoiceElementIDWire(from: location)
        self.tickOffset = Int32(tickOffset)
    }

    public func decoded() -> (location: VoiceElementID, tickOffset: Int) {
        (location: location.decoded(), tickOffset: Int(tickOffset))
    }
}

/// `setNoteHead`'s payload — the note, and the notehead override to write onto it.
///
/// The head is spelled as a presence flag plus a string rather than as an `Optional<String>` for the reason
/// `InputNoteIntentWire` spells its optional duration that way: the macro emits `unknownTag` for any missing
/// non-optional field, and "clear the override" has to be distinguishable from "write an empty head".
@WireFormat
public struct SetNoteHeadIntentWire {
    public var location: NoteIDWire
    public var hasHead: UInt8
    public var head: String

    public init(location: NoteID, headType: String?) {
        self.location = NoteIDWire(from: location)
        hasHead = headType == nil ? 0 : 1
        head = headType ?? ""
    }

    public func decoded() -> (location: NoteID, headType: String?) {
        (location: location.decoded(), headType: hasHead == 0 ? nil : head)
    }
}

/// `setPartNames`'s payload — which part, and the two names to write onto it.
///
/// Each name is a `has` flag plus a string rather than an absent tag, so "clear this name" and "set it to the
/// empty string" stay distinguishable across the wire. `SetNoteHeadIntentWire` spells its one optional the same
/// way, and for the same reason.
@WireFormat
public struct SetPartNamesIntentWire {
    public var partIndex: Int32
    public var hasLongName: UInt8
    public var longName: String
    public var hasShortName: UInt8
    public var shortName: String

    public init(partIndex: Int, longName: String?, shortName: String?) {
        self.partIndex = Int32(partIndex)
        hasLongName = longName == nil ? 0 : 1
        self.longName = longName ?? ""
        hasShortName = shortName == nil ? 0 : 1
        self.shortName = shortName ?? ""
    }

    public func decoded() -> (partIndex: Int, longName: String?, shortName: String?) {
        (
            partIndex: Int(partIndex),
            longName: hasLongName == 0 ? nil : longName,
            shortName: hasShortName == 0 ? nil : shortName,
        )
    }
}

/// `setDrumsetEntry`'s payload — which part's kit, which pitch, and the row to write there.
///
/// `DrumsetEntry`'s fields are inlined rather than nested: they are five scalars and an optional string, and a
/// nested wire struct only this intent would ever use buys nothing but a second length prefix.
@WireFormat
public struct SetDrumsetEntryIntentWire {
    public var partIndex: Int32
    public var pitch: Int32
    public var hasEntry: UInt8
    public var name: String
    public var head: String
    public var line: Int32
    public var voiceIndex: Int32
    public var stem: Int32
    public var hasShortcut: UInt8
    public var shortcut: String

    public init(partIndex: Int, pitch: Int, entry: DrumsetEntry?) {
        self.partIndex = Int32(partIndex)
        self.pitch = Int32(pitch)
        hasEntry = entry == nil ? 0 : 1
        name = entry?.name ?? ""
        head = entry?.head ?? ""
        line = Int32(entry?.line ?? 0)
        voiceIndex = Int32(entry?.voiceIndex ?? 0)
        stem = Int32(entry?.stem ?? 1)
        hasShortcut = entry?.shortcut == nil ? 0 : 1
        shortcut = entry?.shortcut ?? ""
    }

    public func decoded() -> (partIndex: Int, pitch: Int, entry: DrumsetEntry?) {
        guard hasEntry != 0 else {
            return (partIndex: Int(partIndex), pitch: Int(pitch), entry: nil)
        }
        return (
            partIndex: Int(partIndex),
            pitch: Int(pitch),
            entry: DrumsetEntry(
                name: name,
                head: head,
                line: Int(line),
                voiceIndex: Int(voiceIndex),
                stem: Int(stem),
                shortcut: hasShortcut == 0 ? nil : shortcut,
            ),
        )
    }
}
