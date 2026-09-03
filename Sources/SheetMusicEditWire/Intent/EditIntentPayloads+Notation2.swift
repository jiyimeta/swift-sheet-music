import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 54…57 (edit-command parity, group 4), in `+Notation.swift`'s style. Split for the
// reason `+Marks2.swift` is: SwiftLint's 400-line file budget.

/// The `SetGlissandoIntentWire` tables, in a type of their own so the payload struct carries stored INSTANCE
/// properties only — the reason `BreathTables` exists.
private enum GlissandoTables {
    static let styles: [Glissando.Style] = [.chromatic, .diatonic, .whiteKeys, .blackKeys, .portamento]
    static let visualTypes: [Glissando.VisualType] = [.straight, .wavy]
}

@WireFormat
public struct SetGlissandoIntentWire {
    public var location: NoteIDWire
    public var hasGlissando: UInt8
    /// 0 chromatic, 1 diatonic, 2 whiteKeys, 3 blackKeys, 4 portamento.
    public var style: UInt8
    /// 0 straight, 1 wavy.
    public var visualType: UInt8
    public var easeIn: Int32
    public var easeOut: Int32
    public var hasText: UInt8
    public var text: String

    public init(location: NoteID, glissando: Glissando?) {
        self.location = NoteIDWire(from: location)
        hasGlissando = glissando == nil ? 0 : 1
        style = GlissandoTables.styles.firstIndex(of: glissando?.style ?? .chromatic).map { UInt8($0) } ?? 0
        visualType = GlissandoTables.visualTypes
            .firstIndex(of: glissando?.visualType ?? .straight)
            .map { UInt8($0) } ?? 0
        easeIn = Int32(glissando?.easeIn ?? 0)
        easeOut = Int32(glissando?.easeOut ?? 0)
        // An ABSENT text is not an empty one: `MSCXDecoder+Note.decodeGlissandoText` treats absent as "MuseScore's
        // per-type default" and empty as "the user cleared it", so both shapes must survive the round trip.
        hasText = glissando?.text == nil ? 0 : 1
        text = glissando?.text ?? ""
    }

    public func decoded() throws -> (location: NoteID, glissando: Glissando?) {
        guard hasGlissando != 0 else { return (location: location.decoded(), glissando: nil) }
        guard GlissandoTables.styles.indices.contains(Int(style)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(style))
        }
        guard GlissandoTables.visualTypes.indices.contains(Int(visualType)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(visualType))
        }
        return (
            location: location.decoded(),
            glissando: Glissando(
                style: GlissandoTables.styles[Int(style)],
                visualType: GlissandoTables.visualTypes[Int(visualType)],
                easeIn: Int(easeIn), easeOut: Int(easeOut), text: hasText == 0 ? nil : text,
            ),
        )
    }
}

@WireFormat
public struct SetDotsIntentWire {
    public var location: VoiceElementIDWire
    public var dots: Int32

    public init(location: VoiceElementID, dots: Int) {
        self.location = VoiceElementIDWire(from: location)
        self.dots = Int32(dots)
    }

    /// Bounded `0…3` here — the same untrusted-input argument `SetArpeggioIntentWire.decoded()` makes. `SetDots`
    /// answers an out-of-range count with `.notDottable`, so a locally built command is not left unguarded.
    public func decoded() throws -> (location: VoiceElementID, dots: Int) {
        guard (0 ... 3).contains(dots) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(bitPattern: dots))
        }
        return (location: location.decoded(), dots: Int(dots))
    }
}

@WireFormat
public struct SetChordLineIntentWire {
    public var location: VoiceElementIDWire
    public var hasLine: UInt8
    /// `ChordLine.Kind.rawValue`: 1 fall, 2 doit, 3 plop, 4 scoop.
    public var kind: UInt8
    public var isStraight: UInt8

    public init(location: VoiceElementID, kind: ChordLine.Kind?, isStraight: Bool) {
        self.location = VoiceElementIDWire(from: location)
        hasLine = kind == nil ? 0 : 1
        self.kind = UInt8(kind?.rawValue ?? 1)
        // Passed through as given even when `hasLine == 0`, unlike the sibling glissando payload, which zeroes an
        // absent value's fields. `isStraight` is not optional on `EditIntent.setChordLine` — it is a plain `Bool`
        // associated value — so `decoded()` always returns whatever this wire carries; zeroing it here would make
        // `EditIntent` round-trip unequal to itself whenever a caller clears a line with `isStraight: true`. Do
        // not "fix" this into a zero.
        self.isStraight = isStraight ? 1 : 0
    }

    /// `ChordLine.Kind`'s raw values ARE MuseScore's `<subtype>` numbers (`ChordLine.swift`), so no second table
    /// is invented; an unknown one throws rather than collapsing to a kind the sender did not send.
    public func decoded() throws -> (location: VoiceElementID, kind: ChordLine.Kind?, isStraight: Bool) {
        guard hasLine != 0 else {
            return (location: location.decoded(), kind: nil, isStraight: isStraight != 0)
        }
        guard let kind = ChordLine.Kind(rawValue: Int(kind)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(kind))
        }
        return (location: location.decoded(), kind: kind, isStraight: isStraight != 0)
    }
}

/// `NoteParentheses` travels as a `u8`, not as its `mscxToken` string, even though it HAS a token pair
/// (`NoteParentheses.swift`): spec §4.2 lists parentheses under the `u8` rule, and the reason holds — the token
/// initializer is LOSSY (`init(mscxToken:)` maps anything unknown to `.none`), so a string payload would silently
/// swallow a corrupted byte, exactly what the `AccidentalWire` rule exists to prevent. A `u8` with a throwing
/// table cannot.
private enum ParenthesesTable {
    static let modes: [NoteParentheses] = [.none, .left, .right, .both]
}

@WireFormat
public struct SetNoteParenthesesIntentWire {
    public var location: NoteIDWire
    /// 0 none, 1 left, 2 right, 3 both; anything above throws.
    public var parentheses: UInt8

    public init(location: NoteID, parentheses: NoteParentheses) {
        self.location = NoteIDWire(from: location)
        self.parentheses = ParenthesesTable.modes.firstIndex(of: parentheses).map { UInt8($0) } ?? 0
    }

    public func decoded() throws -> (location: NoteID, parentheses: NoteParentheses) {
        guard ParenthesesTable.modes.indices.contains(Int(parentheses)) else {
            throw WireFormatError.unknownChoiceDiscriminator(UInt32(parentheses))
        }
        return (location: location.decoded(), parentheses: ParenthesesTable.modes[Int(parentheses)])
    }
}
