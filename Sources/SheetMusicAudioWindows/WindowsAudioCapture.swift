import CWASAPI
import Foundation
import Synchronization

/// A microphone on Windows: WASAPI capture in shared, event-driven mode, as 32-bit float mono at the rate asked for —
/// Windows mixes the device's channels down and converts its rate (`AUTOCONVERTPCM`) — handed to `samples` packet by
/// packet as the device delivers them, about once per device period (10 ms on most hardware).
///
/// The sibling of the playback output (`AudioDeviceStream`): the same C layer (`CWASAPI`), the same thread in the
/// multimedia scheduler's Pro Audio class waiting on the device's event, and the same supervision of device changes.
///
/// **What reaches `samples`.** Each packet as it came, at the length it came — nothing is cut into frames, scaled or
/// filtered, so a sample is the device's ±1.0 float. A packet the device marked silent arrives as that many zeros. The
/// buffer is valid only during the call, which runs on the capture thread and must return quickly: copy what is kept
/// and leave. A pitch detector's window, a level meter and the like are the host's.
///
/// **Device changes.** Following the default (`deviceID` nil), a new default microphone closes the stream and opens one
/// on it after 250 ms, the interval playback settles a change with. The stream's own device going away
/// (`AUDCLNT_E_DEVICE_INVALIDATED`) closes it too; it then opens again on the default — or, with a `deviceID`, on that
/// device once it is back — trying on every endpoint notification and every two seconds. `notify` says each step:
/// `.lost`, `.removed` when the device itself went away rather than only stopped being the default, and
/// `.recovered(format)`. The calls come on the capture thread.
///
/// **Permission.** `start()` opens the first stream before it returns, so a refusal is the caller's to show:
/// `.accessDenied` when the system's privacy setting keeps the app out, `.noDevice` when there is no microphone.
///
/// One start per object: `stop()` ends it for good, and a host that listens again makes a new one.
///
/// Its types (`Device`, `Format`, `Notice`, `Stats`) and the device list are in `WindowsAudioCapture+Types.swift`.
public final class WindowsAudioCapture: @unchecked Sendable {
    /// The rate every packet is at.
    public let sampleRate: Double
    /// The endpoint the stream opens on, or nil for the default capture device.
    public let deviceID: String?

    private let samples: Samples
    private let notify: Notify
    private let state = Mutex(State())
    private let control = Mutex(Control())
    private let firstAttempt = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)

    /// How long a device change settles before the reopen: playback's (`AudioDeviceStream.rebuildDelay`).
    private static var rebuildDelay: Double {
        AudioDeviceStream.rebuildDelay
    }

    /// How often a stream-less thread tries again without being told anything changed: playback's.
    private static var retryInterval: Duration {
        AudioDeviceStream.retryInterval
    }

    private static let threadName = "SheetMusicAudioWindows capture"

    private struct State {
        var format: Format?
        var stats = Stats()
    }

    private struct Control {
        var exitRequested = false
        var started = false
        var finished = false
        var firstResult: Result<Format, WindowsAudioCaptureError>?
    }

    /// - Parameters:
    ///   - sampleRate: The rate `samples` receives, converted by Windows from the device's own. Above zero.
    ///   - deviceID: A `Device.id` to capture from, or nil for the default capture device, followed as it changes.
    ///   - samples: Each packet, on the capture thread. See the type's discussion.
    ///   - notify: The steps of a device change, on the capture thread.
    public init(
        sampleRate: Double = 44100, deviceID: String? = nil, samples: @escaping Samples,
        notify: @escaping Notify = { _ in },
    ) {
        precondition(sampleRate > 0, "a capture rate must be above zero")
        self.sampleRate = sampleRate
        self.deviceID = deviceID
        self.samples = samples
        self.notify = notify
    }

    /// Starts the capture thread and waits until it has opened and started the first stream, so a refusal throws here.
    /// On a throw the thread has already left, and nothing is captured. The running thread holds the capture until
    /// `stop()`, so a host stops it rather than only dropping it. Called once, from one thread; a later call returns
    /// the first one's format, or throws its error again.
    @discardableResult
    public func start() throws(WindowsAudioCaptureError) -> Format {
        let alreadyStarted = control.withLock { control -> Bool in
            defer { control.started = true }
            return control.started
        }
        if !alreadyStarted {
            let thread = Thread { [self] in
                run()
            }
            thread.name = Self.threadName
            thread.start()
            firstAttempt.wait()
            if case .failure = control.withLock({ $0.firstResult }) {
                // The thread is cleaning up after the failed open; it is gone when the throw arrives.
                exited.wait()
            }
        }
        guard let first = control.withLock({ $0.firstResult }) else {
            throw .device(call: "WindowsAudioCapture.start", hresult: 0)
        }
        return try first.get()
    }

    /// Stops the thread, closes the stream, and returns once the thread has left. Idempotent. Called on the capture
    /// thread itself — a capture released by a host's `samples` or `notify` — it only asks the thread to leave.
    public func stop() {
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

    /// The open stream's format, or nil while none is open (before `start()`, between a loss and its recovery, after
    /// `stop()`).
    public var currentFormat: Format? {
        state.withLock { $0.format }
    }

    public var currentStats: Stats {
        state.withLock { $0.stats }
    }

    private var exitRequested: Bool {
        control.withLock { $0.exitRequested }
    }

    // MARK: The capture thread

    /// What the capture thread keeps between wakes.
    private struct Supervision {
        let clock = ContinuousClock()
        var lastAttempt: ContinuousClock.Instant
        let watcher: OpaquePointer?
    }

    private func run() {
        let proAudio = cwasapi_enter_pro_audio()
        var watcher: OpaquePointer?
        if cwasapi_watch_create(&watcher) != 0 {
            // Without notifications the stream still notices its device going away on its next packet request; only a
            // new default goes unnoticed, and a stream-less wait polls instead.
            watcher = nil
        }
        var supervision = Supervision(lastAttempt: ContinuousClock.now, watcher: watcher)

        let first = openAndStart()
        control.withLock { control in
            switch first {
            case let .success(opened): control.firstResult = .success(opened.format)
            case let .failure(error):
                control.firstResult = .failure(error)
                // Nothing to supervise: `start()` throws, and a later `stop()` has no thread to wait for.
                control.finished = true
            }
        }
        firstAttempt.signal()

        var current: OpenStream?
        if case let .success(opened) = first {
            current = opened
            while !exitRequested {
                if let stream = current {
                    current = service(stream, &supervision)
                } else {
                    current = awaitDevice(&supervision)
                }
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

    private struct OpenStream {
        let stream: OpaquePointer
        let format: Format
    }

    /// One wake with a stream: hand over what arrived, or — when its device went away or a new default replaced it —
    /// close it, let the change settle, and open again. Answers the stream to go on with.
    private func service(_ stream: OpenStream, _ supervision: inout Supervision) -> OpenStream? {
        _ = cwasapi_capture_wait(stream.stream, 200)
        if exitRequested { return stream }

        // The watcher's capture flag covers every endpoint's state as well as the default: only a new default is this
        // stream's business, and only while it follows the default. Taken either way, so it does not pile up.
        let changed = supervision.watcher.map { cwasapi_watch_take_capture_change($0) == 1 } ?? false
        let lost = if changed, deviceID == nil, cwasapi_capture_is_current_default(stream.stream) == 0 {
            true
        } else {
            cwasapi_is_device_lost(drain(stream.stream)) == 1
        }
        guard lost else { return stream }

        let endpoint = cwasapi_capture_endpoint(stream.stream)
        close(stream)
        notify(.lost)
        // Gone, or only no longer the default? Asked at once and again after the settle, as playback asks: Windows can
        // announce the new default before it marks the old device unplugged.
        var removed = Self.isGone(endpoint)
        if removed {
            notify(.removed)
        }
        Thread.sleep(forTimeInterval: Self.rebuildDelay)
        if !removed, Self.isGone(endpoint) {
            removed = true
            notify(.removed)
        }
        cwasapi_endpoint_release(endpoint)
        if let watcher = supervision.watcher {
            _ = cwasapi_watch_take_capture_change(watcher)
        }
        supervision.lastAttempt = supervision.clock.now
        if exitRequested { return nil }
        return reopen()
    }

    /// Whether the device a closed stream captured from is gone. One whose state cannot be read counts as gone.
    private static func isGone(_ endpoint: OpaquePointer?) -> Bool {
        guard let endpoint else { return true }
        return cwasapi_endpoint_is_active(endpoint) == 0
    }

    /// One wake without a stream: wait for an endpoint to appear or the default to change, then try again — and every
    /// `retryInterval` regardless, for an open that failed for a reason no notification reports (the privacy switch).
    private func awaitDevice(_ supervision: inout Supervision) -> OpenStream? {
        var changed = false
        if let watcher = supervision.watcher {
            _ = cwasapi_watch_wait(watcher, 200)
            changed = cwasapi_watch_take_capture_change(watcher) == 1
        } else {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let clock = supervision.clock
        guard !exitRequested, changed || clock.now - supervision.lastAttempt >= Self.retryInterval else { return nil }
        if changed, let watcher = supervision.watcher {
            Thread.sleep(forTimeInterval: Self.rebuildDelay)
            _ = cwasapi_watch_take_capture_change(watcher)
        }
        supervision.lastAttempt = clock.now
        return reopen()
    }

    /// Opens and starts a stream again, counting it as a rebuild. Nil when it will not open or start; the caller waits.
    private func reopen() -> OpenStream? {
        guard case let .success(stream) = openAndStart() else { return nil }
        state.withLock { $0.stats.rebuilds += 1 }
        notify(.recovered(stream.format))
        return stream
    }

    /// Opens the stream on `deviceID` (or the default) at `sampleRate`, and starts it.
    private func openAndStart() -> Result<OpenStream, WindowsAudioCaptureError> {
        var opened: OpaquePointer?
        var format = cwasapi_capture_format()
        let rate = UInt32(sampleRate.rounded())
        let result: Int32 = if let deviceID {
            deviceID.withCString { cwasapi_capture_open(&opened, &format, rate, $0) }
        } else {
            cwasapi_capture_open(&opened, &format, rate, nil)
        }
        guard result == 0, let stream = opened else {
            state.withLock { state in
                state.format = nil
                state.stats.lastOpenFailure = result
            }
            return .failure(WindowsAudioCaptureError(call: "cwasapi_capture_open", hresult: result))
        }
        let started = cwasapi_capture_start(stream)
        guard started == 0 else {
            cwasapi_capture_close(stream)
            state.withLock { state in
                state.format = nil
                state.stats.lastOpenFailure = started
            }
            return .failure(WindowsAudioCaptureError(call: "IAudioClient::Start", hresult: started))
        }
        let opening = Format(
            sampleRate: Double(format.sample_rate), channels: Int(format.channels),
            bufferFrames: Int(format.buffer_frames), latencySeconds: format.latency_seconds,
            periodSeconds: format.period_seconds,
        )
        state.withLock { state in
            state.format = opening
            state.stats.lastOpenFailure = 0
        }
        return .success(OpenStream(stream: stream, format: opening))
    }

    private func close(_ stream: OpenStream) {
        cwasapi_capture_close(stream.stream)
        state.withLock { $0.format = nil }
    }

    /// The zeros a silent packet is handed as. Only the capture thread touches it.
    private var zeros: [Float] = []

    /// Hands `samples` every packet waiting. Returns the first failing HRESULT, or 0.
    private func drain(_ stream: OpaquePointer) -> Int32 {
        while true {
            var frames: UInt32 = 0
            var data: UnsafeMutablePointer<Float>?
            var silent: Int32 = 0
            var discontinuity: Int32 = 0
            let read = cwasapi_capture_next(stream, &frames, &data, &silent, &discontinuity)
            guard read == 0 else { return read }
            guard frames > 0 else { return 0 }
            Self.packetSamples(
                frames: Int(frames), data: UnsafePointer(data), silent: silent != 0, zeros: &zeros, body: samples,
            )
            state.withLock { state in
                state.stats.framesCaptured += Int(frames)
                if silent != 0 {
                    state.stats.silentPackets += 1
                }
                if discontinuity != 0 {
                    state.stats.discontinuities += 1
                }
            }
            let released = cwasapi_capture_release(stream, frames)
            guard released == 0 else { return released }
        }
    }
}
