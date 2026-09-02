@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Hand-mutated-wire throw tests for the range payloads (intents 35…40, edit-command parity group 2,
/// spec 2026-09-02). Split out of `EditIntentCodecTests.swift` to keep that file under SwiftLint's 400-line budget
/// — see this file for the round-trip and discriminator-pin coverage of the same six intents.
@Suite("EditIntentCodec — range payloads")
struct EditIntentCodecRangeTests {
    /// A `mode` outside `RespellMode`'s cases (0…2) must not decode as one of them.
    @Test func `a respell mode outside the known cases is refused`() {
        let slot = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        var wire = RespellRangeIntentWire(range: VoiceElementRange(start: slot, end: slot), mode: .simplest)
        wire.mode = 7
        let bytes = EditIntentWire.respellRange(wire).encodeToData()
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }

    /// The nested range's unknown-accidental refusal reaches the top: the same guard `setAccidental` has.
    @Test func `an unknown accidental spelling inside a range payload is refused`() {
        let slot = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        var wire = SetAccidentalsInRangeIntentWire(
            range: VoiceElementRange(start: slot, end: slot), accidental: .sharp,
        )
        wire.accidental.raw = "accidentalShasp"
        let bytes = EditIntentWire.setAccidentalsInRange(wire).encodeToData()
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(0)) { try EditIntentCodec.decode(bytes) }
    }
}
