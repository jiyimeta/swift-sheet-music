import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore

// Note-audition entry points, backing `AndroidPlaybackEngine.playPreview`.
//
// The engine asks what an audition should do and executes the answer; when one supersedes another, how long a
// drum rings, and how long the audio graph has to stay alive for a release are all decided by the shared
// ``NotePreviewPolicy`` — the same code the Apple engine runs. Android reproduced that state machine by hand
// once and it drifted in both directions that were audible; this exists so it cannot drift again.
//
// Only the MIDI messages stay platform-side, and that is deliberate: FluidSynth ends a note with a plain
// note-off where AUMIDISynth needs All Sound Off on a foreign channel, and "keep the graph rendering" means
// holding an Oboe stream open here and not pausing an `AVAudioEngine` there.

/// One coordinator per playback engine. Kotlin owns the lifetime, as it does for a score handle.
let previewPolicyTable = HandleTable<NotePreviewCoordinator>()

/// Packs a voice the way `nativePreviewPolicyEnd` and `nativePreviewPolicySilence` answer: `channel << 8 | pitch`,
/// or -1 for "nothing to silence". Two bytes do not earn a wire type, and the packed-scalar shape matches
/// `nativePitchAndStaffOfNote` next door.
private func packed(_ voice: PreviewVoice?) -> Int64 {
    guard let voice else { return -1 }
    return Int64(voice.channel) << 8 | Int64(voice.pitch)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicyCreate()` call site.
public func nativePreviewPolicyCreate() -> Int64 {
    previewPolicyTable.insert(NotePreviewCoordinator())
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicyRelease(...)` call site. Unknown handles are ignored, so a host may
/// release twice — engine teardown is documented as idempotent.
public func nativePreviewPolicyRelease(policyHandle: Int64) {
    previewPolicyTable.release(policyHandle)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicyBegin(...)` call site. Returns an encoded `PreviewPlan`, or empty
/// `Data` when the handle is unknown — for which the engine's only sane response is to sound nothing, since it
/// would otherwise have no generation to end the note by.
///
/// The channel, pitch and drum flag are the engine's own resolved values (`staffLiveChannel`,
/// `StaffParams.isDrums`) rather than something re-derived here: the engine assigned those channels.
public func nativePreviewPolicyBegin(
    policyHandle: Int64,
    channel: Int32,
    pitch: Int32,
    velocity: Int32,
    isDrum: Bool,
    ringMilliseconds: Int32,
) -> Data {
    guard let coordinator = previewPolicyTable.value(for: policyHandle) else { return Data() }
    let plan = coordinator.begin(
        channel: UInt8(clamping: channel),
        pitch: UInt8(clamping: pitch),
        velocity: UInt8(clamping: velocity),
        isDrum: isDrum,
        ringMilliseconds: Int(ringMilliseconds),
    )
    return PreviewPlanCodec.encode(plan)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicyEnd(...)` call site. Answers the note to silence now that this
/// audition's ring time is up, packed as `channel << 8 | pitch`, or -1 when it was superseded and silencing
/// anything would silence the note that replaced it.
public func nativePreviewPolicyEnd(policyHandle: Int64, generation: Int64) -> Int64 {
    guard let coordinator = previewPolicyTable.value(for: policyHandle) else { return -1 }
    return packed(coordinator.end(generation: UInt64(bitPattern: generation)))
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicySilence(...)` call site. Abandons any audition in progress — for
/// teardown and for re-preparing on another score — and answers the note that has to be silenced for that to be
/// true, packed as `channel << 8 | pitch`, or -1.
public func nativePreviewPolicySilence(policyHandle: Int64) -> Int64 {
    guard let coordinator = previewPolicyTable.value(for: policyHandle) else { return -1 }
    return packed(coordinator.silence())
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeMasterTuningControlChanges(...)` call site. Returns the MIDI Master Tuning RPN
/// messages that retune one channel by `cents` off A4=440, as consecutive `(controller, value)` byte pairs.
///
/// Kotlin held a hand-port of this arithmetic, kept honest by golden assertions on both sides. That is the
/// strategy this call replaces: goldens catch a change that is made twice and made differently, but they say
/// nothing about a change made once — and `playPreview` is what happens then.
public func nativeMasterTuningControlChanges( // swiftlint:disable:this inclusive_language
    cents: Double,
) -> Data {
    var bytes = Data()
    for change in MasterTuning.rpnControlChanges(cents: cents) {
        bytes.append(change.controller)
        bytes.append(change.value)
    }
    return bytes
}
