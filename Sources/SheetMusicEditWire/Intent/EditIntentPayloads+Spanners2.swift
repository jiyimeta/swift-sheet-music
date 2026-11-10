import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 68…72 (edit-command parity, group 6) and 96. Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged.
// `TrillType` and `VibratoType` are closed `CaseIterable` enums with no escape hatch — unlike ottava's subtype in
// the sibling file, an unlisted spelling here really is a decode failure, the `AccidentalWire` rule.

@WireFormat
public struct SetTrillIntentWire {
    public var range: VoiceElementRangeWire
    public var type: String

    public init(range: VoiceElementRange, type: TrillType) {
        self.range = VoiceElementRangeWire(from: range)
        self.type = type.rawValue
    }

    public func decoded() throws -> (range: VoiceElementRange, type: TrillType) {
        guard let decodedType = TrillType(rawValue: type) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return (range: range.decoded(), type: decodedType)
    }
}

@WireFormat
public struct SetVibratoIntentWire {
    public var range: VoiceElementRangeWire
    public var type: String

    public init(range: VoiceElementRange, type: VibratoType) {
        self.range = VoiceElementRangeWire(from: range)
        self.type = type.rawValue
    }

    public func decoded() throws -> (range: VoiceElementRange, type: VibratoType) {
        guard let decodedType = VibratoType(rawValue: type) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return (range: range.decoded(), type: decodedType)
    }
}

@WireFormat
public struct SetPalmMuteIntentWire {
    public var range: VoiceElementRangeWire

    public init(range: VoiceElementRange) {
        self.range = VoiceElementRangeWire(from: range)
    }

    public func decoded() -> VoiceElementRange {
        range.decoded()
    }
}

@WireFormat
public struct SetLetRingIntentWire {
    public var range: VoiceElementRangeWire

    public init(range: VoiceElementRange) {
        self.range = VoiceElementRangeWire(from: range)
    }

    public func decoded() -> VoiceElementRange {
        range.decoded()
    }
}

@WireFormat
public struct RemoveSpannerIntentWire {
    public var location: VoiceElementIDWire
    public var kind: String

    public init(location: VoiceElementID, kind: Spanner.Kind) {
        self.location = VoiceElementIDWire(from: location)
        self.kind = kind.rawValue
    }

    /// `Spanner.Kind` is closed and `.other` has the raw value `"other"`, so `init(rawValue:)` accepts exactly the
    /// twelve spellings the model can hold and rejects everything else — including `"Tie"`, which is a real MSCX
    /// spanner type this package models elsewhere and must not silently become `.other` here.
    public func decoded() throws -> (location: VoiceElementID, kind: Spanner.Kind) {
        guard let decodedKind = Spanner.Kind(rawValue: kind) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return (location: location.decoded(), kind: decodedKind)
    }
}

/// Intent 96, appended to the spanner group later. `GradualTempoChangeType` is closed like `TrillType` — `.undefined`
/// is a spelling of its own, not an escape hatch — so an unlisted spelling is a decode failure. The factor is the
/// codec's usual optional pair: `hasFactor` 0 decodes as `nil` whatever `factor` holds.
@WireFormat
public struct SetGradualTempoChangeIntentWire {
    public var range: VoiceElementRangeWire
    public var type: String
    public var hasFactor: UInt8
    public var factor: Double

    public init(range: VoiceElementRange, type: GradualTempoChangeType, factor: Double?) {
        self.range = VoiceElementRangeWire(from: range)
        self.type = type.rawValue
        hasFactor = factor == nil ? 0 : 1
        self.factor = factor ?? 0
    }

    public func decoded() throws -> (range: VoiceElementRange, type: GradualTempoChangeType, factor: Double?) {
        guard let decodedType = GradualTempoChangeType(rawValue: type) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return (range: range.decoded(), type: decodedType, factor: hasFactor == 0 ? nil : factor)
    }
}
