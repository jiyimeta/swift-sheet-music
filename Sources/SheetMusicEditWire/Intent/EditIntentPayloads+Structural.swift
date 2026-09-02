import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 30…34 (edit-command parity, group 1). Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory, optionals as `has` + value pairs, enums this codec does not own as raw strings.

@WireFormat
public struct SetLayoutBreakIntentWire {
    public var measure: MeasureRefWire
    public var kind: UInt8
    public var enabled: UInt8

    public init(measure: MeasureRef, kind: LayoutBreakKind, enabled: Bool) {
        self.measure = MeasureRefWire(from: measure)
        self.kind = kind.rawValue
        self.enabled = enabled ? 1 : 0
    }

    /// Throws `unknownChoiceDiscriminator` for a kind outside `LayoutBreakKind` — a break a newer writer knows and
    /// an older reader does not must not decode as some other break.
    public func decoded() throws -> (measure: MeasureRef, kind: LayoutBreakKind, enabled: Bool) {
        guard let kind = LayoutBreakKind(rawValue: kind) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(kind))
        }
        return (measure: measure.decoded(), kind: kind, enabled: enabled != 0)
    }
}

@WireFormat
public struct SetBarLineIntentWire {
    public var measure: MeasureRefWire
    public var style: String

    public init(measure: MeasureRef, style: BarLineStyle) {
        self.measure = MeasureRefWire(from: measure)
        self.style = style.rawValue
    }

    /// Throws `unknownChoiceDiscriminator` for a spelling `BarLineStyle` does not know — the same forward-
    /// compatibility rule `AccidentalWire.decoded()` enforces on its own raw-string payload.
    public func decoded() throws -> (measure: MeasureRef, style: BarLineStyle) {
        guard let style = BarLineStyle(rawValue: style) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return (measure: measure.decoded(), style: style)
    }
}

@WireFormat
public struct SetRepeatBarLinesIntentWire {
    public var measure: MeasureRefWire
    public var startRepeat: UInt8
    public var hasEndRepeat: UInt8
    public var endRepeatCount: Int32

    public init(measure: MeasureRef, startRepeat: Bool, endRepeatCount: Int?) {
        self.measure = MeasureRefWire(from: measure)
        self.startRepeat = startRepeat ? 1 : 0
        hasEndRepeat = endRepeatCount == nil ? 0 : 1
        self.endRepeatCount = Int32(endRepeatCount ?? 0)
    }

    public func decoded() -> (measure: MeasureRef, startRepeat: Bool, endRepeatCount: Int?) {
        (
            measure: measure.decoded(),
            startRepeat: startRepeat != 0,
            endRepeatCount: hasEndRepeat == 0 ? nil : Int(endRepeatCount),
        )
    }
}

@WireFormat
public struct SetMeasureRepeatIntentWire {
    public var measure: MeasureRefWire
    public var staff: StaffAddressWire
    public var hasCount: UInt8
    public var numMeasures: Int32

    public init(measure: MeasureRef, staff: StaffAddress, numMeasures: Int?) {
        self.measure = MeasureRefWire(from: measure)
        self.staff = StaffAddressWire(from: staff)
        hasCount = numMeasures == nil ? 0 : 1
        self.numMeasures = Int32(numMeasures ?? 0)
    }

    public func decoded() -> (measure: MeasureRef, staff: StaffAddress, numMeasures: Int?) {
        (measure: measure.decoded(), staff: staff.decoded(), numMeasures: hasCount == 0 ? nil : Int(numMeasures))
    }
}

@WireFormat
public struct MoveToVoiceIntentWire {
    public var location: VoiceElementIDWire
    public var destination: VoiceRefWire

    public init(location: VoiceElementID, destination: VoiceRef) {
        self.location = VoiceElementIDWire(from: location)
        self.destination = VoiceRefWire(from: destination)
    }

    public func decoded() -> (location: VoiceElementID, destination: VoiceRef) {
        (location: location.decoded(), destination: destination.decoded())
    }
}
