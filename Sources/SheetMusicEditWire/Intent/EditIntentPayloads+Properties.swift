import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Intents 76/77. The macro permits Optional stored properties; hasX + value is used for consistency
// with the existing intent payloads, not because flattening is required by Wirelet.
// Every field is mandatory. Presence is UInt8 (zero = absent, any nonzero = present).
// When absent, writers emit a zero-valued placeholder and readers ignore it.

/// Color supports text and individual notes only. Case indices are persistent: 0 text, 1 note.
@WireFormatChoice
public enum ElementColorTargetWire {
    case text(ScoreTextIDWire)
    case note(NoteIDWire)

    public init(from target: SetElementColor.Target) {
        switch target {
        case let .text(id): self = .text(ScoreTextIDWire(from: id))
        case let .note(id): self = .note(NoteIDWire(from: id))
        }
    }

    public func decoded() -> SetElementColor.Target {
        switch self {
        case let .text(id): .text(id.decoded())
        case let .note(id): .note(id.decoded())
        }
    }
}

/// Placement also supports a whole chord (including a rest). Persistent indices: 0 text, 1 note, 2 chord.
@WireFormatChoice
public enum ElementPlacementTargetWire {
    case text(ScoreTextIDWire)
    case note(NoteIDWire)
    case chord(VoiceElementIDWire)

    public init(from target: SetElementPlacement.Target) {
        switch target {
        case let .text(id): self = .text(ScoreTextIDWire(from: id))
        case let .note(id): self = .note(NoteIDWire(from: id))
        case let .chord(id): self = .chord(VoiceElementIDWire(from: id))
        }
    }

    public func decoded() -> SetElementPlacement.Target {
        switch self {
        case let .text(id): .text(id.decoded())
        case let .note(id): .note(id.decoded())
        case let .chord(id): .chord(id.decoded())
        }
    }
}

/// RGBA tags 1...4, signed zig-zag Int64. ScoreColor stores unconstrained Int channels, despite the
/// conventional 0...255 range, so UInt8 conversion would trap or lose information. Preserve the model value;
/// refuse values unrepresentable on the receiving platform instead of truncating them.
@WireFormat
public struct ElementColorWire {
    public var red: Int64
    public var green: Int64
    public var blue: Int64
    public var alpha: Int64

    public init(from color: ScoreColor) {
        red = Int64(color.red)
        green = Int64(color.green)
        blue = Int64(color.blue)
        alpha = Int64(color.alpha)
    }

    public func decoded() throws -> ScoreColor {
        guard let red = Int(exactly: red), let green = Int(exactly: green),
              let blue = Int(exactly: blue), let alpha = Int(exactly: alpha)
        else { throw WireFormatError.varintOverflow }
        return ScoreColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Tags: 1 target, 2 hasColor, 3 color (nested RGBA message).
@WireFormat
public struct SetElementColorIntentWire {
    public var target: ElementColorTargetWire
    public var hasColor: UInt8
    public var color: ElementColorWire

    public init(target: SetElementColor.Target, color: ScoreColor?) {
        self.target = ElementColorTargetWire(from: target)
        hasColor = color == nil ? 0 : 1
        self.color = ElementColorWire(from: color ?? ScoreColor(red: 0, green: 0, blue: 0, alpha: 0))
    }

    public func decoded() throws -> (target: SetElementColor.Target, color: ScoreColor?) {
        try (target: target.decoded(), color: hasColor == 0 ? nil : color.decoded())
    }
}

/// Tags: 1 target, 2 hasPlacement, 3 placement (UInt8: 0 above, 1 below; 0 placeholder when absent).
@WireFormat
public struct SetElementPlacementIntentWire {
    public var target: ElementPlacementTargetWire
    public var hasPlacement: UInt8
    public var placement: UInt8

    public init(target: SetElementPlacement.Target, placement: Placement?) {
        self.target = ElementPlacementTargetWire(from: target)
        hasPlacement = placement == nil ? 0 : 1
        switch placement {
        case .above, nil: self.placement = 0
        case .below: self.placement = 1
        }
    }

    public func decoded() throws -> (target: SetElementPlacement.Target, placement: Placement?) {
        guard hasPlacement != 0 else { return (target.decoded(), nil) }
        let value: Placement
        switch placement {
        case 0: value = .above
        case 1: value = .below
        default: throw WireFormatError.unknownChoiceDiscriminator(UInt32(placement))
        }
        return (target.decoded(), value)
    }
}
