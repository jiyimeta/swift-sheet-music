@preconcurrency import AVFoundation
import Foundation

extension PlaybackEngine {
    /// How the engine treats the process-wide `AVAudioSession`.
    ///
    /// `prepare(score:)` has to leave the session active — a paused-but-prepared engine is what makes
    /// `playPreview` audible the instant a host wants to audition a note, without a session round-trip per tap. What a
    /// host gets to choose is whether that activation is *exclusive*: an active `.playback` session without
    /// `.mixWithOthers` tells iOS this app owns audio output, and iOS interrupts whatever else was playing. For a host
    /// that prepares a score when a screen merely *opens*, that interruption lands long before the user has asked for
    /// any sound.
    public enum AudioSessionPolicy: Sendable {
        /// `prepare(score:)` takes an exclusive `.playback` session. Other apps' audio is interrupted at prepare time.
        case exclusiveOnPrepare

        /// `prepare(score:)` takes a `.playback` session with `.mixWithOthers`, so another app's audio keeps playing
        /// and note previews mix over it; the first `play(...)` drops `.mixWithOthers` and takes the session
        /// exclusively. Interruption happens when the user asks for playback, not when a score is loaded.
        case mixUntilPlay

        /// The engine never *configures* `AVAudioSession`. For a host with its own session requirements — a tuner
        /// holding `.playAndRecord` for live pitch tracking, say — that would otherwise have to undo the engine's
        /// category write after every `prepare`. Interruptions are still observed under this policy; see
        /// `startObservingAudioSessionInterruptions()`.
        case hostManaged
    }

    /// Watch `AVAudioSession.interruptionNotification` so an interruption can't leave `state` claiming `.playing`
    /// while iOS has taken audio output away.
    ///
    /// When another app starts non-mixing playback (the user opens Music while a score plays in the background, say),
    /// iOS deactivates this app's session and the `AVAudioEngine` stops rendering. Nothing about that reaches the
    /// transport on its own: the sequencer / backend is still nominally started and `state` stays `.playing`, so a
    /// host's play button keeps showing "pause" for audio that has already gone silent — and its Now Playing entry
    /// keeps claiming to be playing. Pausing on `.began` puts `state` where the sound already is.
    ///
    /// `.ended` is deliberately NOT handled. Whether to resume — and whether resuming is even wanted when the
    /// interrupter is still playing — is the host's call, and a host that already drives resume from its own
    /// `AVAudioSession` observation (via `play(...)`) keeps working unchanged.
    ///
    /// Registered for every policy, `.hostManaged` included: the invalid `state` is engine-internal, and a host that
    /// owns its session is just as exposed to it. A host that also pauses on `.began` costs nothing — `pause()` is
    /// idempotent.
    ///
    /// There is no macOS counterpart *in this file*, and none is missing: macOS has no `AVAudioSession`, so what
    /// plays the equivalent role there — the engine losing its output from under a running transport — arrives as
    /// `AVAudioEngineConfigurationChange`. See `PlaybackEngine+ConfigurationChange`, which is registered on every
    /// platform including this one.
    func startObservingAudioSessionInterruptions() {
        #if os(iOS) || os(tvOS) || os(watchOS)
            interruptionObserver.token = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main,
            ) { [weak self] notification in
                // Unwrap to the plain `UInt` HERE: `Notification` is not `Sendable`, so handing the notification
                // itself across to the main actor is a "sending risks causing data races" error even though the
                // closure already runs on the main queue.
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                // `queue: .main` guarantees this block runs on the main thread, which for a `@MainActor` type is the
                // main actor — but the closure is `@Sendable` and so nominally non-isolated.
                MainActor.assumeIsolated {
                    self?.handleAudioSessionInterruption(rawType: rawType)
                }
            }
        #endif
    }

    #if os(iOS) || os(tvOS) || os(watchOS)
        private func handleAudioSessionInterruption(rawType: UInt?) {
            guard
                let rawType,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            switch type {
            case .began:
                // `pause()` already no-ops during an offline export, which runs on its own engine and is not what the
                // system interrupted.
                if state == .playing {
                    pause()
                }
                // The exclusive claim is over — iOS handed output to the interrupter and deactivated this session,
                // though the *category* it was carrying survives. Retiring the escalation means the next audition
                // sounds mixing (`prepareAudioSessionForPreview`) rather than re-activating that exclusive category
                // and silencing the interrupter a second time; an explicit `play(...)` still escalates again, because
                // that is the user asking for the route back. `needsAudioSessionReactivation` additionally covers the
                // case where the session was ALREADY mixing when something interrupted it anyway (a phone call
                // interrupts even a mixing app): nothing to retire there, but the session still needs re-activating
                // before the next preview can be heard.
                if audioSessionPolicy == .mixUntilPlay {
                    hasEscalatedAudioSession = false
                    needsAudioSessionReactivation = true
                }
            case .ended:
                break
            @unknown default:
                break
            }
        }
    #endif

    /// Apply the policy's session configuration for `prepare(score:)`.
    ///
    /// Every call is best-effort (`try?`): a host that manages its own session can have iOS reject this category switch
    /// with `AVAudioSessionError.insufficientPriority`, and a hard `try` would throw out of `prepare(score:)` BEFORE
    /// the synths are built, leaving every voice silent while only the already-prepared metronome sounds. The engine
    /// adapts to whatever route the host left active (`connect` uses `format: nil`).
    func configureAudioSessionForPrepare() {
        #if os(iOS) || os(tvOS) || os(watchOS)
            switch audioSessionPolicy {
            case .hostManaged:
                return
            case .exclusiveOnPrepare:
                activateAudioSession(mixWithOthers: false)
            case .mixUntilPlay:
                // A re-prepare after the user has already started playback (a SoundFont hot-swap re-prepares the
                // loaded score) must not demote the session back to mixing — the user is mid-session with playback
                // as the point of it.
                activateAudioSession(mixWithOthers: !hasEscalatedAudioSession)
            }
        #endif
    }

    /// Take the session exclusively because playback is starting. Only `.mixUntilPlay` defers the exclusive claim to
    /// here; the other policies have nothing left to do.
    func escalateAudioSessionForPlayback() {
        #if os(iOS) || os(tvOS) || os(watchOS)
            guard audioSessionPolicy == .mixUntilPlay, !hasEscalatedAudioSession else { return }
            hasEscalatedAudioSession = true
            activateAudioSession(mixWithOthers: false)
        #endif
    }

    /// Put the session on a *mixing* category before an audition sounds, so tapping a note never takes the audio route
    /// away from another app.
    ///
    /// Under `.mixUntilPlay` the exclusive claim belongs to playback and to nothing else. Auditioning a note is not a
    /// claim on the route — the user is reading a score, not asking to be the thing playing — so a preview always
    /// sounds on a mixing session and, in doing so, hands the exclusive claim back. The next `play(...)` re-takes it.
    ///
    /// This has to be a positive step rather than something inferred from an interruption. Two ways to arrive at an
    /// exclusive category with an audition next:
    ///
    /// - The app was interrupted (`.began` sets `needsAudioSessionReactivation`) and iOS deactivated the session. The
    ///   category it was carrying survives the deactivation, and `AVAudioEngine.start()` — which sounding a preview
    ///   does — re-activates the session with it.
    /// - No interruption arrived at all: `play(...)` escalated, the user paused, and only then did another app start
    ///   playing. iOS has no reason to interrupt an app that is not making a sound, so nothing tells the engine its
    ///   exclusive category is now standing on someone else's audio — until a preview re-asserts it and cuts them off.
    ///
    /// Skipped while `.playing`: a preview overlaid on live playback is part of that playback, and demoting the
    /// session under it would be exactly wrong. Skipped when the session is already mixing, so the common note tap
    /// costs nothing — `setCategory` / `setActive` are not free and an audition is meant to be the cheapest thing in
    /// the editor. No-op under the other policies.
    func prepareAudioSessionForPreview() {
        #if os(iOS) || os(tvOS) || os(watchOS)
            guard audioSessionPolicy == .mixUntilPlay, state != .playing else { return }
            guard hasEscalatedAudioSession || needsAudioSessionReactivation else { return }
            hasEscalatedAudioSession = false
            activateAudioSession(mixWithOthers: true)
        #endif
    }

    #if os(iOS) || os(tvOS) || os(watchOS)
        /// Set `.playback` (optionally mixing) and activate, pinning the hardware rate on the way.
        ///
        /// Request a concrete hardware sample rate before activating. iOS's audio HAL can get its system-wide I/O rate
        /// stuck at an odd value (e.g. 24 kHz left over from another app's Bluetooth HFP call), and a session that
        /// simply adopts whatever rate the system hands back then renders the whole graph against that stale clock —
        /// heard as playback that is both sped up and pitched up, and which survives an app relaunch because the wedge
        /// lives in the system audio daemon, not our process. Asking for a definite rate makes `setActive` reconfigure
        /// the HAL toward it, which un-sticks that state without a reboot. 48 kHz is the native rate of modern iOS
        /// output hardware, so on a healthy device this is a no-op (no forced resample); it only takes effect when the
        /// system was parked somewhere unexpected.
        ///
        /// The rate is re-requested on the `.mixUntilPlay` escalation as well, not just at prepare: while mixing, the
        /// app that already owns the route decides the rate, so a preferred rate asked for at prepare time can simply
        /// not have been granted. Going exclusive is the first moment the request can actually take.
        ///
        /// Best-effort throughout: the route may clamp or ignore the rate (the graph still adapts because every
        /// `connect` uses `format: nil`), so a failure here must not abort score preparation.
        private func activateAudioSession(mixWithOthers: Bool) {
            let session = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = mixWithOthers ? [.mixWithOthers] : []
            try? session.setCategory(.playback, mode: .default, options: options)
            try? session.setPreferredSampleRate(48000)
            try? session.setActive(true, options: [])
            // Whatever an interruption left owing is settled: the session is active again, on a category chosen for
            // what the engine is about to do rather than inherited from before the interruption.
            needsAudioSessionReactivation = false
        }
    #endif
}
