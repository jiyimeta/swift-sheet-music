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
/// associatedValue.encode()`. Case indices, matching `EditIntent`'s declaration order exactly:
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
/// ```
///
/// Cases 5…11 were appended in SP1, 12…13 in SP2, 14…15 for M1 solo scratch creation, 16…18 for M2 ensemble
/// creation and 19…20 for M3 signature changes; 0…4 predate them all and must keep their indices and byte layout.
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

    public init(from intent: EditIntent) {
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

@WireFormat
public struct CompositeIntentWire {
    public var members: [EditIntentWire]

    public init(from intents: [EditIntent]) {
        members = intents.map(EditIntentWire.init(from:))
    }

    /// Refuses to decode past `maxCompositeIntentDepth` levels of nesting rather than recursing arbitrarily deep —
    /// a malformed payload with thousands of nested `composite` members would otherwise overflow the stack instead
    /// of failing cleanly. `depth` is this composite's own nesting level; each member is one level deeper.
    public func decoded(depth: Int) throws -> [EditIntent] {
        guard depth < maxCompositeIntentDepth else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(depth))
        }
        return try members.map { try $0.decoded(depth: depth + 1) }
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
