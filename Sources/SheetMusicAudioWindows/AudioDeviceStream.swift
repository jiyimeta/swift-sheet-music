import CWASAPI
import Foundation
import Synchronization

/// The WASAPI output, the thread that feeds it, and the supervision that keeps it on the current default device.
///
/// `render` runs on that thread, in the multimedia scheduler's Pro Audio class, and fills an interleaved stereo float
/// buffer whose frame count is always a multiple of `PlaybackCore.chunkFrames`. The thread waits on the device's event
/// and hands over as much as the shared buffer can take in whole chunks, so it wakes once per device period.
///
/// **Device changes.** An `IMMNotificationClient` (`cwasapi_watch_*`) flags a change of the default render device or
/// of any device's state — acted on only when the stream is no longer on the default (`cwasapi_is_current_default`),
/// so a microphone plugged in costs nothing; a `GetCurrentPadding` / `GetBuffer` that answers
/// `AUDCLNT_E_DEVICE_INVALIDATED` or `AUDCLNT_E_RESOURCES_INVALIDATED` means the same. Either way the thread closes
/// the stream, waits 250 ms — the interval the Apple engine debounces an `AVAudioEngineConfigurationChange` burst
/// with — and opens the default device as it now is, at the rate the stream first opened at (`cwasapi_open_at_rate`:
/// Windows converts to the new device's own). Nothing upstream is rebuilt: the synths, their players and their ticks
/// simply do not advance while nothing renders, so playback resumes where it was and the gap is the reopen alone.
/// With no endpoint at all (`E_NOTFOUND`) the thread renders nothing and tries again on the next notification, or
/// every two seconds.
final class AudioDeviceStream: @unchecked Sendable {
    typealias Render = @Sendable (UnsafeMutablePointer<Float>, Int) -> Void

    enum Notice: Sendable {
        /// The stream was closed: the device went away or the default changed.
        case lost
        /// A stream is open again on the current default device.
        case recovered
    }

    typealias Notify = @Sendable (Notice) -> Void

    /// What the output looks like and what it has been through, for `WindowsPlaybackEngine.diagnostics`.
    struct Stats: Sendable {
        /// The rate the stream renders at for its whole life: the default device's mix rate when the stream first
        /// opened, or `fallbackSampleRate` when there was no device then.
        var sampleRate: Double = AudioDeviceStream.fallbackSampleRate
        var bufferFrames = 0
        var latencySeconds = 0.0
        var underruns = 0
        var hasDevice = false
        /// Streams reopened after one was closed, or opened after starting with no device.
        var rebuilds = 0
        /// Close to reopen, for the last rebuild.
        var lastRebuildSeconds: Double?
        /// The HRESULT of the last failed open, 0 when the last open succeeded.
        var lastOpenFailure: Int32 = 0
    }

    /// The rate the synths are made at when the stream starts with no device to ask.
    static let fallbackSampleRate = 48000.0

    /// How long a device change settles before the reopen.
    private static let rebuildDelay = 0.25

    /// How often a stream-less thread tries the default device without being told anything changed.
    private static let retryInterval = Duration.seconds(2)

    private struct Control {
        var exitRequested = false
        var faultRequested = false
        var started = false
        var finished = false
    }

    private let render: Render
    private let notify: Notify
    private let stats = Mutex(Stats())
    private let control = Mutex(Control())
    private let firstAttempt = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)

    init(render: @escaping Render, notify: @escaping Notify) {
        self.render = render
        self.notify = notify
    }

    /// Starts the output thread and waits until it has tried the default device once, so `sampleRate` is settled when
    /// this returns. Does not fail: with no device the thread keeps waiting for one.
    func start() {
        let alreadyStarted = control.withLock { control -> Bool in
            defer { control.started = true }
            return control.started
        }
        guard !alreadyStarted else { return }
        let thread = Thread { [self] in
            run()
        }
        thread.name = Self.threadName
        thread.start()
        firstAttempt.wait()
    }

    /// Stops the thread, closes the stream, and returns once the thread has left. Idempotent. Called on the output
    /// thread itself — an engine released by a host's `onEvent` handler — it only asks the thread to leave.
    func stop() {
        let wait = control.withLock { control -> Bool in
            guard control.started, !control.finished else { return false }
            control.exitRequested = true
            control.finished = true
            return true
        }
        if wait, Thread.current.name != Self.threadName {
            exited.wait()
        }
    }

    private static let threadName = "SheetMusicAudioWindows output"

    var sampleRate: Double {
        stats.withLock { $0.sampleRate }
    }

    var currentStats: Stats {
        stats.withLock { $0 }
    }

    /// Makes the next buffer request fail with `AUDCLNT_E_DEVICE_INVALIDATED` once — only when the process runs with
    /// `SSM_WASAPI_FAIL_ONCE=invalidated` (`cwasapi_arm_fault`). For the playback probe.
    func requestFault() {
        control.withLock { $0.faultRequested = true }
    }

    private var exitRequested: Bool {
        control.withLock { $0.exitRequested }
    }

    // MARK: The output thread

    private struct OpenStream {
        let stream: OpaquePointer
        let bufferFrames: Int
    }

    /// What the output thread keeps between wakes.
    private struct Supervision {
        let clock = ContinuousClock()
        /// The rate every reopen asks for: the one the stream first opened at.
        var rate: UInt32 = 0
        /// When the last stream was lost, for the rebuild's duration.
        var lostAt: ContinuousClock.Instant?
        var lastAttempt: ContinuousClock.Instant
        let watcher: OpaquePointer?
    }

    private func run() {
        let proAudio = cwasapi_enter_pro_audio()
        var watcher: OpaquePointer?
        if cwasapi_watch_create(&watcher) != 0 {
            // Without notifications the stream still notices an invalidated device on its next buffer request; only a
            // change of default goes unnoticed, and a device-less start polls instead.
            watcher = nil
        }
        var supervision = Supervision(lastAttempt: ContinuousClock.now, watcher: watcher)
        var current = startFirstStream(&supervision)

        while !exitRequested {
            if let stream = current {
                current = service(stream, &supervision)
            } else {
                current = awaitDevice(&supervision)
            }
        }

        if let current {
            close(current)
        }
        if let watcher {
            cwasapi_watch_destroy(watcher)
        }
        cwasapi_leave_pro_audio(proAudio)
        exited.signal()
    }

    /// Opens the default device at its own rate — which becomes the stream's rate for good — lets `start()` return,
    /// and starts the stream.
    private func startFirstStream(_ supervision: inout Supervision) -> OpenStream? {
        let first = open(rate: 0)
        supervision.rate = UInt32(stats.withLock { $0.sampleRate })
        firstAttempt.signal()
        guard let first else { return nil }
        guard begin(first) else {
            close(first)
            return nil
        }
        // The probe's fault hook is not armed here: only `requestFault()` arms it. Armed at start, it fired on the
        // first wake after `prepare(score:)` and left the device closed for the 250 ms rebuild the probe then read.
        return first
    }

    /// One wake with a stream: feed it, or — when its device went away or is no longer the default — close it, let
    /// the change settle, and reopen on the default device as it now is. Answers the stream to go on with.
    private func service(_ stream: OpenStream, _ supervision: inout Supervision) -> OpenStream? {
        _ = cwasapi_wait(stream.stream, 200)
        if exitRequested { return stream }
        let faultRequested = control.withLock { control -> Bool in
            defer { control.faultRequested = false }
            return control.faultRequested
        }
        if faultRequested {
            cwasapi_arm_fault()
        }

        // The watcher's flag covers every endpoint, capture ones and other outputs included: only a new default is this
        // stream's business. Its own device going away shows up as an invalidated buffer request instead.
        var lost = false
        if let watcher = supervision.watcher, cwasapi_watch_take_change(watcher) == 1,
           cwasapi_is_current_default(stream.stream) == 0
        {
            lost = true
        } else {
            lost = cwasapi_is_device_lost(fill(stream, countingUnderrun: true)) == 1
        }
        guard lost else { return stream }

        let began = supervision.clock.now
        close(stream)
        notify(.lost)
        Thread.sleep(forTimeInterval: Self.rebuildDelay)
        if let watcher = supervision.watcher {
            _ = cwasapi_watch_take_change(watcher)
        }
        supervision.lostAt = began
        supervision.lastAttempt = supervision.clock.now
        if exitRequested { return nil }
        return reopen(rate: supervision.rate, lostAt: began, clock: supervision.clock)
    }

    /// One wake without a stream: wait for an endpoint to appear or the default to change, then try again — and every
    /// `retryInterval` regardless, for an open that failed for a reason no notification will report.
    private func awaitDevice(_ supervision: inout Supervision) -> OpenStream? {
        var changed = false
        if let watcher = supervision.watcher {
            _ = cwasapi_watch_wait(watcher, 200)
            changed = cwasapi_watch_take_change(watcher) == 1
        } else {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let clock = supervision.clock
        guard !exitRequested, changed || clock.now - supervision.lastAttempt >= Self.retryInterval else { return nil }
        if changed, let watcher = supervision.watcher {
            Thread.sleep(forTimeInterval: Self.rebuildDelay)
            _ = cwasapi_watch_take_change(watcher)
        }
        supervision.lastAttempt = clock.now
        return reopen(rate: supervision.rate, lostAt: supervision.lostAt ?? clock.now, clock: clock)
    }

    /// Opens and starts a stream on the current default device at `rate`, counting it as a rebuild. `nil` when there
    /// is no device (the caller waits for one) or it will not start.
    private func reopen(rate: UInt32, lostAt: ContinuousClock.Instant, clock: ContinuousClock) -> OpenStream? {
        guard let stream = open(rate: rate) else { return nil }
        guard begin(stream) else {
            close(stream)
            return nil
        }
        let elapsed = clock.now - lostAt
        stats.withLock { stats in
            stats.rebuilds += 1
            stats.lastRebuildSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) * 1e-18
        }
        notify(.recovered)
        return stream
    }

    /// Opens the default device at `rate` (0: at its own mix rate, which then becomes the stream's rate for good).
    private func open(rate: UInt32) -> OpenStream? {
        var opened: OpaquePointer?
        var format = cwasapi_format()
        let result = cwasapi_open_at_rate(&opened, &format, rate)
        guard result == 0, let opened else {
            stats.withLock { stats in
                stats.hasDevice = false
                stats.lastOpenFailure = result
            }
            return nil
        }
        var latency = 0.0
        if cwasapi_latency_seconds(opened, &latency) != 0 {
            latency = 0
        }
        stats.withLock { stats in
            if rate == 0 {
                stats.sampleRate = Double(format.sample_rate)
            }
            stats.bufferFrames = Int(format.buffer_frames)
            stats.latencySeconds = latency
            stats.hasDevice = true
            stats.lastOpenFailure = 0
        }
        return OpenStream(stream: opened, bufferFrames: Int(format.buffer_frames))
    }

    /// Primes the buffer, so the device starts on audio rather than on an empty buffer, and starts the stream.
    private func begin(_ stream: OpenStream) -> Bool {
        let primed = fill(stream, countingUnderrun: false)
        guard cwasapi_is_device_lost(primed) == 0 else { return false }
        return cwasapi_start(stream.stream) == 0
    }

    private func close(_ stream: OpenStream) {
        cwasapi_close(stream.stream)
        stats.withLock { $0.hasDevice = false }
    }

    /// Hands the device as many whole chunks as it can take. Returns the first failing HRESULT, or 0.
    private func fill(_ stream: OpenStream, countingUnderrun: Bool) -> Int32 {
        var writable: UInt32 = 0
        let asked = cwasapi_writable_frames(stream.stream, &writable)
        guard asked == 0 else { return asked }
        let chunk = PlaybackCore.chunkFrames
        let frames = Int(writable) - Int(writable) % chunk
        guard frames > 0 else { return 0 }
        if countingUnderrun, Int(writable) == stream.bufferFrames {
            // The device found nothing queued: an audible gap.
            stats.withLock { $0.underruns += 1 }
        }
        var data: UnsafeMutablePointer<Float>?
        let got = cwasapi_get_buffer(stream.stream, UInt32(frames), &data)
        guard got == 0, let data else { return got }
        render(data, frames)
        return cwasapi_release_buffer(stream.stream, UInt32(frames), 0)
    }
}

/// Why the Windows audio backend could not do what was asked.
public enum WindowsAudioError: Error, CustomStringConvertible {
    /// A WASAPI call failed; `hresult` is its HRESULT.
    case device(call: String, hresult: Int32)
    /// FluidSynth refused: `what` names the step.
    case synth(String)

    public var description: String {
        switch self {
        case let .device(call, hresult):
            "\(call) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))"
        case let .synth(what):
            "FluidSynth: \(what)"
        }
    }
}
