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
// Only the MIDI messages stay platform-side, and that is deliberate: Android's SwiftySynth ends a note with a plain
// note-off where AUMIDISynth needs All Sound Off on a foreign channel, and "keep the graph rendering" means
// holding the output stream open here and not pausing an `AVAudioEngine` there.

/// One coordinator per playback engine. Kotlin owns the lifetime, as it does for a score handle.
let previewPolicyTable = HandleTable<NotePreviewCoordinator>()

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
/// `SheetMusicAudioJNI.nativePreviewPolicyBegin(...)` call site. Plans one audition of the notes `voices` packs
/// (`PreviewVoicePairs`: `channel, pitch` a byte each), struck together, each at the pitch wheel `bends` packs for it
/// (`PreviewBendPairs`; empty for all centered) — the plan's `pitchBends` say which wheels to move before the notes
/// start. Returns an encoded `PreviewPlan`, or empty `Data` when the handle is unknown or `voices` names no note — for
/// which the engine's only sane response is to sound nothing, since it would otherwise have no generation to end the
/// notes by.
///
/// The channels, pitches and drum flag are the engine's own resolved values (`staffLiveChannel`,
/// `StaffParams.isDrums`) rather than something re-derived here: the engine assigned those channels. The wheels are
/// the routes' (`nativePreviewRoute`), so the cents-to-wheel arithmetic stays in Swift.
public func nativePreviewPolicyBegin(
    policyHandle: Int64,
    voices: Data,
    bends: Data,
    velocity: Int32,
    isDrum: Bool,
    ringMilliseconds: Int32,
) -> Data {
    guard let coordinator = previewPolicyTable.value(for: policyHandle),
          let plan = coordinator.begin(
              voices: PreviewVoicePairs.decode(voices),
              bends: PreviewBendPairs.decode(bends),
              velocity: UInt8(clamping: velocity),
              isDrum: isDrum,
              ringMilliseconds: Int(ringMilliseconds),
          )
    else { return Data() }
    return PreviewPlanCodec.encode(plan)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicyEnd(...)` call site. Answers the notes to silence now that this
/// audition's ring time is up, packed as `PreviewVoicePairs`, or empty when it was superseded and silencing
/// anything would silence the notes that replaced it.
public func nativePreviewPolicyEnd(policyHandle: Int64, generation: Int64) -> Data {
    guard let coordinator = previewPolicyTable.value(for: policyHandle) else { return Data() }
    return PreviewVoicePairs.encode(coordinator.endVoices(generation: UInt64(bitPattern: generation)))
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativePreviewPolicySilence(...)` call site. Abandons any audition in progress — for
/// teardown and for re-preparing on another score — and answers the notes that have to be silenced for that to be
/// true, packed as `PreviewVoicePairs`, or empty.
public func nativePreviewPolicySilence(policyHandle: Int64) -> Data {
    guard let coordinator = previewPolicyTable.value(for: policyHandle) else { return Data() }
    return PreviewVoicePairs.encode(coordinator.silenceVoices())
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
