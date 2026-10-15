@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// `SetDynamicIntentWire`'s tag 4 carries a dynamic's own text as MuseScore xml text. It is optional: a dynamic written
/// without its own text — every one folino's palette writes — encodes exactly as before, and older bytes still decode.
@Suite("EditIntentCodec — a dynamic's own text")
struct EditIntentCodecDynamicTextTests {
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 2, voiceIndex: 0, elementIndex: 1,
    )

    private static let cases: [EditIntent] = [
        .setDynamic(at: slot, subtype: "p", xmlText: "subito <sym>dynamicPiano</sym>"),
        .setDynamic(at: slot, subtype: "f", xmlText: "più &amp; <b>forte</b>"),
        .setDynamic(at: slot, subtype: "other-dynamics", xmlText: "dolce"),
        .setDynamic(at: slot, subtype: "mf"),
    ]

    @Test("a dynamic's own text survives a round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("without its own text a dynamic writes no tag 4; with one, exactly its bytes")
    func optionalTagCostsOnlyWhenPresent() {
        let plain = EditIntentCodec.encode(.setDynamic(at: Self.slot, subtype: "p")).count
        #expect(EditIntentCodec.encode(.setDynamic(at: Self.slot, subtype: "p", xmlText: nil)).count == plain)
        #expect(EditIntentCodec.encode(.setDynamic(at: Self.slot, subtype: "p", xmlText: "x")).count == plain + 3)
    }

    @Test("a removal carries no text, whatever it was handed")
    func removalCarriesNoText() throws {
        let decoded = try EditIntentCodec.decode(EditIntentCodec.encode(
            .setDynamic(at: Self.slot, subtype: nil, xmlText: "stale"),
        ))
        #expect(decoded == .setDynamic(at: Self.slot, subtype: nil))
    }
}
