import Foundation
@testable import SheetMusicAudioWindows
import Synchronization
import Testing

/// The microphone (`WindowsAudioCapture`). What needs no microphone runs everywhere: the errors an HRESULT maps to, a
/// silent packet read as zeros, the device list, and the refusals — no capture endpoint at all, an id that names none.
/// A second of real capture runs only on a machine that has a microphone (folino-win; folino-qa has none).
struct WindowsAudioCaptureTests {
    /// The frames `samples` saw, from the capture thread.
    private final class FrameCount: Sendable {
        private let count = Mutex(0)

        func add(_ frames: Int) {
            count.withLock { $0 += frames }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    private static let devices: [WindowsAudioCapture.Device]? = try? WindowsAudioCapture.inputDevices()
    static let hasMicrophone = devices.map { !$0.isEmpty } ?? false
    static let hasNoMicrophone = devices.map(\.isEmpty) ?? false

    @Test
    func `an HRESULT reads as the privacy setting (E_ACCESSDENIED), no device (E_NOTFOUND) or the call's own`() {
        let accessDenied = Int32(bitPattern: 0x8007_0005)
        let notFound = Int32(bitPattern: 0x8007_0490)
        let unsupportedFormat = Int32(bitPattern: 0x8889_0008)
        #expect(WindowsAudioCaptureError(call: "IMMDevice::Activate", hresult: accessDenied) == .accessDenied)
        #expect(WindowsAudioCaptureError(call: "GetDefaultAudioEndpoint", hresult: notFound) == .noDevice)
        #expect(
            WindowsAudioCaptureError(call: "IAudioClient::Initialize", hresult: unsupportedFormat)
                == .device(call: "IAudioClient::Initialize", hresult: unsupportedFormat),
        )
        #expect(
            WindowsAudioCaptureError.device(call: "IAudioClient::Initialize", hresult: unsupportedFormat).description
                == "IAudioClient::Initialize failed (HRESULT 0x88890008)",
        )
    }

    @Test
    func `a packet the device marked silent reads as zeros, whatever its buffer holds`() {
        let garbage: [Float] = [0.5, -0.25, 1, -1]
        var zeros: [Float] = []
        var seen: [Float] = []
        garbage.withUnsafeBufferPointer { buffer in
            WindowsAudioCapture.packetSamples(frames: 4, data: buffer.baseAddress, silent: true, zeros: &zeros) {
                seen = Array($0)
            }
        }
        #expect(seen == [0, 0, 0, 0])
    }

    @Test
    func `a packet with samples is handed over as it came, at its own length`() {
        let packet: [Float] = [0.5, -0.25, 1, -1, 0.125]
        var zeros: [Float] = []
        var seen: [Float] = []
        packet.withUnsafeBufferPointer { buffer in
            WindowsAudioCapture.packetSamples(frames: 5, data: buffer.baseAddress, silent: false, zeros: &zeros) {
                seen = Array($0)
            }
        }
        #expect(seen == packet)
        #expect(zeros.isEmpty)
    }

    @Test
    func `a silent packet longer than the last one gets that many zeros, and a shorter one no more than its own`() {
        var zeros: [Float] = []
        var lengths: [Int] = []
        for frames in [3, 441, 160] {
            WindowsAudioCapture.packetSamples(frames: frames, data: nil, silent: true, zeros: &zeros) { samples in
                #expect(samples.allSatisfy { $0 == 0 })
                lengths.append(samples.count)
            }
        }
        #expect(lengths == [3, 441, 160])
    }

    @Test
    func `the device list reads, its ids are distinct, and at most one entry is the default`() throws {
        let devices = try WindowsAudioCapture.inputDevices()
        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(devices.count(where: \.isDefault) <= 1)
        #expect(devices.allSatisfy { !$0.id.isEmpty })
    }

    @Test(.enabled(if: Self.hasNoMicrophone, "a machine with no capture endpoint"))
    func `with no microphone at all, start refuses as no device and captures nothing`() {
        let frames = FrameCount()
        let capture = WindowsAudioCapture(samples: { frames.add($0.count) })
        #expect(throws: WindowsAudioCaptureError.noDevice) {
            try capture.start()
        }
        #expect(capture.currentFormat == nil)
        // The thread has left: stopping waits for nothing.
        capture.stop()
        #expect(frames.value == 0)
    }

    @Test
    func `an id that names no endpoint is refused as no device`() {
        let capture = WindowsAudioCapture(
            deviceID: "{0.0.1.00000000}.{00000000-0000-0000-0000-000000000000}", samples: { _ in },
        )
        #expect(throws: WindowsAudioCaptureError.noDevice) {
            try capture.start()
        }
    }

    @Test(.enabled(if: Self.hasMicrophone, "a machine with a microphone"))
    func `a second of capture arrives mono at the 44.1 kHz asked for`() {
        let frames = FrameCount()
        let capture = WindowsAudioCapture(sampleRate: 44100, samples: { frames.add($0.count) })
        let format: WindowsAudioCapture.Format
        do throws(WindowsAudioCaptureError) {
            format = try capture.start()
        } catch {
            // The machine's privacy setting keeps desktop apps from the microphone: nothing to measure, and the refusal
            // is the one the host shows. Any other failure is this code's.
            if error != .accessDenied {
                Issue.record("start failed: \(error)")
            }
            return
        }
        #expect(format.sampleRate == 44100)
        #expect(format.channels == 1)
        #expect(format.bufferFrames > 0)
        Thread.sleep(forTimeInterval: 1)
        capture.stop()
        // At least half the second: the device takes a moment to deliver its first packet.
        #expect(frames.value >= 22050, "\(frames.value) frames in a second")
        #expect(frames.value <= 44100 * 2, "\(frames.value) frames in a second")
        #expect(capture.currentStats.framesCaptured == frames.value)
        #expect(capture.currentFormat == nil)
    }
}
