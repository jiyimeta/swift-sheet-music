import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 50…53 (edit-command parity, group 4) and the two list element mirrors
// `SetGraceNotesIntentWire` carries. Tag layouts live in `EditIntentCodec.swift`'s file comment beside the older
// payloads; the rules there apply unchanged — every field mandatory, optionals as `has` + value pairs, enums this
// codec does not own as raw strings, small closed enums as `u8` with a hand-written throwing table.
//
// `SetGraceNotesIntentWire` is the codec's first NESTED list of structs: a `[GraceChordWire]` each element of
// which holds a `[GraceNoteWire]`. Wirelet frames both the same way it frames `SetJumpsIntentWire.jumps`
// (length-delimited array, each element itself length-delimited), so the nesting needs no new machinery — but it
// does need the empty-inner-list case pinned, which `EditIntentCodecNotationTests` does.

@WireFormat
public struct SetArticulationIntentWire {
    public var location: VoiceElementIDWire
    public var kind: String
    public var hasAnchor: UInt8
    public var anchor: UInt8
    public var present: UInt8

    public init(
        location: VoiceElementID, kind: ChordArticulation.Kind, anchor: ChordArticulation.Anchor?, present: Bool,
    ) {
        self.location = VoiceElementIDWire(from: location)
        self.kind = kind.mscxToken
        hasAnchor = anchor == nil ? 0 : 1
        self.anchor = anchor == .below ? 1 : 0
        self.present = present ? 1 : 0
    }

    /// A token the Core table does not know becomes `.unknown(subtype:)` rather than throwing — spec row 50 says
    /// so, and it is what lets a host toggle a mark it round-tripped out of a file this package does not model.
    /// That is the deliberate exception to the `AccidentalWire` rule: the string IS the value here.
    public func decoded() throws -> (
        location: VoiceElementID, kind: ChordArticulation.Kind, anchor: ChordArticulation.Anchor?, present: Bool,
    ) {
        guard anchor <= 1 else { throw WireFormatError.unknownChoiceDiscriminator(UInt32(anchor)) }
        return (
            location: location.decoded(),
            kind: ChordArticulation.Kind(mscxToken: kind) ?? .unknown(subtype: kind),
            anchor: hasAnchor == 0 ? nil : (anchor == 1 ? .below : .above),
            present: present != 0,
        )
    }
}

/// One note of a grace chord: what `AddNoteIntentWire` carries for an ordinary note, minus the location.
@WireFormat
public struct GraceNoteWire {
    public var pitch: Int32
    public var tpc: Int32
    public var accidental: AccidentalWire

    public init(from note: Note) {
        pitch = Int32(note.pitch)
        tpc = Int32(note.tpc)
        accidental = AccidentalWire(from: note.accidental)
    }

    public func decoded() throws -> Note {
        try Note(pitch: Int(pitch), tpc: Int(tpc), accidental: accidental.decoded())
    }
}

/// `GraceChord` with `graceType` as `GraceType.mscxTag` — a raw string, not an index, because that enum's case
/// order is not this codec's to control (the `AccidentalWire` rule). An unknown tag throws.
@WireFormat
public struct GraceChordWire {
    public var graceType: String
    public var duration: NoteDurationWire
    public var notes: [GraceNoteWire]

    public init(from grace: GraceChord) {
        graceType = grace.graceType.mscxTag
        duration = NoteDurationWire(from: grace.duration)
        notes = grace.notes.map(GraceNoteWire.init(from:))
    }

    public func decoded() throws -> GraceChord {
        guard let graceType = GraceType(mscxTag: graceType) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return try GraceChord(
            graceType: graceType, duration: duration.decoded(),
            notes: ChordNotes(notes.map { try $0.decoded() }),
        )
    }
}

@WireFormat
public struct SetGraceNotesIntentWire {
    public var location: VoiceElementIDWire
    public var before: [GraceChordWire]
    public var after: [GraceChordWire]

    public init(location: VoiceElementID, before: [GraceChord], after: [GraceChord]) {
        self.location = VoiceElementIDWire(from: location)
        self.before = before.map(GraceChordWire.init(from:))
        self.after = after.map(GraceChordWire.init(from:))
    }

    public func decoded() throws -> (location: VoiceElementID, before: [GraceChord], after: [GraceChord]) {
        try (
            location: location.decoded(),
            before: before.map { try $0.decoded() }, after: after.map { try $0.decoded() },
        )
    }
}

/// The `SetTremoloIntentWire` stroke table, in a type of its own so the payload struct carries stored INSTANCE
/// properties only — `@WireFormat` numbers those into tags, and a stored type property would be noise there.
private enum TremoloTables {
    /// `Tremolo.StrokeStyle`'s raw value is a STRING (`Tremolo.swift`), but spec §4.2 puts the stroke on the wire
    /// as a `u8`: it is a three-case enum this project owns outright, and a byte is what the Kotlin and wasm
    /// sides mirror most cheaply. Pinned by `EditIntentCodecNotationTests.everyTremoloShapeSurvives`.
    static let strokeStyles: [Tremolo.StrokeStyle] = [.default, .traditional, .z]
}

@WireFormat
public struct SetTremoloIntentWire {
    public var location: VoiceElementIDWire
    public var hasTremolo: UInt8
    public var subtype: UInt8
    public var span: UInt8
    public var strokeStyle: UInt8

    public init(location: VoiceElementID, tremolo: Tremolo?) {
        self.location = VoiceElementIDWire(from: location)
        hasTremolo = tremolo == nil ? 0 : 1
        subtype = tremolo?.subtype.rawValue ?? 1
        span = tremolo?.span == .between ? 1 : 0
        strokeStyle = TremoloTables.strokeStyles
            .firstIndex(of: tremolo?.strokeStyle ?? .default)
            .map { UInt8($0) } ?? 0
    }

    public func decoded() throws -> (location: VoiceElementID, tremolo: Tremolo?) {
        guard hasTremolo != 0 else { return (location: location.decoded(), tremolo: nil) }
        guard let bars = Tremolo.Subtype(rawValue: subtype) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(subtype))
        }
        guard span <= 1 else { throw WireFormatError.unknownChoiceDiscriminator(UInt32(span)) }
        guard TremoloTables.strokeStyles.indices.contains(Int(strokeStyle)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(strokeStyle))
        }
        return (
            location: location.decoded(),
            tremolo: Tremolo(
                subtype: bars, span: span == 1 ? .between : .single,
                strokeStyle: TremoloTables.strokeStyles[Int(strokeStyle)],
            ),
        )
    }
}

@WireFormat
public struct SetArpeggioIntentWire {
    public var location: VoiceElementIDWire
    public var hasArpeggio: UInt8
    public var subtype: Int32

    public init(location: VoiceElementID, subtype: Int?) {
        self.location = VoiceElementIDWire(from: location)
        hasArpeggio = subtype == nil ? 0 : 1
        self.subtype = Int32(subtype ?? 0)
    }

    /// `0…5` is MuseScore's whole `ARPEGGIO_TYPES` table (`types/typesconv.cpp`); the bound lives here rather
    /// than in `SetArpeggio` because a relayed payload is untrusted input while a locally built command carries a
    /// value its author already holds (see `SetArpeggio`'s doc comment).
    public func decoded() throws -> (location: VoiceElementID, subtype: Int?) {
        guard hasArpeggio != 0 else { return (location: location.decoded(), subtype: nil) }
        guard (0 ... 5).contains(subtype) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(bitPattern: subtype))
        }
        return (location: location.decoded(), subtype: Int(subtype))
    }
}
