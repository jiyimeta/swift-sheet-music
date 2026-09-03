@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips, discriminator pins and one hand-mutated-wire decode for the visibility payloads (intents 58…61,
/// edit-command parity group 5, spec 2026-09-02). Its own file, like `EditIntentCodecMarkTests`, because
/// `EditIntentCodecTests.swift` is past SwiftLint's 400-line budget already.
@Suite("EditIntentCodec — visibility payloads")
struct EditIntentCodecVisibilityTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
    private static let note = NoteID(
        staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3, noteIndexInChord: 2,
    )

    /// Both values of every flag, on non-zero indices everywhere, so a dropped `visible` byte or a swapped
    /// location mirror cannot survive looking right.
    private static let cases: [EditIntent] = [
        .setElementVisible(at: slot, visible: false), .setElementVisible(at: slot, visible: true),
        .setNoteVisible(at: note, visible: false), .setNoteVisible(at: note, visible: true),
        .setStemVisible(at: slot, visible: false), .setStemVisible(at: slot, visible: true),
        .setBeamVisible(at: slot, visible: false), .setBeamVisible(at: slot, visible: true),
    ]

    @Test("every visibility intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: every payload stays under 128 bytes at
    /// these small indices.
    @Test func `the wire discriminators stay where they were`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let slot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let note = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        #expect(EditIntentCodec.encode(.setElementVisible(at: slot, visible: false))[1] == 58)
        #expect(EditIntentCodec.encode(.setNoteVisible(at: note, visible: false))[1] == 59)
        #expect(EditIntentCodec.encode(.setStemVisible(at: slot, visible: false))[1] == 60)
        #expect(EditIntentCodec.encode(.setBeamVisible(at: slot, visible: false))[1] == 61)
        #expect(EditIntentCodec.encode(.setNoteVisible(at: note, visible: true)).count < 128)
    }

    /// `visible` is a bool on the wire, not an enum: any non-zero byte reads as shown, the `SetLayoutBreakIntentWire
    /// .enabled` rule — pinned so a future "throwing table" refactor does not quietly start refusing old bytes.
    @Test func `a visible byte above one decodes as shown`() throws {
        var wire = SetStemVisibleIntentWire(location: Self.slot, visible: false)
        wire.visible = 7
        let bytes = EditIntentWire.setStemVisible(wire).encodeToData()
        #expect(try EditIntentCodec.decode(bytes) == .setStemVisible(at: Self.slot, visible: true))
    }
}
