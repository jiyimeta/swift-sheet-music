@preconcurrency import AVFoundation
import Foundation

extension PlaybackEngine {
    /// Watch `AVAudioEngineConfigurationChange` so a change of audio route can't leave `state` claiming `.playing`
    /// over silence.
    ///
    /// `AVAudioEngine` **stops itself** when its I/O configuration changes — the user switches the system output
    /// device on a Mac, unplugs headphones on iOS, or a device arrives at a different sample rate. The transport
    /// knows nothing about it: the sequencer is still nominally started and `state` still says `.playing`, so a
    /// host's play button keeps showing "pause" for audio that has already gone silent, and it stays silent until
    /// something re-prepares the graph.
    ///
    /// Registered on **every** Apple platform. This is the macOS counterpart to `+AudioSession`'s interruption
    /// observer — there is no `AVAudioSession` on macOS — but the notification exists on iOS too, where an
    /// interruption and a route change are different events and only the first was handled before.
    ///
    /// Registered against `engine` specifically, so an offline export — which renders on its own `AVAudioEngine`
    /// (`exportEngineSnapshot`) — cannot deliver here.
    func startObservingConfigurationChanges() {
        configurationChangeObserver.token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
        ) { [weak self] _ in
            // `queue: .main` guarantees this block runs on the main thread, which for a `@MainActor` type is the
            // main actor — but the closure is `@Sendable` and so nominally non-isolated. The notification itself is
            // never touched: `Notification` is not `Sendable`, and this one carries nothing we need.
            MainActor.assumeIsolated {
                self?.configurationChangeDidPost()
            }
        }
    }

    /// Schedule one rebuild for however many notifications arrive.
    ///
    /// A single device switch can post more than once (the output unit reconfigures in stages). Restarting per
    /// notification would rebuild the graph two or three times over, each one an audible gap. The first post
    /// schedules a main-actor task and keeps the handle; later posts see it pending and drop. The task clears the
    /// handle *before* it rebuilds, so a genuine second change arriving during a rebuild still earns its own.
    func configurationChangeDidPost() {
        guard pendingConfigurationRestart == nil else { return }
        pendingConfigurationRestart = Task { @MainActor [weak self] in
            guard let self else { return }
            pendingConfigurationRestart = nil
            guard !Task.isCancelled else { return }
            performConfigurationChangeRestart()
        }
    }

    /// Rebuild the graph on the new route, preserving position and mixer state.
    ///
    /// Refused in three cases:
    ///
    /// - `.exporting`: the export renders on its own engine and is not what the system reconfigured; tearing the
    ///   live graph down under it would be gratuitous.
    /// - `.stopped`: nothing is sounding, and the next `play(...)` starts the engine itself and so adopts the new
    ///   route anyway. This is also what makes a notification arriving after `teardown()` harmless — `teardown()`
    ///   leaves `loadedScore` set, so a "has a score" test alone would resurrect a torn-down engine.
    /// - no score prepared: `restartGraphPreservingState()` would no-op regardless.
    ///
    /// A failed rebuild is recorded rather than swallowed, and the transport is corrected — the whole point is that
    /// `state` must not claim `.playing` over silence.
    func performConfigurationChangeRestart() {
        guard state == .playing || state == .paused else { return }
        guard loadedScore != nil else { return }
        do {
            try restartGraphPreservingState()
        } catch {
            recordGraphRestartFailure(error)
        }
    }
}
