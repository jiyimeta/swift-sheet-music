import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

@Suite("EditIntentCodec — font and verse")
struct EditIntentCodecTextFontTests {
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 0,
    )

    @Test("literal 78: mixed set/clear/unchanged fields, signed bitset and fixed64 padding")
    func fontBytes() throws {
        let intent = EditIntent.setTextFont(
            text: .rehearsalMark(measureIndex: 0),
            patch: .init(face: .set("A"), size: .clear, style: .set([.bold, .italic]), framePadding: .set(1)),
        )
        // Payload = 5-byte identity + 2/3/2/9/2/2/2/2/2/9 bytes for tags 2...11 = 40.
        // Choice body = index 78 + tag 1 + length 40 + payload = 43 bytes.
        // Double 1 is 0x3FF0000000000000, little-endian; style raw 3 zig-zags to 6.
        let expected: [UInt8] = [
            0x2B, 0x4E, 0x0A, 0x28,
            0x0A, 0x03, 0x03, 0x08, 0x00,
            0x10, 0x02, 0x1A, 0x01, 0x41,
            0x20, 0x01, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x30, 0x02, 0x38, 0x06, 0x40, 0x00, 0x48, 0x00,
            0x50, 0x02, 0x59, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
        ]
        #expect(Array(EditIntentCodec.encode(intent)) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
    }

    @Test("literal 79: lyric at the zero address, verse 0 to verse 2")
    func verseBytes() throws {
        let intent = EditIntent.setLyricVerse(text: .lyric(anchor: Self.slot, verse: 0), toVerse: 2)
        // Staff = 4 bytes; anchor = 12; lyric payload = 16; text choice = 19.
        // Intent payload = tag 1 + length 19 + choice + tag 2 + zig-zag(2) = 23.
        // Outer body = index 79 + tag 1 + length 23 + payload = 26.
        let expected: [UInt8] = [
            0x1A, 0x4F, 0x0A, 0x17,
            0x0A, 0x13, 0x00, 0x0A, 0x10,
            0x0A, 0x0C, 0x0A, 0x04, 0x08, 0x00, 0x10, 0x00,
            0x10, 0x00, 0x18, 0x00, 0x20, 0x00,
            0x10, 0x00, 0x10, 0x04,
        ]
        #expect(Array(EditIntentCodec.encode(intent)) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
    }

    @Test("all three states of each field stay independent on every text identity")
    func combinations() throws {
        let texts: [ScoreTextID] = [
            .lyric(anchor: Self.slot, verse: 3), .staffText(anchor: Self.slot, style: .staffText),
            .staffText(anchor: Self.slot, style: .systemText), .harmony(anchor: Self.slot),
            .rehearsalMark(measureIndex: 17),
        ]
        for text in texts {
            for value in 0 ..< 243 {
                let patch = SetTextFont.Patch(
                    face: Self.state(value % 3, "字"), size: Self.state(value / 3 % 3, 12.5),
                    style: Self.state(value / 9 % 3, FontStyleSet(rawValue: Int.min)),
                    frameType: Self.state(value / 27 % 3, .circle),
                    framePadding: Self.state(value / 81 % 3, -0.5),
                )
                let intent = EditIntent.setTextFont(text: text, patch: patch)
                #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
            }
        }
        for frame in [TextFrameType.none, .rectangle, .circle] {
            let intent = EditIntent.setTextFont(text: texts[0], patch: .init(frameType: .set(frame)))
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
        for verse in [Int.min, -1, 0, Int.max] {
            let intent = EditIntent.setLyricVerse(text: texts[0], toVerse: verse)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    @Test("unknown states refuse; clear and unchanged ignore invalid placeholders")
    func invalidStates() throws {
        let text = ScoreTextID.rehearsalMark(measureIndex: 0)
        let fields: [WritableKeyPath<SetTextFontIntentWire, UInt8>] = [
            \.faceState, \.sizeState, \.styleState, \.frameTypeState, \.framePaddingState,
        ]
        for field in fields {
            var wire = SetTextFontIntentWire(text: text, patch: .init())
            wire[keyPath: field] = 3
            #expect(throws: WireFormatError.unknownChoiceDiscriminator(3)) { try wire.decoded() }
        }
        var wire = SetTextFontIntentWire(text: text, patch: .init())
        wire.frameType = 255
        #expect(try wire.decoded().patch.frameType == .unchanged)
        wire.frameTypeState = 1
        #expect(try wire.decoded().patch.frameType == .clear)
        wire.frameTypeState = 2
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(255)) { try wire.decoded() }
    }

    private static func state<Value: Sendable & Equatable>(_ state: Int, _ value: Value) -> TextPropertyUpdate<Value> {
        switch state {
        case 0: .unchanged
        case 1: .clear
        default: .set(value)
        }
    }
}
