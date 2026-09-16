import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// A tempo marking's color and font on the wire: color target 2 appended to `ElementColorTargetWire`, and
/// intent 89 carrying `SetTextFont.Patch` against the tempo's anchor. Both are appended choices; every earlier
/// index keeps its bytes (pinned by `EditIntentCodecPropertiesTests` and `EditIntentCodecTextFontTests`).
@Suite("EditIntentCodec — tempo color and font")
struct EditIntentCodecTempoTextTests {
    private static let zero = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 0,
    )
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 1, staffIndexInPart: 2),
        measureIndex: 3, voiceIndex: 1, elementIndex: 4,
    )
    /// The zero anchor's `VoiceElementIDWire` message: staff (tag 1, 4 bytes), measure, voice, element.
    private static let zeroAnchor: [UInt8] = [
        0x0A, 0x04, 0x08, 0x00, 0x10, 0x00, 0x10, 0x00, 0x18, 0x00, 0x20, 0x00,
    ]

    @Test("a tempo color target round trips with and without a color")
    func colorRoundTrips() throws {
        let colors: [ScoreColor?] = [
            nil, ScoreColor(red: 1, green: 2, blue: 3), ScoreColor(red: -1, green: 256, blue: 0),
        ]
        for color in colors {
            let intent = EditIntent.setElementColor(target: .tempo(anchor: Self.slot), color: color)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    @Test("literal 76 with target 2: the tempo anchor, and a cleared color's zero placeholder")
    func colorBytes() throws {
        let intent = EditIntent.setElementColor(target: .tempo(anchor: Self.zero), color: nil)
        // Target choice = index 2 + tag 1 + length 12 + anchor = 15 bytes; as tag 1 of the payload, 17.
        // Tags 2/3: hasColor = 0 and an all-zero RGBA placeholder (10 bytes). Payload = 29; body = 32.
        let expected: [UInt8] = [0x20, 0x4C, 0x0A, 0x1D, 0x0A, 0x0F, 0x02, 0x0A, 0x0C] + Self.zeroAnchor + [
            0x10, 0x00, 0x1A, 0x08, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00, 0x20, 0x00,
        ]
        #expect(Array(EditIntentCodec.encode(intent)) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
    }

    @Test("every three-state combination of the tempo font patch round trips")
    func fontRoundTrips() throws {
        for value in 0 ..< 243 {
            let patch = SetTextFont.Patch(
                face: Self.update(value, 0, "Edwin"), size: Self.update(value, 1, 17.5),
                style: Self.update(value, 2, [.bold, .italic]), frameType: Self.update(value, 3, .circle),
                framePadding: Self.update(value, 4, 0.25),
            )
            let intent = EditIntent.setTempoFont(anchor: Self.slot, patch: patch)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    @Test("literal 89: the tempo anchor, then intent 78's patch fields byte for byte")
    func fontBytes() throws {
        let fontPatch = SetTextFont.Patch(
            face: .set("A"), size: .clear, style: .set([.bold, .italic]), framePadding: .set(1),
        )
        let intent = EditIntent.setTempoFont(anchor: Self.zero, patch: fontPatch)
        // Payload = anchor (tag 1 + length 12 + 12 = 14) + the 35 patch bytes intent 78 writes = 49.
        // Choice body = index 89 + tag 1 + length 49 + payload = 52.
        let patch: [UInt8] = [
            0x10, 0x02, 0x1A, 0x01, 0x41,
            0x20, 0x01, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x30, 0x02, 0x38, 0x06, 0x40, 0x00, 0x48, 0x00,
            0x50, 0x02, 0x59, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
        ]
        let expected: [UInt8] = [0x34, 0x59, 0x0A, 0x31, 0x0A, 0x0C] + Self.zeroAnchor + patch
        #expect(Array(EditIntentCodec.encode(intent)) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
        // The same patch against a text writes the same field bytes after its own identity.
        let text = EditIntentCodec.encode(.setTextFont(text: .rehearsalMark(measureIndex: 0), patch: fontPatch))
        #expect(Array(text.suffix(patch.count)) == patch)
    }

    @Test("an unknown patch state is refused on the tempo payload too")
    func unknownStateRefused() {
        var wire = SetTempoFontIntentWire(anchor: Self.slot, patch: .init())
        wire.sizeState = 3
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(3)) { try wire.decoded() }
    }

    private static func update<Value: Sendable & Equatable>(
        _ value: Int, _ field: Int, _ set: Value,
    ) -> TextPropertyUpdate<Value> {
        var digit = value
        for _ in 0 ..< field {
            digit /= 3
        }
        switch digit % 3 {
        case 0: return .unchanged
        case 1: return .clear
        default: return .set(set)
        }
    }
}
