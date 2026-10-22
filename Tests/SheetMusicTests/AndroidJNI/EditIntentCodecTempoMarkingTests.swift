@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// `SetTempoIntentWire`'s text, play, type and follow tags (6–11) are optional: a number-only marking writes none of
/// them, so its bytes are what they always were and older bytes still decode, and every text edit and play flag
/// round-trips.
@Suite("EditIntentCodec — tempo marking text and play")
struct EditIntentCodecTempoMarkingTests {
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 2, voiceIndex: 0, elementIndex: 1,
    )

    private static func intent(
        _ text: SetTempo.Marking.TextEdit = .keep, playsBack: Bool? = nil, numberEdit: Bool? = nil,
        textType: TempoTextType? = nil, followText: Bool? = nil,
    ) -> EditIntent {
        .setTempo(anchor: slot, marking: SetTempo.Marking(
            beatsPerSecond: 2.4, text: text, playsBack: playsBack, numberEdit: numberEdit, textType: textType,
            followText: followText,
        ))
    }

    private static let cases: [EditIntent] = [
        intent(numberEdit: true), intent(playsBack: false, numberEdit: false),
        intent(), intent(.derive), intent(.set("Allegro molto")), intent(.set("")),
        intent(playsBack: false), intent(playsBack: true), intent(.set("a tempo"), playsBack: false),
        intent(textType: .normal), intent(textType: .aTempo), intent(textType: .tempoPrimo),
        intent(followText: false), intent(followText: true),
        intent(.set("a tempo"), playsBack: true, numberEdit: true, textType: .aTempo, followText: true),
    ]

    @Test("every text edit and play flag survives a round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("a decoder skips a field number it does not declare, which is how an older build reads tags 6–8")
    func unknownFieldIsSkipped() throws {
        let marking = SetTempo.Marking(beatsPerSecond: 2.4)
        var writer = WireFormatWriter()
        SetTempoIntentWire(anchor: Self.slot, marking: marking).encodePayload(into: &writer)
        writer.writeTag(tag: 15, wireType: .varint)
        writer.writeVarint(1)
        var reader = WireFormatReader(data: writer.data)
        let decoded = try SetTempoIntentWire(decodingPayload: &reader).decoded()
        #expect(decoded.anchor == Self.slot)
        #expect(decoded.marking == marking)
    }

    @Test("an unknown text mode, and a set without its text, are refused")
    func malformedTextEditIsRefused() {
        var unknownMode = SetTempoIntentWire(anchor: Self.slot, marking: SetTempo.Marking(beatsPerSecond: 2))
        unknownMode.textMode = 3
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(3)) { try unknownMode.decoded() }
        var missingText = SetTempoIntentWire(anchor: Self.slot, marking: SetTempo.Marking(beatsPerSecond: 2))
        missingText.textMode = 2
        #expect(throws: WireFormatError.unknownTag(tag: 7, wireType: .lengthDelimited)) { try missingText.decoded() }
        var unknownType = SetTempoIntentWire(anchor: Self.slot, marking: SetTempo.Marking(beatsPerSecond: 2))
        unknownType.textType = 3
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(3)) { try unknownType.decoded() }
    }

    @Test("a number-only marking writes no optional tag; each one costs exactly its own bytes")
    func optionalTagsCostOnlyWhenPresent() {
        let plain = EditIntentCodec.encode(Self.intent()).count
        #expect(EditIntentCodec.encode(Self.intent(.derive)).count == plain + 2)
        #expect(EditIntentCodec.encode(Self.intent(.set("x"))).count == plain + 5)
        #expect(EditIntentCodec.encode(Self.intent(playsBack: false)).count == plain + 2)
        #expect(EditIntentCodec.encode(Self.intent(numberEdit: true)).count == plain + 2)
        #expect(EditIntentCodec.encode(Self.intent(textType: .aTempo)).count == plain + 2)
        #expect(EditIntentCodec.encode(Self.intent(followText: false)).count == plain + 2)
    }
}
