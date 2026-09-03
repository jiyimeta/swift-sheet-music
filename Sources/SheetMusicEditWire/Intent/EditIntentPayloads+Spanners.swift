import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 62…67 (edit-command parity, group 6). Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory, optionals as `has` + value pairs, enums this codec does not own as raw strings, small
// closed enums as `u8` with a throwing table, every score location a nested reference mirror. `SetVoltaIntentWire`
// carries the codec's first SCALAR array: Wirelet writes `[Int32]` as one length-delimited field whose body is a
// run of zig-zag varints (`Conformances+Collections.swift:9-45`), self-delimiting and byte-stable.

@WireFormat
public struct SetSlurIntentWire {
    public var range: VoiceElementRangeWire

    public init(range: VoiceElementRange) {
        self.range = VoiceElementRangeWire(from: range)
    }

    public func decoded() -> VoiceElementRange {
        range.decoded()
    }
}

/// `Spanner.HairpinPayload.Subtype` as a hand-written `u8` table — the `NoteDurationWire` rule for a small closed
/// enum whose case order this codec must not depend on, even though it happens to have an `Int` raw value.
@WireFormat
public struct SetHairpinIntentWire {
    public var range: VoiceElementRangeWire
    /// 0 = crescendo, 1 = decrescendo, 2 = crescLine, 3 = dimLine.
    public var subtype: UInt8

    public init(range: VoiceElementRange, subtype: Spanner.HairpinPayload.Subtype) {
        self.range = VoiceElementRangeWire(from: range)
        self.subtype = switch subtype {
        case .crescendo: 0
        case .decrescendo: 1
        case .crescLine: 2
        case .dimLine: 3
        }
    }

    public func decoded() throws -> (range: VoiceElementRange, subtype: Spanner.HairpinPayload.Subtype) {
        let decodedSubtype: Spanner.HairpinPayload.Subtype = switch subtype {
        case 0: .crescendo
        case 1: .decrescendo
        case 2: .crescLine
        case 3: .dimLine
        default: throw WireFormatError.unknownChoiceDiscriminator(UInt32(subtype))
        }
        return (range: range.decoded(), subtype: decodedSubtype)
    }
}

@WireFormat
public struct SetPedalIntentWire {
    public var range: VoiceElementRangeWire

    public init(range: VoiceElementRange) {
        self.range = VoiceElementRangeWire(from: range)
    }

    public func decoded() -> VoiceElementRange {
        range.decoded()
    }
}

@WireFormat
public struct SetVoltaIntentWire {
    public var range: VoiceElementRangeWire
    public var endings: [Int32]
    public var hasText: UInt8
    public var text: String

    public init(range: VoiceElementRange, endings: [Int], text: String?) {
        self.range = VoiceElementRangeWire(from: range)
        self.endings = endings.map(Int32.init)
        hasText = text == nil ? 0 : 1
        self.text = text ?? ""
    }

    public func decoded() -> (range: VoiceElementRange, endings: [Int], text: String?) {
        (range: range.decoded(), endings: endings.map(Int.init), text: hasText == 0 ? nil : text)
    }
}

/// The ottava subtype is the one raw-string enum here that does NOT throw on an unlisted spelling:
/// `OttavaPayload.Subtype` has `case other(String)` and a non-failable `init(rawValue:)` (`Spanner.swift:186-205`),
/// so an unknown subtype is a value the model holds and a file carries, not a decode failure. Throwing would
/// refuse bytes this package itself produces.
@WireFormat
public struct SetOttavaIntentWire {
    public var range: VoiceElementRangeWire
    public var subtype: String

    public init(range: VoiceElementRange, subtype: Spanner.OttavaPayload.Subtype) {
        self.range = VoiceElementRangeWire(from: range)
        self.subtype = subtype.rawValue
    }

    public func decoded() -> (range: VoiceElementRange, subtype: Spanner.OttavaPayload.Subtype) {
        (range: range.decoded(), subtype: Spanner.OttavaPayload.Subtype(rawValue: subtype))
    }
}

@WireFormat
public struct SetTextLineIntentWire {
    public var range: VoiceElementRangeWire
    public var hasText: UInt8
    public var text: String

    public init(range: VoiceElementRange, text: String?) {
        self.range = VoiceElementRangeWire(from: range)
        hasText = text == nil ? 0 : 1
        self.text = text ?? ""
    }

    public func decoded() -> (range: VoiceElementRange, text: String?) {
        (range: range.decoded(), text: hasText == 0 ? nil : text)
    }
}
