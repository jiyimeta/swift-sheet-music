import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 48…49 (edit-command parity, group 3) and the list element mirrors they carry.
// The two lists are the codec's first arrays of structs since `PartPlanWire.staves`; an empty list encodes as
// its tag with a zero length, which `EditIntentCodecMarkTests` pins.

/// `Jump`, field for field. Strings are MuseScore's own tokens (`jumpTo` / `playUntil` / `continueAt`:
/// "start", "segno", "fine", "coda", "codab", "end", ""); the codec does not interpret them.
@WireFormat
public struct JumpWire {
    public var jumpTo: String
    public var playUntil: String
    public var continueAt: String
    public var playRepeats: UInt8
    public var text: String

    public init(from jump: Jump) {
        jumpTo = jump.jumpTo
        playUntil = jump.playUntil
        continueAt = jump.continueAt
        playRepeats = jump.playRepeats ? 1 : 0
        text = jump.text
    }

    public func decoded() -> Jump {
        Jump(jumpTo: jumpTo, playUntil: playUntil, continueAt: continueAt, playRepeats: playRepeats != 0, text: text)
    }
}

/// `Marker`, with `kind` as `Marker.Kind.rawValue` — a raw string, not an index, because that enum's case order
/// is not this codec's to control (the `AccidentalWire` rule). An unknown kind throws.
@WireFormat
public struct MarkerWire {
    public var kind: String
    public var label: String
    public var text: String

    public init(from marker: Marker) {
        kind = marker.kind.rawValue
        label = marker.label
        text = marker.text
    }

    public func decoded() throws -> Marker {
        guard let kind = Marker.Kind(rawValue: kind) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return Marker(kind: kind, label: label, text: text)
    }
}

@WireFormat
public struct SetJumpsIntentWire {
    public var measure: MeasureRefWire
    public var jumps: [JumpWire]

    public init(measure: MeasureRef, jumps: [Jump]) {
        self.measure = MeasureRefWire(from: measure)
        self.jumps = jumps.map(JumpWire.init(from:))
    }

    public func decoded() -> (measure: MeasureRef, jumps: [Jump]) {
        (measure: measure.decoded(), jumps: jumps.map { $0.decoded() })
    }
}

@WireFormat
public struct SetMarkersIntentWire {
    public var measure: MeasureRefWire
    public var markers: [MarkerWire]

    public init(measure: MeasureRef, markers: [Marker]) {
        self.measure = MeasureRefWire(from: measure)
        self.markers = markers.map(MarkerWire.init(from:))
    }

    public func decoded() throws -> (measure: MeasureRef, markers: [Marker]) {
        try (measure: measure.decoded(), markers: markers.map { try $0.decoded() })
    }
}
