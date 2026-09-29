import CWASAPI
import Foundation

/// The WASAPI output and the thread that feeds it.
///
/// `render` runs on that thread, in the multimedia scheduler's Pro Audio class, and fills an interleaved stereo float
/// buffer of the given frame count. The thread waits on the device's event and hands over as much as the shared buffer
/// can take, so it wakes once per device period.
final class AudioDeviceStream: @unchecked Sendable {
    typealias Render = @Sendable (UnsafeMutablePointer<Float>, Int) -> Void

    let sampleRate: Double
    let bufferFrames: Int

    private let stream: OpaquePointer
    private let render: Render
    private let lock = NSLock()
    // Guarded by `lock`.
    private var running = false
    private var loopFinished: DispatchSemaphore?
    private var underrunCount = 0

    init(render: @escaping Render) throws {
        var opened: OpaquePointer?
        var format = cwasapi_format()
        try check(cwasapi_open(&opened, &format), "opening the default output device")
        guard let opened else { throw WindowsAudioError.device(call: "opening the default output device", hresult: -1) }
        stream = opened
        sampleRate = Double(format.sample_rate)
        bufferFrames = Int(format.buffer_frames)
        self.render = render
    }

    deinit {
        stop()
        cwasapi_close(stream)
    }

    /// Seconds of audio the device has played since the stream last started from zero. Holds still while stopped.
    var playedSeconds: Double {
        var seconds = 0.0
        return cwasapi_position_seconds(stream, &seconds) == 0 ? seconds : 0
    }

    /// The latency Windows reports for the stream, in seconds.
    var latencySeconds: Double {
        var seconds = 0.0
        return cwasapi_latency_seconds(stream, &seconds) == 0 ? seconds : 0
    }

    /// Times the device found its buffer empty while running — each one an audible gap.
    var underruns: Int {
        lock.lock()
        defer { lock.unlock() }
        return underrunCount
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start() throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        let finished = DispatchSemaphore(value: 0)
        loopFinished = finished
        lock.unlock()

        // Prime the buffer, so the device starts on audio rather than on an empty buffer.
        fill(countingUnderrun: false)
        do {
            try check(cwasapi_start(stream), "starting the output stream")
        } catch {
            lock.lock()
            running = false
            loopFinished = nil
            lock.unlock()
            throw error
        }
        let thread = Thread { [self] in
            let proAudio = cwasapi_enter_pro_audio()
            while isRunning {
                if cwasapi_wait(stream, 200) == 0 {
                    fill(countingUnderrun: true)
                }
            }
            cwasapi_leave_pro_audio(proAudio)
            finished.signal()
        }
        thread.name = "SheetMusicAudioWindows render"
        thread.start()
    }

    /// Stops the device and waits for the render thread to leave. The clock keeps its position; `reset` zeroes it.
    func stop() {
        lock.lock()
        let finished = loopFinished
        running = false
        loopFinished = nil
        lock.unlock()
        finished?.wait()
        cwasapi_stop(stream)
    }

    /// Drops queued audio and returns the clock to zero. Only while stopped.
    func reset() {
        cwasapi_reset(stream)
    }

    private func fill(countingUnderrun: Bool) {
        var frames: UInt32 = 0
        guard cwasapi_writable_frames(stream, &frames) == 0, frames > 0 else { return }
        if countingUnderrun, Int(frames) == bufferFrames {
            lock.lock()
            underrunCount += 1
            lock.unlock()
        }
        var data: UnsafeMutablePointer<Float>?
        guard cwasapi_get_buffer(stream, frames, &data) == 0, let data else { return }
        render(data, Int(frames))
        cwasapi_release_buffer(stream, frames, 0)
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

private func check(_ hresult: Int32, _ call: String) throws {
    guard hresult == 0 else { throw WindowsAudioError.device(call: call, hresult: hresult) }
}
