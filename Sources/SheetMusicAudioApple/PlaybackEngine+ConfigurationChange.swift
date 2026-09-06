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

    /// Trailing-debounce window collapsing a burst of `AVAudioEngineConfigurationChange` posts into one rebuild.
    ///
    /// A single device switch reconfigures the output unit in stages and posts more than once — but tens to
    /// hundreds of milliseconds apart, not back-to-back. A scheme that only dropped a post arriving WHILE a
    /// rebuild was already scheduled bought nothing against that gap: by the time the second post lands the first
    /// has already fired, so every post in the burst bought its own `prepare` + transport re-seat — several
    /// audible gaps and several backward cursor re-seats for what the user experienced as one switch. `internal`
    /// so a test can reason about it without hardcoding the literal twice.
    static let configurationChangeDebounceInterval: Duration = .milliseconds(250)

    /// Debounce a burst of notifications into one rebuild, fired 250 ms after the LAST post rather than the
    /// first: every post cancels whatever rebuild is still pending and schedules a fresh one.
    ///
    /// Deliberately does no other work beyond scheduling. This can run reentrantly mid-`prepare` (a rebuild's own
    /// `prepare(score:)` posts this same notification, delivered synchronously — see
    /// `PlaybackEngine.isRebuildingForConfigurationChange`, which this checks first and which drops that
    /// reentrant post), so anything heavier than scheduling a `Task` here would reenter the graph mutation.
    func configurationChangeDidPost() {
        guard !isRebuildingForConfigurationChange else { return }
        pendingConfigurationRestart?.cancel()
        pendingConfigurationRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.configurationChangeDebounceInterval)
            guard let self, !Task.isCancelled else { return }
            pendingConfigurationRestart = nil
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
        // Set for the duration of the rebuild so a reentrant post from our OWN `prepare(score:)` — delivered
        // synchronously, see `isRebuildingForConfigurationChange` — is dropped rather than scheduling a rebuild of
        // this rebuild.
        isRebuildingForConfigurationChange = true
        defer { isRebuildingForConfigurationChange = false }
        do {
            try restartGraphPreservingState()
        } catch {
            recordGraphRestartFailure(error)
        }
    }
}
