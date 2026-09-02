import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 41…47 (edit-command parity, group 3). Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory, optionals as `has` + value pairs, enums this codec does not own as raw strings, small
// closed enums as `u8` with a throwing table. The `Double` fields are the codec's first floating-point payloads:
// Wirelet writes them as fixed 64-bit IEEE 754 bit patterns, so they are byte-stable and round-trip exactly.

@WireFormat
public struct SetClefIntentWire {
    public var target: VoiceElementIDWire
    public var clefType: String

    public init(target: VoiceElementID, clef: NotatedClef) {
        self.target = VoiceElementIDWire(from: target)
        clefType = clef.rawType
    }

    /// Only the spellings `NotatedClef.rawType` emits are accepted. `NotatedClef(rawType:)` would also take the
    /// legacy aliases and collapse anything else to treble — a silent misdecode, the very thing the
    /// `AccidentalWire` rule exists to prevent.
    public func decoded() throws -> (target: VoiceElementID, clef: NotatedClef) {
        guard let clef = NotatedClef.allCases.first(where: { $0.rawType == clefType }) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return (target: target.decoded(), clef: clef)
    }
}

@WireFormat
public struct RemoveClefIntentWire {
    public var location: VoiceElementIDWire

    public init(location: VoiceElementID) {
        self.location = VoiceElementIDWire(from: location)
    }

    public func decoded() -> VoiceElementID {
        location.decoded()
    }
}

@WireFormat
public struct SetTempoIntentWire {
    public var anchor: VoiceElementIDWire
    public var hasTempo: UInt8
    public var beatsPerSecond: Double
    public var beatNote: NoteDurationWire
    public var beatDots: Int32

    public init(anchor: VoiceElementID, marking: SetTempo.Marking?) {
        self.anchor = VoiceElementIDWire(from: anchor)
        hasTempo = marking == nil ? 0 : 1
        beatsPerSecond = marking?.beatsPerSecond ?? 0
        beatNote = NoteDurationWire(from: marking?.beatNote ?? .quarter)
        beatDots = Int32(marking?.beatDots ?? 0)
    }

    public func decoded() throws -> (anchor: VoiceElementID, marking: SetTempo.Marking?) {
        guard hasTempo != 0 else { return (anchor: anchor.decoded(), marking: nil) }
        return try (
            anchor: anchor.decoded(),
            marking: SetTempo.Marking(
                beatsPerSecond: beatsPerSecond, beatNote: beatNote.decoded(), beatDots: Int(beatDots),
            ),
        )
    }
}

@WireFormat
public struct SetStaffTextIntentWire {
    public var anchor: VoiceElementIDWire
    public var hasText: UInt8
    public var text: String
    public var isSystemText: UInt8

    public init(anchor: VoiceElementID, text: String?, isSystemText: Bool) {
        self.anchor = VoiceElementIDWire(from: anchor)
        hasText = text == nil ? 0 : 1
        self.text = text ?? ""
        self.isSystemText = isSystemText ? 1 : 0
    }

    public func decoded() -> (anchor: VoiceElementID, text: String?, isSystemText: Bool) {
        (anchor: anchor.decoded(), text: hasText == 0 ? nil : text, isSystemText: isSystemText != 0)
    }
}

@WireFormat
public struct SetDynamicIntentWire {
    public var location: VoiceElementIDWire
    public var hasDynamic: UInt8
    public var subtype: String

    public init(location: VoiceElementID, subtype: String?) {
        self.location = VoiceElementIDWire(from: location)
        hasDynamic = subtype == nil ? 0 : 1
        self.subtype = subtype ?? ""
    }

    public func decoded() -> (location: VoiceElementID, subtype: String?) {
        (location: location.decoded(), subtype: hasDynamic == 0 ? nil : subtype)
    }
}

@WireFormat
public struct SetFermataIntentWire {
    public var location: VoiceElementIDWire
    public var hasFermata: UInt8
    public var subtype: String
    public var timeStretch: Double

    public init(location: VoiceElementID, subtype: String?, timeStretch: Double) {
        self.location = VoiceElementIDWire(from: location)
        hasFermata = subtype == nil ? 0 : 1
        self.subtype = subtype ?? ""
        self.timeStretch = subtype == nil ? 0 : timeStretch
    }

    public func decoded() -> (location: VoiceElementID, subtype: String?, timeStretch: Double) {
        (location: location.decoded(), subtype: hasFermata == 0 ? nil : subtype, timeStretch: timeStretch)
    }
}

/// The `SetBreathIntentWire` tables, in a type of their own so the payload struct carries stored INSTANCE
/// properties only — `@WireFormat` numbers those into tags, and a stored type property would be noise there.
private enum BreathTables {
    static let breathStyles: [Breath.BreathMarkStyle] = [.comma, .tick, .upbow, .salzedo]
    static let caesuraStyles: [Breath.CaesuraStyle] = [.normal, .short, .thick, .curved]
}

/// `Breath.Kind` as two hand-written `u8` tables — the `NoteDurationWire` rule for a small closed enum whose
/// case order this codec must not depend on.
@WireFormat
public struct SetBreathIntentWire {
    public var location: VoiceElementIDWire
    public var hasBreath: UInt8
    /// 0 = breath mark, 1 = caesura.
    public var kind: UInt8
    /// Breath mark: 0 comma, 1 tick, 2 upbow, 3 salzedo. Caesura: 0 normal, 1 short, 2 thick, 3 curved.
    public var style: UInt8
    public var pause: Double

    public init(location: VoiceElementID, kind: Breath.Kind?, pause: Double) {
        self.location = VoiceElementIDWire(from: location)
        hasBreath = kind == nil ? 0 : 1
        switch kind {
        case let .breathMark(style)?:
            self.kind = 0
            self.style = BreathTables.breathStyles.firstIndex(of: style).map { UInt8($0) } ?? 0
        case let .caesura(style)?:
            self.kind = 1
            self.style = BreathTables.caesuraStyles.firstIndex(of: style).map { UInt8($0) } ?? 0
        case nil:
            self.kind = 0
            style = 0
        }
        self.pause = kind == nil ? 0 : pause
    }

    /// Throws `unknownChoiceDiscriminator` for a kind or style outside the tables.
    public func decoded() throws -> (location: VoiceElementID, kind: Breath.Kind?, pause: Double) {
        guard hasBreath != 0 else { return (location: location.decoded(), kind: nil, pause: pause) }
        let decodedKind: Breath.Kind
        switch kind {
        case 0:
            guard BreathTables.breathStyles.indices.contains(Int(style)) else {
                throw WireFormatError.unknownChoiceDiscriminator(UInt32(style))
            }
            decodedKind = .breathMark(BreathTables.breathStyles[Int(style)])
        case 1:
            guard BreathTables.caesuraStyles.indices.contains(Int(style)) else {
                throw WireFormatError.unknownChoiceDiscriminator(UInt32(style))
            }
            decodedKind = .caesura(BreathTables.caesuraStyles[Int(style)])
        default:
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(kind))
        }
        return (location: location.decoded(), kind: decodedKind, pause: pause)
    }
}
