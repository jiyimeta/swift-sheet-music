import Foundation
import SheetMusicCore
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
/// Wirelet's TLV scheme (`Sources/Wirelet/WireFormat.swift` in `swift-wirelet`) is protobuf-style: every field is a
/// `tag` varint (`fieldNumber << 3 | wireType`) followed by its payload; signed integers are zig-zag varints;
/// nested structs, arrays, and choice enums are length-delimited (`varint(byteCount)` + that many payload bytes),
/// so they are self-delimiting and **not** fixed-width — every byte count below varies with the actual field
/// values, unlike the fixed-width tables in `ScoreItemIDCodec.swift` / `PathIDCodecs.swift` (those predate the
/// current varint/TLV macro expansion and no longer match the bytes those macros emit; verified against this
/// package's own golden fixtures under `Tests/SheetMusicTests/Resources/Golden/Audio/`). Field tags are assigned
/// 1, 2, 3, … in declaration order; case indices for a `@WireFormatChoice` enum are 0, 1, 2, … in declaration
/// order.
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
/// ```
///
/// `InputNoteIntentWire` fields, in tag order:
/// ```
/// tag 1: location     RestIDWire (see PathIDCodecs.swift)
/// tag 2: pitch        i32, zig-zag varint
/// tag 3: tpc          i32, zig-zag varint
/// tag 4: hasDuration  u8, varint — 0 = keep the slot's length, 1 = retime it to `duration`
/// tag 5: duration     NoteDurationWire — present but ignored by the decoder when hasDuration == 0
/// ```
///
/// `SlotDurationIntentWire` fields (shared by `setRestDuration` and `setChordDuration` — the discriminator case
/// index is what tells the two apart, not anything in this struct):
/// ```
/// tag 1: location  VoiceElementIDWire (see PathIDCodecs.swift)
/// tag 2: duration  NoteDurationWire
/// ```
///
/// `delete` reuses `VoiceElementIDWire` directly as its payload — no wrapper struct.
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
public enum EditIntentCodec {
    public static func encode(_ intent: EditIntent) -> Data {
        EditIntentWire(from: intent).encodeToData()
    }

    public static func decode(_ data: Data) throws -> EditIntent {
        try EditIntentWire(decoding: data).decoded()
    }
}

/// `NoteDuration` as a discriminator plus an optional fraction. `.fraction` is the only case with a payload, so the
/// two numerator/denominator fields are zero for every other case.
@WireFormat
struct NoteDurationWire {
    var kind: UInt8
    var numerator: Int32
    var denominator: Int32

    init(from value: NoteDuration) {
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
    func decoded() throws -> NoteDuration {
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
        case 11: return .fraction(Fraction(numerator: Int(numerator), denominator: Int(denominator)))
        default: throw WireFormatError.unknownChoiceDiscriminator(UInt32(kind))
        }
    }
}

@WireFormatChoice
enum EditIntentWire {
    case inputNote(InputNoteIntentWire)
    case setRestDuration(SlotDurationIntentWire)
    case setChordDuration(SlotDurationIntentWire)
    case delete(VoiceElementIDWire)
    case composite(CompositeIntentWire)

    init(from intent: EditIntent) {
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
        }
    }

    func decoded() throws -> EditIntent {
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
            return try .composite(wire.decoded())
        }
    }
}

@WireFormat
struct InputNoteIntentWire {
    var location: RestIDWire
    var pitch: Int32
    var tpc: Int32
    /// 0 = keep the slot's length, 1 = retime it to `duration`.
    var hasDuration: UInt8
    var duration: NoteDurationWire

    init(location: RestID, pitch: Int, tpc: Int, duration: NoteDuration?) {
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

    func decoded() throws -> (at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?) {
        try (
            at: location.decoded(),
            pitch: Int(pitch),
            tpc: Int(tpc),
            duration: hasDuration != 0 ? duration.decoded() : nil,
        )
    }
}

@WireFormat
struct SlotDurationIntentWire {
    var location: VoiceElementIDWire
    var duration: NoteDurationWire

    init(location: VoiceElementID, duration: NoteDuration) {
        self.location = VoiceElementIDWire(from: location)
        self.duration = NoteDurationWire(from: duration)
    }

    func decoded() throws -> (at: VoiceElementID, duration: NoteDuration) {
        try (at: location.decoded(), duration: duration.decoded())
    }
}

@WireFormat
struct CompositeIntentWire {
    var members: [EditIntentWire]

    init(from intents: [EditIntent]) {
        members = intents.map(EditIntentWire.init(from:))
    }

    func decoded() throws -> [EditIntent] {
        try members.map { try $0.decoded() }
    }
}
