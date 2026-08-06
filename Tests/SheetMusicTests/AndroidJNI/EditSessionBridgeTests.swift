import Foundation
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Testing

/// Drives the JNI entry points as plain Swift functions on the host — the same code the device calls, minus the
/// Kotlin hop. Handles are created through the shipped `nativeLoadScore` so the table's lifetime rules are exercised
/// too.
@Suite("EditSessionBridge")
struct EditSessionBridgeTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func loadedHandle() throws -> Int64 {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let handle = try nativeLoadScore(bytes: Data(contentsOf: url))
        #expect(handle != 0)
        return handle
    }

    /// `midi01.mscx` measure 0 is `KeySig(0)`, `TimeSig(1)`, then quarter-note chords at element indices 2-5 (see
    /// `EditReplayScript`'s doc comment) — there is no rest anywhere in the fixture, so `.inputNote` (which requires
    /// an existing rest at its target) would be refused at any slot. `.setChordDuration` on an already-existing
    /// chord exercises the same round-trip (decode -> apply -> publish) without that precondition.
    private static let chordSlot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

    @Test("an intent applied through the bridge moves the fingerprint")
    func applyMovesFingerprint() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        let before = nativeScoreFingerprint(scoreHandle: handle)
        let intent = EditIntent.setChordDuration(at: Self.chordSlot, duration: .eighth)
        #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)))
        #expect(nativeScoreFingerprint(scoreHandle: handle) != before)
        nativeEndEditSession(scoreHandle: handle)
    }

    @Test("undo through the bridge restores the fingerprint")
    func undoRestores() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        let before = nativeScoreFingerprint(scoreHandle: handle)
        let intent = EditIntent.setChordDuration(at: Self.chordSlot, duration: .eighth)
        _ = nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent))
        #expect(nativeEditUndo(scoreHandle: handle))
        #expect(nativeScoreFingerprint(scoreHandle: handle) == before)
        nativeEndEditSession(scoreHandle: handle)
    }

    @Test("applying without a session reports false")
    func applyWithoutSession() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        let intent = EditIntent.delete(at: VoiceElementID(
            staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        ))
        #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)) == false)
    }

    @Test("an unknown handle is refused rather than crashing")
    func unknownHandleIsRefused() {
        #expect(nativeBeginEditSession(scoreHandle: 999_999) == false)
        #expect(nativeScoreFingerprint(scoreHandle: 999_999) == 0)
        nativeEndEditSession(scoreHandle: 999_999)
    }

    @Test("garbage intent bytes are refused")
    func garbageIntentIsRefused() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: Data([0xFF, 0x00])) == false)
        nativeEndEditSession(scoreHandle: handle)
    }

    @Test("the version stamp matches the engine's")
    func versionStampMatches() {
        #expect(nativeEngineVersionStamp() == SheetMusicEngine.versionStamp)
    }
}
