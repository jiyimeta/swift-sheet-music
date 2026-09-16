import SheetMusicCore
import SheetMusicFoundation
import Wirelet

/// Intent 78. Tag 1 is the text identity; tags 2...11 alternate update state and scalar value,
/// in face, size, style, frameType, framePadding order. State: 0 unchanged, 1 clear, 2 set.
/// All fields are mandatory. Non-set values use zero/empty placeholders, ignored on decode.
/// Unknown update states and unknown set frame types are refused, never silently converted into edits.
/// Style uses signed Int64 to preserve the model's entire Int bitset, including unknown bits.
/// Frame values: 0 none, 1 rectangle, 2 circle. State controls whether the value is read at all.
@WireFormat
public struct SetTextFontIntentWire {
    public var text: ScoreTextIDWire
    public var faceState: UInt8
    public var face: String
    public var sizeState: UInt8
    public var size: Double
    public var styleState: UInt8
    public var style: Int64
    public var frameTypeState: UInt8
    public var frameType: UInt8
    public var framePaddingState: UInt8
    public var framePadding: Double

    public init(text: ScoreTextID, patch: SetTextFont.Patch) {
        self.text = ScoreTextIDWire(from: text)
        let fields = PatchWireFields(patch)
        faceState = fields.faceState
        face = fields.face
        sizeState = fields.sizeState
        size = fields.size
        styleState = fields.styleState
        style = fields.style
        frameTypeState = fields.frameTypeState
        frameType = fields.frameType
        framePaddingState = fields.framePaddingState
        framePadding = fields.framePadding
    }

    public func decoded() throws -> (text: ScoreTextID, patch: SetTextFont.Patch) {
        let fields = PatchWireFields(
            faceState: faceState, face: face, sizeState: sizeState, size: size, styleState: styleState,
            style: style, frameTypeState: frameTypeState, frameType: frameType,
            framePaddingState: framePaddingState, framePadding: framePadding,
        )
        return try (text.decoded(), fields.patch())
    }
}

/// Intent 89. Tag 1 is the tempo's anchor — the chord or rest `SetTempo` addresses it by — and tags 2...11 are
/// intent 78's patch fields, in the same order, states and placeholders.
@WireFormat
public struct SetTempoFontIntentWire {
    public var anchor: VoiceElementIDWire
    public var faceState: UInt8
    public var face: String
    public var sizeState: UInt8
    public var size: Double
    public var styleState: UInt8
    public var style: Int64
    public var frameTypeState: UInt8
    public var frameType: UInt8
    public var framePaddingState: UInt8
    public var framePadding: Double

    public init(anchor: VoiceElementID, patch: SetTextFont.Patch) {
        self.anchor = VoiceElementIDWire(from: anchor)
        let fields = PatchWireFields(patch)
        faceState = fields.faceState
        face = fields.face
        sizeState = fields.sizeState
        size = fields.size
        styleState = fields.styleState
        style = fields.style
        frameTypeState = fields.frameTypeState
        frameType = fields.frameType
        framePaddingState = fields.framePaddingState
        framePadding = fields.framePadding
    }

    public func decoded() throws -> (anchor: VoiceElementID, patch: SetTextFont.Patch) {
        let fields = PatchWireFields(
            faceState: faceState, face: face, sizeState: sizeState, size: size, styleState: styleState,
            style: style, frameTypeState: frameTypeState, frameType: frameType,
            framePaddingState: framePaddingState, framePadding: framePadding,
        )
        return try (anchor.decoded(), fields.patch())
    }
}

/// The ten flattened patch fields both font payloads carry, encoded and decoded in one place so the two
/// intents cannot drift apart on a state or frame value.
private struct PatchWireFields {
    var faceState: UInt8
    var face: String
    var sizeState: UInt8
    var size: Double
    var styleState: UInt8
    var style: Int64
    var frameTypeState: UInt8
    var frameType: UInt8
    var framePaddingState: UInt8
    var framePadding: Double

    init(
        faceState: UInt8, face: String, sizeState: UInt8, size: Double, styleState: UInt8, style: Int64,
        frameTypeState: UInt8, frameType: UInt8, framePaddingState: UInt8, framePadding: Double,
    ) {
        self.faceState = faceState
        self.face = face
        self.sizeState = sizeState
        self.size = size
        self.styleState = styleState
        self.style = style
        self.frameTypeState = frameTypeState
        self.frameType = frameType
        self.framePaddingState = framePaddingState
        self.framePadding = framePadding
    }

    init(_ patch: SetTextFont.Patch) {
        faceState = patch.face.wireState
        face = patch.face.wireValue ?? ""
        sizeState = patch.size.wireState
        size = patch.size.wireValue ?? 0
        styleState = patch.style.wireState
        style = patch.style.wireValue.map { Int64($0.rawValue) } ?? 0
        frameTypeState = patch.frameType.wireState
        switch patch.frameType.wireValue {
        case nil, .some(.none): frameType = 0
        case .rectangle: frameType = 1
        case .circle: frameType = 2
        }
        framePaddingState = patch.framePadding.wireState
        framePadding = patch.framePadding.wireValue ?? 0
    }

    func patch() throws -> SetTextFont.Patch {
        try SetTextFont.Patch(
            face: update(faceState) { face },
            size: update(sizeState) { size },
            style: update(styleState) {
                guard let value = Int(exactly: style) else { throw WireFormatError.varintOverflow }
                return FontStyleSet(rawValue: value)
            },
            frameType: update(frameTypeState) {
                switch frameType {
                case 0: TextFrameType.none
                case 1: .rectangle
                case 2: .circle
                default: throw WireFormatError.unknownChoiceDiscriminator(UInt32(frameType))
                }
            },
            framePadding: update(framePaddingState) { framePadding },
        )
    }

    private func update<Value: Sendable & Equatable>(
        _ state: UInt8, value: () throws -> Value,
    ) throws -> TextPropertyUpdate<Value> {
        switch state {
        case 0: .unchanged
        case 1: .clear
        case 2: try .set(value())
        default: throw WireFormatError.unknownChoiceDiscriminator(UInt32(state))
        }
    }
}

extension TextPropertyUpdate {
    fileprivate var wireState: UInt8 {
        switch self {
        case .unchanged: 0
        case .clear: 1
        case .set: 2
        }
    }

    fileprivate var wireValue: Value? {
        guard case let .set(value) = self else { return nil }
        return value
    }
}

/// Intent 79: tag 1 text identity (only lyric is accepted by the command), tag 2 signed destination verse.
@WireFormat
public struct SetLyricVerseIntentWire {
    public var text: ScoreTextIDWire
    public var toVerse: Int64

    public init(text: ScoreTextID, toVerse: Int) {
        self.text = ScoreTextIDWire(from: text)
        self.toVerse = Int64(toVerse)
    }

    public func decoded() throws -> (text: ScoreTextID, toVerse: Int) {
        guard let destination = Int(exactly: toVerse) else { throw WireFormatError.varintOverflow }
        return (text.decoded(), destination)
    }
}
