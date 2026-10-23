@preconcurrency import AVFoundation
#if os(macOS)
    import CoreAudio
#endif
import Foundation

extension PlaybackEngine {
    /// How long the audio graph keeps running once nothing is sounding.
    ///
    /// The engine *parks* an idle graph — `AVAudioEngine.pause()` — so that it stops holding the output device: on
    /// iOS a running graph is "audio active" to Control Center, which then overrides the host's paused Now Playing
    /// state, and on every platform a running graph keeps the device (and, on macOS, the system's idle sleep) awake.
    ///
    /// Parking costs a restart, and on a Bluetooth output that restart is expensive. `AVAudioEngine.start()` waits for
    /// the device to resume streaming, which on AirPods blocks the calling (main) thread for 0.2–0.55 s against ~30 ms
    /// on built-in speakers (measured on macOS 27, 2026-10-22) — a lag before every preview or play that follows a
    /// pause, and the frame that draws whatever the user just entered waits behind it. Keeping the graph warm for a
    /// while after the last sound means the next one needs no restart at all.
    ///
    /// The grace always counts from the last *sound* — a transport that played, a preview that rang. Pausing a
    /// transport that was not playing (a host parking the graph right after `prepare(score:)`) is not a sound and
    /// parks at once, so loading a score never holds the output device on its own.
    public enum IdleParkPolicy: Sendable, Equatable {
        /// Park as soon as nothing sounds (a software-synth preview still waits out its release tail first). The
        /// default, and the only choice on iOS, where a warm graph flips Control Center to "playing".
        case immediate

        /// Keep the graph running for `grace` after the last sound, whatever the output device.
        case deferred(grace: Duration)

        /// `deferred(grace:)` while the output is a Bluetooth device, `immediate` otherwise — the restart is only
        /// expensive over Bluetooth, so holding a wired or built-in output buys nothing. The output is read at each
        /// idle moment, so connecting or disconnecting headphones takes effect at the next one.
        case deferredOnBluetoothOutput(grace: Duration)
    }

    /// Resume the graph for a preview about to sound. A graph that was parked — or about to be — now owes its park
    /// back once the preview ends, unless a playing transport owns it.
    func wakeGraphForPreview() {
        let wasParked = !engine.isRunning || pendingIdlePark != nil
        cancelPendingIdlePark()
        if !engine.isRunning {
            try? engine.start()
        }
        if wasParked, state != .playing {
            graphOwesIdlePark = true
        }
    }

    /// Resume the graph for transport playback. `throws` what `AVAudioEngine.start()` throws, as the call it replaces
    /// did.
    func wakeGraphForPlayback() throws {
        cancelPendingIdlePark()
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Something stopped sounding: park the graph after the policy's grace, or after `minimumDelay` when that is
    /// longer — the software synth's release tail must render out before a pause freezes it. A grace of zero parks
    /// synchronously, which is what keeps `.immediate` exactly the behavior from before the policy existed.
    func requestIdlePark(minimumDelay: Duration = .zero) {
        guard graphOwesIdlePark, state != .playing else { return }
        cancelPendingIdlePark()
        let delay = max(minimumDelay, idleParkGrace)
        guard delay > .zero else {
            parkIdleGraph()
            return
        }
        pendingIdlePark = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            firePendingIdlePark()
        }
    }

    /// A transport stopped. One that was playing has just sounded, so the graph stays warm for the grace. One that
    /// was not — a host parking the graph after `prepare(score:)`, a score swap re-seating a paused transport — parks
    /// at once, unless a park from an earlier sound is already pending, which keeps its own deadline.
    func requestIdleParkAfterTransportStop(wasPlaying: Bool) {
        graphOwesIdlePark = true
        if wasPlaying {
            requestIdlePark()
        } else if pendingIdlePark == nil {
            parkIdleGraph()
        }
    }

    /// Forget any owed or pending park — `prepare(score:)` leaves the graph running on purpose, `teardown()` has just
    /// stopped it outright, and a graph rebuild decides its park afresh.
    func resetIdlePark() {
        cancelPendingIdlePark()
        graphOwesIdlePark = false
    }

    /// `true` while a park is scheduled but has not run. Not host-facing; lets a test tell a warm graph waiting out
    /// its grace from one nobody will park.
    var isIdleParkPending: Bool {
        pendingIdlePark != nil
    }

    /// Run the pending park now instead of at the end of its grace, exactly as the timer would. Test-only: the grace
    /// is wall-clock, and a test should not sleep through it.
    func firePendingIdleParkForTesting() {
        guard pendingIdlePark != nil else { return }
        cancelPendingIdlePark()
        firePendingIdlePark()
    }

    private func firePendingIdlePark() {
        pendingIdlePark = nil
        // A preview that began during the grace cancelled this park; one still sounding at the deadline owns the
        // park through its own drain.
        guard !isPreviewSounding else { return }
        parkIdleGraph()
    }

    private func parkIdleGraph() {
        guard graphOwesIdlePark, state != .playing else { return }
        graphOwesIdlePark = false
        if engine.isRunning {
            engine.pause()
        }
    }

    private func cancelPendingIdlePark() {
        pendingIdlePark?.cancel()
        pendingIdlePark = nil
    }

    private var idleParkGrace: Duration {
        switch idleParkPolicy {
        case .immediate:
            .zero
        case let .deferred(grace):
            grace
        case let .deferredOnBluetoothOutput(grace):
            isOutputBluetooth ? grace : .zero
        }
    }

    /// Whether the graph's output is a Bluetooth device right now. `internal` so a test can check it reads the device
    /// the graph actually plays through.
    var isOutputBluetooth: Bool {
        #if os(macOS)
            guard let unit = engine.outputNode.audioUnit else { return false }
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioUnitGetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size,
            ) == noErr else { return false }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain,
            )
            var transport: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
            return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        #elseif os(iOS) || os(tvOS) || os(watchOS)
            let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
            return AVAudioSession.sharedInstance().currentRoute.outputs.contains { bluetooth.contains($0.portType) }
        #else
            return false
        #endif
    }
}
