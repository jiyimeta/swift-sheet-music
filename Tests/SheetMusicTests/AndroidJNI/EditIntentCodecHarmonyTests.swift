@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips, the discriminator pin and hand-mutated-wire refusals for the harmony payload (intent 73,
/// edit-command parity group 7, spec 2026-09-02). Its own file, like `EditIntentCodecMarkTests`, because
/// `EditIntentCodecTests.swift` is past SwiftLint's 400-line budget already.
@Suite("EditIntentCodec — harmony payload")
struct EditIntentCodecHarmonyTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)

    /// All three types, a name with a slash and an accidental, and the removal shape.
    private static let cases: [EditIntent] = [
        .setChordSymbol(at: slot, name: "F#m7b5/A", harmonyType: .standard),
        .setChordSymbol(at: slot, name: "bVII", harmonyType: .roman),
        .setChordSymbol(at: slot, name: "4", harmonyType: .nashville),
        .setChordSymbol(at: slot, name: nil, harmonyType: .standard),
    ]

    @Test("every harmony intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: the payload stays under 128 bytes at
    /// these small indices, so the case index is the second byte.
    @Test func `the wire discriminator is 73`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let slot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let bytes = EditIntentCodec.encode(.setChordSymbol(at: slot, name: nil, harmonyType: .standard))
        #expect(bytes[1] == 73)
        #expect(bytes.count < 128)
    }

    /// A removal has one byte shape: the type is zeroed on encode and comes back `.standard`, the
    /// `SetFermataIntentWire.timeStretch` rule.
    @Test func `a removal zeroes the harmony type`() throws {
        let bytes = EditIntentCodec.encode(.setChordSymbol(at: Self.slot, name: nil, harmonyType: .roman))
        #expect(try EditIntentCodec.decode(bytes) == .setChordSymbol(at: Self.slot, name: nil, harmonyType: .standard))
    }

    @Test func `a harmony type outside the table is refused`() {
        var wire = SetChordSymbolIntentWire(location: Self.slot, name: "C", harmonyType: .standard)
        wire.harmonyType = 3
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(3)) {
            try EditIntentCodec.decode(EditIntentWire.setChordSymbol(wire).encodeToData())
        }
    }
}
