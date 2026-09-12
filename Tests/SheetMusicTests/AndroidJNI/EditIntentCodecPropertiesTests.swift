import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

@Suite("EditIntentCodec — element properties")
struct EditIntentCodecPropertiesTests {
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 1, staffIndexInPart: 2),
        measureIndex: 3, voiceIndex: 1, elementIndex: 4,
    )
    private static let note = NoteID(
        staff: slot.staff, measureIndex: 3, voiceIndex: 1, elementIndex: 4, noteIndexInChord: 2,
    )
    private static let texts: [ScoreTextID] = [
        .lyric(anchor: slot, verse: 3),
        .staffText(anchor: slot, style: .staffText),
        .staffText(anchor: slot, style: .systemText),
        .harmony(anchor: slot), .rehearsalMark(measureIndex: 17),
    ]

    @Test("every color target and every channel round trips, without UInt8 truncation")
    func colorsRoundTrip() throws {
        let targets = Self.texts.map(SetElementColor.Target.text) + [.note(Self.note)]
        let values: [ScoreColor?] = [
            nil, ScoreColor(red: 0, green: 0, blue: 0, alpha: 0),
            ScoreColor(red: 1, green: 2, blue: 3, alpha: 255),
            ScoreColor(red: -1, green: 256, blue: 1024, alpha: -2),
            ScoreColor(red: Int.min, green: Int.max, blue: 0, alpha: 255),
        ]
        for target in targets {
            for color in values {
                let intent = EditIntent.setElementColor(target: target, color: color)
                #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
            }
        }
    }

    @Test("every placement target and nil/above/below round trips")
    func placementsRoundTrip() throws {
        let targets = Self.texts.map(SetElementPlacement.Target.text) + [.note(Self.note), .chord(Self.slot)]
        let values: [Placement?] = [nil, .above, .below]
        for target in targets {
            for placement in values {
                let intent = EditIntent.setElementPlacement(target: target, placement: placement)
                #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
            }
        }
    }

    @Test("literal bytes pin intent 76 and the text target framing")
    func colorBytes() throws {
        let intent = EditIntent.setElementColor(
            target: .text(.rehearsalMark(measureIndex: 0)),
            color: ScoreColor(red: 1, green: 2, blue: 3, alpha: 4),
        )
        // 23-byte choice: discriminator 76, tag 1, 20-byte payload.
        // Target: text(0), tag 1, rehearsalMark(3), tag 1, measure 0.
        // Payload tags 2/3: hasColor = 1 and an 8-byte RGBA message (signed zig-zag values).
        let expected: [UInt8] = [
            0x17, 0x4C, 0x0A, 0x14,
            0x0A, 0x06, 0x00, 0x0A, 0x03, 0x03, 0x08, 0x00,
            0x10, 0x01, 0x1A, 0x08, 0x08, 0x02, 0x10, 0x04, 0x18, 0x06, 0x20, 0x08,
        ]
        let bytes = EditIntentCodec.encode(intent)
        #expect(Array(bytes) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
    }

    @Test("literal bytes pin intent 77 and below = 1")
    func placementBytes() throws {
        let intent = EditIntent.setElementPlacement(
            target: .text(.rehearsalMark(measureIndex: 0)), placement: .below,
        )
        // 15-byte choice: discriminator 77, tag 1, 12-byte payload.
        // Target is identical to color's text target. Tags 2/3: hasPlacement = 1, below = 1.
        let expected: [UInt8] = [
            0x0F, 0x4D, 0x0A, 0x0C,
            0x0A, 0x06, 0x00, 0x0A, 0x03, 0x03, 0x08, 0x00,
            0x10, 0x01, 0x18, 0x01,
        ]
        #expect(Array(EditIntentCodec.encode(intent)) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
        #expect(EditIntentCodec.encode(.setTextVisible(text: .rehearsalMark(measureIndex: 0), visible: false))[1] == 75)
        #expect(EditIntentCodec.encode(.setLyricSyllables(writes: []))[1] == 74)
    }

    @Test("discriminators 80 and 81 remain note-small and note-play")
    func noteFlagDiscriminators() {
        #expect(EditIntentCodec.encode(.setNoteSmall(at: Self.note, isSmall: true))[1] == 80)
        #expect(EditIntentCodec.encode(.setNotePlay(at: Self.note, play: true))[1] == 81)
    }

    @Test("literal bytes pin intent 82 and the fixed64 offset field layout")
    func offsetBytes() throws {
        let intent = EditIntent.setTextOffset(
            text: .rehearsalMark(measureIndex: 0), offset: ScoreOffset(x: 1, y: -2),
        )
        // 29-byte record: outer length 28, discriminator 82, tag 1, 25-byte payload.
        // Payload: target = rehearsalMark(0) (5 bytes), hasOffset = 1 (2 bytes),
        // x = 1.0 and y = -2.0 as fixed64 little-endian doubles (9 bytes each, tag + 8-byte value).
        let expected: [UInt8] = [
            0x1C, 0x52, 0x0A, 0x19,
            0x0A, 0x03, 0x03, 0x08, 0x00,
            0x10, 0x01,
            0x19, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
            0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0,
        ]
        #expect(Array(EditIntentCodec.encode(intent)) == expected)
        #expect(try EditIntentCodec.decode(.init(expected)) == intent)
        #expect(
            EditIntentCodec
                .encode(.setTextAutoplace(text: .rehearsalMark(measureIndex: 0), autoplace: nil))[1] == 83,
        )
    }

    @Test("presence flags accept any nonzero value and clearing ignores the placeholder")
    func presenceFlags() throws {
        let target = SetElementColor.Target.text(.rehearsalMark(measureIndex: 0))
        var color = SetElementColorIntentWire(target: target, color: ScoreColor(red: 1, green: 2, blue: 3))
        color.hasColor = 2
        #expect(try color.decoded().color == ScoreColor(red: 1, green: 2, blue: 3))
        color.hasColor = 0
        #expect(try color.decoded().color == nil)
        var placement = SetElementPlacementIntentWire(target: .chord(Self.slot), placement: .below)
        placement.hasPlacement = 2
        #expect(try placement.decoded().placement == .below)
        placement.hasPlacement = 0
        placement.placement = 255
        #expect(try placement.decoded().placement == nil)
        placement.hasPlacement = 1
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(255)) { try placement.decoded() }
    }

    @Test("target discriminators remain text 0, note 1, chord 2; unknown targets are refused")
    func targetDiscriminators() throws {
        #expect(ElementColorTargetWire(from: .note(Self.note)).encodeToData()[1] == 1)
        #expect(ElementPlacementTargetWire(from: .note(Self.note)).encodeToData()[1] == 1)
        #expect(ElementPlacementTargetWire(from: .chord(Self.slot)).encodeToData()[1] == 2)
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(2)) {
            try ElementColorTargetWire(decoding: .init([0x01, 0x02]))
        }
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(3)) {
            try ElementPlacementTargetWire(decoding: .init([0x01, 0x03]))
        }
    }
}
