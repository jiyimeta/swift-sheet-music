import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 41…47 (edit-command parity, group 3). Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory (`SetTempoIntentWire`'s tags 6–9 and `SetDynamicIntentWire`'s tag 4 are the `T?` exceptions,
// written only when non-nil), optionals as `has` + value pairs, enums this codec does not own as raw strings, small
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
    /// Tag 6: what the write does to the text — absent `.keep`, 1 `.derive`, 2 `.set(text)`.
    public var textMode: UInt8?
    /// Tag 7: the text a `.set` writes.
    public var text: String?
    /// Tag 8: `<play>` — absent leaves it, 0 mutes the marking, 1 plays it.
    public var playsBack: UInt8?
    /// Tag 9: whether the number and beat were edited — absent infers it at the receiver (older senders), 0 no, 1 yes.
    public var numberEdit: UInt8?

    public init(anchor: VoiceElementID, marking: SetTempo.Marking?) {
        numberEdit = marking?.numberEdit.map { $0 ? 1 : 0 }
        self.anchor = VoiceElementIDWire(from: anchor)
        hasTempo = marking == nil ? 0 : 1
        beatsPerSecond = marking?.beatsPerSecond ?? 0
        beatNote = NoteDurationWire(from: marking?.beatNote ?? .quarter)
        beatDots = Int32(marking?.beatDots ?? 0)
        switch marking?.text ?? .keep {
        case .keep:
            textMode = nil
            text = nil
        case .derive:
            textMode = 1
            text = nil
        case let .set(value):
            textMode = 2
            text = value
        }
        playsBack = marking?.playsBack.map { $0 ? 1 : 0 }
    }

    public func decoded() throws -> (anchor: VoiceElementID, marking: SetTempo.Marking?) {
        guard hasTempo != 0 else { return (anchor: anchor.decoded(), marking: nil) }
        // A mode this build does not know, or a `.set` without its text, is malformed bytes: refusing them is better
        // than applying a different edit from the one that was sent.
        let textEdit: SetTempo.Marking.TextEdit
        switch textMode {
        case nil:
            textEdit = .keep
        case 1?:
            textEdit = .derive
        case 2?:
            guard let text else { throw WireFormatError.unknownTag(tag: 7, wireType: .lengthDelimited) }
            textEdit = .set(text)
        case let mode?:
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(mode))
        }
        return try (
            anchor: anchor.decoded(),
            marking: SetTempo.Marking(
                beatsPerSecond: beatsPerSecond, beatNote: beatNote.decoded(), beatDots: Int(beatDots),
                text: textEdit, playsBack: playsBack.map { $0 != 0 }, numberEdit: numberEdit.map { $0 != 0 },
            ),
        )
    }
}

/// `setSwing`'s payload. `isSystemText` is carried OUTSIDE the settings as well as inside them, because a removal
/// has no settings and still has to say which of the two kinds at the beat it means — the same question
/// `SetStaffTextIntentWire` answers with its own top-level flag.
///
/// The unit crosses as its MSCX spelling ("", "eighth", "16th") rather than as an ordinal: it is the string the
/// format itself uses, so a reader on the far side needs no table to agree with the encoder.
@WireFormat
public struct SetSwingIntentWire {
    public var anchor: VoiceElementIDWire
    public var hasSettings: UInt8
    public var text: String
    public var unit: String
    public var ratio: Int32
    public var isSystemText: UInt8

    public init(anchor: VoiceElementID, settings: SetSwing.Settings?, isSystemText: Bool) {
        self.anchor = VoiceElementIDWire(from: anchor)
        hasSettings = settings == nil ? 0 : 1
        text = settings?.text ?? ""
        unit = (settings?.unit ?? .off).mscxString
        ratio = Int32(settings?.ratio ?? 0)
        self.isSystemText = isSystemText ? 1 : 0
    }

    public func decoded() -> (anchor: VoiceElementID, settings: SetSwing.Settings?, isSystemText: Bool) {
        let system = isSystemText != 0
        guard hasSettings != 0 else {
            return (anchor: anchor.decoded(), settings: nil, isSystemText: system)
        }
        return (
            anchor: anchor.decoded(),
            settings: SetSwing.Settings(
                // An unrecognized spelling straightens rather than guessing a subdivision — `SwingUnit`'s own
                // fallback rule, stated where it is applied.
                text: text, unit: SwingUnit(mscxString: unit) ?? .off, ratio: Int(ratio), isSystemText: system,
            ),
            isSystemText: system,
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
    /// Tag 4: the dynamic's own text as MuseScore xml text (`Dynamic.customXMLText`); absent for its subtype's glyphs
    /// and for a removal, so those encode as they did before the tag existed.
    public var xmlText: String?

    public init(location: VoiceElementID, subtype: String?, xmlText: String? = nil) {
        self.location = VoiceElementIDWire(from: location)
        hasDynamic = subtype == nil ? 0 : 1
        self.subtype = subtype ?? ""
        self.xmlText = subtype == nil ? nil : xmlText
    }

    public func decoded() -> (location: VoiceElementID, subtype: String?, xmlText: String?) {
        let decodedSubtype = hasDynamic == 0 ? nil : subtype
        return (location: location.decoded(), subtype: decodedSubtype, xmlText: decodedSubtype == nil ? nil : xmlText)
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
