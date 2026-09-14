import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 35…40 (edit-command parity, group 2). Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory, optionals as `has` + value pairs, and every score location a nested reference mirror.

@WireFormat
public struct TransposeRangeIntentWire {
    public var range: VoiceElementRangeWire
    public var semitones: Int32
    public var respellInKey: UInt8

    public init(range: VoiceElementRange, semitones: Int, respellInKey: Bool) {
        self.range = VoiceElementRangeWire(from: range)
        self.semitones = Int32(semitones)
        self.respellInKey = respellInKey ? 1 : 0
    }

    public func decoded() -> (range: VoiceElementRange, semitones: Int, respellInKey: Bool) {
        (range: range.decoded(), semitones: Int(semitones), respellInKey: respellInKey != 0)
    }
}

@WireFormat
public struct AddIntervalToSelectionIntentWire {
    public var range: VoiceElementRangeWire
    public var steps: Int32

    public init(range: VoiceElementRange, steps: Int) {
        self.range = VoiceElementRangeWire(from: range)
        self.steps = Int32(steps)
    }

    public func decoded() -> (range: VoiceElementRange, steps: Int) {
        (range: range.decoded(), steps: Int(steps))
    }
}

@WireFormat
public struct DeleteRangeIntentWire {
    public var range: VoiceElementRangeWire

    public init(range: VoiceElementRange) {
        self.range = VoiceElementRangeWire(from: range)
    }

    public func decoded() -> VoiceElementRange {
        range.decoded()
    }
}

@WireFormat
public struct SetAccidentalsInRangeIntentWire {
    public var range: VoiceElementRangeWire
    public var accidental: AccidentalWire

    public init(range: VoiceElementRange, accidental: Accidental?) {
        self.range = VoiceElementRangeWire(from: range)
        self.accidental = AccidentalWire(from: accidental)
    }

    public func decoded() throws -> (range: VoiceElementRange, accidental: Accidental?) {
        try (range: range.decoded(), accidental: accidental.decoded())
    }
}

@WireFormat
public struct SetDurationInRangeIntentWire {
    public var range: VoiceElementRangeWire
    public var duration: NoteDurationWire

    public init(range: VoiceElementRange, duration: NoteDuration) {
        self.range = VoiceElementRangeWire(from: range)
        self.duration = NoteDurationWire(from: duration)
    }

    public func decoded() throws -> (range: VoiceElementRange, duration: NoteDuration) {
        try (range: range.decoded(), duration: duration.decoded())
    }
}

@WireFormat
public struct RespellRangeIntentWire {
    public var range: VoiceElementRangeWire
    public var mode: UInt8

    public init(range: VoiceElementRange, mode: RespellMode) {
        self.range = VoiceElementRangeWire(from: range)
        self.mode = mode.rawValue
    }

    /// Throws `unknownChoiceDiscriminator` for a mode outside `RespellMode` — a preference a newer writer knows
    /// must not decode as some other preference on an older reader.
    public func decoded() throws -> (range: VoiceElementRange, mode: RespellMode) {
        guard let mode = RespellMode(rawValue: mode) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(mode))
        }
        return (range: range.decoded(), mode: mode)
    }
}

@WireFormat
public struct DuplicateRangeIntentWire {
    public var range: VoiceElementRangeWire

    public init(range: VoiceElementRange) {
        self.range = VoiceElementRangeWire(from: range)
    }

    public func decoded() -> VoiceElementRange {
        range.decoded()
    }
}

@WireFormat
public struct PasteRangeIntentWire {
    public var location: VoiceElementIDWire
    public var payload: String

    public init(location: VoiceElementID, payload: String) {
        self.location = VoiceElementIDWire(from: location)
        self.payload = payload
    }

    public func decoded() -> (location: VoiceElementID, payload: String) {
        (location: location.decoded(), payload: payload)
    }
}

// Appended for the score-transposition project (spec 2026-09-14) — intents 87 and 88. `TransposeScoreIntentWire`
// lives here rather than in a file of its own because it is `TransposeRangeIntentWire` with the range taken away:
// the two must stay in step, and a reader comparing them should not have to open two files.

@WireFormat
public struct SetDotsInRangeIntentWire {
    public var range: VoiceElementRangeWire
    public var dots: Int32

    public init(range: VoiceElementRange, dots: Int) {
        self.range = VoiceElementRangeWire(from: range)
        self.dots = Int32(dots)
    }

    public func decoded() -> (range: VoiceElementRange, dots: Int) {
        (range: range.decoded(), dots: Int(dots))
    }
}

@WireFormat
public struct TransposeScoreIntentWire {
    public var semitones: Int32
    public var transposeKeySignatures: UInt8
    public var respellInKey: UInt8

    public init(semitones: Int, transposeKeySignatures: Bool, respellInKey: Bool) {
        self.semitones = Int32(semitones)
        self.transposeKeySignatures = transposeKeySignatures ? 1 : 0
        self.respellInKey = respellInKey ? 1 : 0
    }

    public func decoded() -> (semitones: Int, transposeKeySignatures: Bool, respellInKey: Bool) {
        (
            semitones: Int(semitones),
            transposeKeySignatures: transposeKeySignatures != 0,
            respellInKey: respellInKey != 0,
        )
    }
}
