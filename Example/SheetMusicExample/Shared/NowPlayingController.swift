import Foundation
import MediaPlayer
import SheetMusic
import SheetMusicAudio

#if canImport(UIKit)
    import AVFoundation
    import UIKit
#endif

/// App-side NowPlaying / lock-screen / Control Center integration on
/// top of `SheetMusicAudio.PlaybackEngine`. The library exposes
/// observable transport state plus the behavioural tweaks that
/// `MPNowPlayingInfoCenter` cares about (`pause()` pauses the
/// `AVAudioEngine` so Control Center doesn't see "audio still
/// active"; `currentTimeSeconds` folds A-B loop wrap so the
/// scrubber stays in `[0, totalTimeSeconds]`). This controller
/// glues those properties into the platform's NowPlaying surface.
///
/// Owned by the iOS / macOS `ContentView`; recreated when the engine
/// is recreated (rare — the engine is process-wide in the example).
@MainActor
final class NowPlayingController {
    private let engine: PlaybackEngine
    private var refreshTimer: Timer?
    private var currentScore: Score?
    private var currentTitle = "Sheet Music"
    private var currentArtist = ""

    init(engine: PlaybackEngine) {
        self.engine = engine
        configureAudioSession()
        wireRemoteCommands()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    /// Replace the displayed title / composer. Call from the
    /// host view whenever the loaded score changes — values default
    /// to placeholders when nil so the lock-screen card never
    /// shows an empty title.
    func update(score: Score?) {
        currentScore = score
        currentTitle = score?.metaTags["workTitle"]?.nonEmpty ?? "Sheet Music"
        currentArtist = score?.metaTags["composer"]?.nonEmpty ?? ""
        refreshNowPlayingInfo()
    }

    /// Push the latest transport state to `MPNowPlayingInfoCenter`.
    /// Call from the host view on every meaningful change
    /// (`engine.state`, `currentCursor`, `currentTimeSeconds` /
    /// `totalTimeSeconds`). A 1 Hz timer also fires while playing
    /// so the elapsed-time scrubber stays in sync without flooding
    /// the system on every audio frame.
    func refreshNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle
        info[MPMediaItemPropertyArtist] = currentArtist
        info[MPMediaItemPropertyPlaybackDuration] = engine.totalTimeSeconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentTimeSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.state == .playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        manageRefreshTimer()
    }

    // MARK: - Private

    private func configureAudioSession() {
        #if canImport(UIKit)
            let session = AVAudioSession.sharedInstance()
            do {
                // .playback + active session is what makes the OS treat
                // us as a media app — required for the lock-screen card
                // and Control Center transport to actually show our info.
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            } catch {
                // Audio session config failure isn't fatal — playback
                // still works, just without NowPlaying integration.
                // Surface in the console for debugging.
                print("NowPlaying: AVAudioSession config failed: \(error)")
            }
            UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    private func wireRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            guard let self, let score = currentScore else { return .commandFailed }
            // Resume from cursor when present, else from start. The
            // engine itself is the source of truth for `from` — we
            // don't second-guess it here.
            engine.play(from: engine.currentCursor, in: score)
            return .success
        }

        cc.pauseCommand.addTarget { [weak self] _ in
            self?.engine.pause()
            return .success
        }

        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let score = currentScore else { return .commandFailed }
            switch engine.state {
            case .playing: engine.pause()
            case .paused, .stopped: engine.play(from: engine.currentCursor, in: score)
            case .exporting: return .commandFailed
            }
            return .success
        }

        cc.stopCommand.addTarget { [weak self] _ in
            self?.engine.stop()
            return .success
        }

        cc.skipForwardCommand.preferredIntervals = [5]
        cc.skipForwardCommand.addTarget { [weak self] event in
            let dt = (event as? MPSkipIntervalCommandEvent)?.interval ?? 5
            self?.engine.skip(by: dt)
            return .success
        }

        cc.skipBackwardCommand.preferredIntervals = [5]
        cc.skipBackwardCommand.addTarget { [weak self] event in
            let dt = (event as? MPSkipIntervalCommandEvent)?.interval ?? 5
            self?.engine.skip(by: -dt)
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            else { return .commandFailed }
            engine.seek(toTimeSeconds: pos)
            return .success
        }
    }

    private func manageRefreshTimer() {
        let needsTimer = engine.state == .playing
        if needsTimer, refreshTimer == nil {
            // 1 Hz is plenty — the system's scrubber interpolates
            // between updates and we don't want to churn IPC.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pushElapsedTime() }
            }
        } else if !needsTimer, let timer = refreshTimer {
            timer.invalidate()
            refreshTimer = nil
        }
    }

    private func pushElapsedTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentTimeSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.state == .playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension String {
    /// Returns nil for empty / whitespace-only strings; useful for
    /// `?? "placeholder"` fallbacks on metaTag lookups.
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
