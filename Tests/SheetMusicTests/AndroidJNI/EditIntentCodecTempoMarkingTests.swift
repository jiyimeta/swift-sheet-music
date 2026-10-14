@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// `SetTempoIntentWire`'s text and play tags (6–8) are optional: a number-only marking writes none of them, so its
/// bytes are what they always were and older bytes still decode, and every text edit and play flag round-trips.
@Suite("EditIntentCodec — tempo marking text and play")
struct EditIntentCodecTempoMarkingTests {
    private static let slot = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 2, voiceIndex: 0, elementIndex: 1,
    )

    private static func intent(_ text: SetTempo.Marking.TextEdit = .keep, playsBack: Bool? = nil) -> EditIntent {
        .setTempo(anchor: slot, marking: SetTempo.Marking(beatsPerSecond: 2.4, text: text, playsBack: playsBack))
    }

    private static let cases: [EditIntent] = [
        intent(), intent(.derive), intent(.set("Allegro molto")), intent(.set("")),
        intent(playsBack: false), intent(playsBack: true), intent(.set("a tempo"), playsBack: false),
    ]

    @Test("every text edit and play flag survives a round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("a number-only marking writes no optional tag; each one costs exactly its own bytes")
    func optionalTagsCostOnlyWhenPresent() {
        let plain = EditIntentCodec.encode(Self.intent()).count
        #expect(EditIntentCodec.encode(Self.intent(.derive)).count == plain + 2)
        #expect(EditIntentCodec.encode(Self.intent(.set("x"))).count == plain + 5)
        #expect(EditIntentCodec.encode(Self.intent(playsBack: false)).count == plain + 2)
    }
}
