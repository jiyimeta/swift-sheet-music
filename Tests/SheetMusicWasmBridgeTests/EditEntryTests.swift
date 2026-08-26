import SheetMusicCore
import SheetMusicEditWire
@testable import SheetMusicWasmBridge
import Testing

@Suite("edit session entry points")
struct EditEntryTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let firstSlot = VoiceElementID(
        staff: staff,
        measureIndex: 0,
        voiceIndex: 0,
        elementIndex: 0,
    )

    private static func loadedHandle() throws -> Int {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        #expect(handle != 0)
        return handle
    }

    @Test("unknown handles do not open sessions")
    func beginRejectsUnknownHandle() {
        #expect(beginEditSession(handle: 999_999) == false)
        #expect(editSessionState(handle: 999_999).active == false)
    }

    @Test("reopening a session drops the undo stack")
    func rebeginDropsUndoStack() throws {
        let handle = try Self.loadedHandle()
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))

        let intent = EditIntent.setChordDuration(at: Self.firstSlot, duration: .eighth)
        let outcome = applyEditIntentBytes(handle: handle, intentBytes: jsBytes(EditIntentCodec.encode(intent)))
        #expect(outcome.accepted)
        #expect(editSessionState(handle: handle).canUndo)

        #expect(beginEditSession(handle: handle))
        let state = editSessionState(handle: handle)
        #expect(state.active)
        #expect(state.canUndo == false)
        #expect(state.canRedo == false)
    }

    @Test("undo and redo publish through the outcome channel")
    func undoRedoRoundTripsFingerprint() throws {
        let handle = try Self.loadedHandle()
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))
        let initial = scoreFingerprint(handle: handle)

        let intent = EditIntent.setChordDuration(at: Self.firstSlot, duration: .eighth)
        #expect(applyEditIntentBytes(handle: handle, intentBytes: jsBytes(EditIntentCodec.encode(intent))).accepted)
        let edited = scoreFingerprint(handle: handle)
        #expect(edited != initial)

        #expect(editUndo(handle: handle).accepted)
        #expect(scoreFingerprint(handle: handle) == initial)
        #expect(editSessionState(handle: handle).canRedo)

        #expect(editRedo(handle: handle).accepted)
        #expect(scoreFingerprint(handle: handle) == edited)
    }

    @Test("empty undo reports a structured refusal")
    func emptyUndoReportsRefusal() throws {
        let handle = try Self.loadedHandle()
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))

        let outcome = editUndo(handle: handle)
        #expect(outcome.accepted == false)
        #expect(outcome.code == "edit.nothingToUndo")
        #expect(outcome.operation == "editUndo")
    }

    @Test("garbage intent bytes report a bridge refusal")
    func garbageBytesAreRefused() throws {
        let handle = try Self.loadedHandle()
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))

        let outcome = applyEditIntentBytes(handle: handle, intentBytes: jsBytes([0xFF, 0x00]))
        #expect(outcome.accepted == false)
        #expect(outcome.code == "bridge.undecodableIntent")
        #expect(outcome.operation == "applyEditIntentBytes")
    }

    @Test("composite intent bytes can be relayed")
    func compositeBytesApply() throws {
        let handle = try Self.loadedHandle()
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))

        let intent = EditIntent.composite([
            .setChordDuration(at: Self.firstSlot, duration: .eighth),
        ])
        let outcome = applyEditIntentBytes(handle: handle, intentBytes: jsBytes(EditIntentCodec.encode(intent)))
        #expect(outcome.accepted)
        #expect(editSessionState(handle: handle).canUndo)
    }

    @Test("nested composite bytes over the codec limit are refused cleanly")
    func tooDeepCompositeBytesAreRefused() throws {
        let handle = try Self.loadedHandle()
        defer { releaseScore(handle: handle) }
        #expect(beginEditSession(handle: handle))

        var intent = EditIntent.delete(at: Self.firstSlot)
        for _ in 0 ..< 9 {
            intent = .composite([intent])
        }
        let outcome = applyEditIntentBytes(handle: handle, intentBytes: jsBytes(EditIntentCodec.encode(intent)))
        #expect(outcome.accepted == false)
    }

    @Test("release tears down an open edit session")
    func releaseTearsDownSession() throws {
        let handle = try Self.loadedHandle()
        #expect(beginEditSession(handle: handle))
        releaseScore(handle: handle)

        #expect(editSessionState(handle: handle).active == false)
        let intent = EditIntent.setChordDuration(at: Self.firstSlot, duration: .eighth)
        let outcome = applyEditIntentBytes(handle: handle, intentBytes: jsBytes(EditIntentCodec.encode(intent)))
        #expect(outcome.accepted == false)
        #expect(outcome.code == "bridge.noSession")
    }
}
