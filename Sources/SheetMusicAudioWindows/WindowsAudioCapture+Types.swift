import CWASAPI

/// Why the microphone could not be opened.
public enum WindowsAudioCaptureError: Error, Equatable, CustomStringConvertible {
    /// The system keeps this app from the microphone: Settings ▸ Privacy & security ▸ Microphone has it (or desktop
    /// apps as a whole) switched off, and `IMMDevice::Activate` answered E_ACCESSDENIED.
    case accessDenied
    /// No capture endpoint is there — none at all, or the one asked for by id is gone, disabled or no microphone.
    case noDevice
    /// Another WASAPI call failed; `hresult` is its HRESULT.
    case device(call: String, hresult: Int32)

    /// What `hresult`, returned by `call`, means for the host.
    init(call: String, hresult: Int32) {
        if cwasapi_is_access_denied(hresult) == 1 {
            self = .accessDenied
        } else if cwasapi_is_no_device(hresult) == 1 {
            self = .noDevice
        } else {
            self = .device(call: call, hresult: hresult)
        }
    }

    public var description: String {
        switch self {
        case .accessDenied:
            "the system's privacy settings keep this app from the microphone"
        case .noDevice:
            "no microphone"
        case let .device(call, hresult):
            "\(call) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))"
        }
    }
}

/// What `WindowsAudioCapture` lists, opens and reports, and the one piece of its packet handling that needs no device.
extension WindowsAudioCapture {
    /// A capture endpoint, as Windows lists it.
    public struct Device: Sendable, Hashable {
        /// The endpoint id — what `init(deviceID:)` takes. Stable across launches for the same device.
        public let id: String
        /// The friendly name Windows shows ("Microphone (USB Audio Device)"); empty when it cannot be read.
        public let name: String
        /// Whether it is the default capture device now.
        public let isDefault: Bool

        /// Public for a host's fakes and tests; a real list comes from `inputDevices()`.
        public init(id: String, name: String, isDefault: Bool) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
        }
    }

    /// What an open stream delivers.
    public struct Format: Sendable, Equatable {
        /// The rate asked for, which every packet is at.
        public let sampleRate: Double
        /// Always 1.
        public let channels: Int
        /// The shared buffer's size in frames: how much may wait unread before the device overwrites it.
        public let bufferFrames: Int
        /// `IAudioClient::GetStreamLatency`, in seconds.
        public let latencySeconds: Double
        /// The device's default period, in seconds: how often a packet arrives.
        public let periodSeconds: Double

        /// Public for a host's fakes and tests (a `.recovered` notice, a route figure); a real one comes from
        /// `start()`.
        public init(
            sampleRate: Double, channels: Int, bufferFrames: Int, latencySeconds: Double, periodSeconds: Double,
        ) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bufferFrames = bufferFrames
            self.latencySeconds = latencySeconds
            self.periodSeconds = periodSeconds
        }
    }

    /// A step of a device change. See `WindowsAudioCapture`'s discussion.
    public enum Notice: Sendable, Equatable {
        /// The stream was closed: its device went away, or a new default replaced it.
        case lost
        /// The closed stream's device went away (unplugged, disabled, removed) rather than only stopping being the
        /// default. At most once per `lost`, before its `recovered`.
        case removed
        /// A stream is open again.
        case recovered(Format)
    }

    /// What the stream has been through, for a host's diagnostics.
    public struct Stats: Sendable, Equatable {
        /// Frames handed to `samples`, silent packets' included.
        public var framesCaptured = 0
        /// Packets the device marked silent.
        public var silentPackets = 0
        /// Packets the device marked as following lost frames (`AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY`): the capture
        /// thread was late, or the device glitched.
        public var discontinuities = 0
        /// Streams opened again after one was closed.
        public var rebuilds = 0
        /// The HRESULT of the last failed open, 0 when the last open succeeded.
        public var lastOpenFailure: Int32 = 0
    }

    public typealias Samples = @Sendable (UnsafeBufferPointer<Float>) -> Void
    public typealias Notify = @Sendable (Notice) -> Void

    /// The active capture endpoints, in the order Windows lists them — what a host's input device picker offers.
    public static func inputDevices() throws(WindowsAudioCaptureError) -> [Device] {
        var opened: OpaquePointer?
        let result = cwasapi_capture_devices(&opened)
        guard result == 0, let list = opened else {
            throw WindowsAudioCaptureError(call: "IMMDeviceEnumerator::EnumAudioEndpoints", hresult: result)
        }
        defer { cwasapi_device_list_free(list) }
        let defaultIndex = Int(cwasapi_device_list_default_index(list))
        return (0 ..< Int(cwasapi_device_list_count(list))).map { index in
            Device(
                id: String(cString: cwasapi_device_list_id(list, UInt32(index))),
                name: String(cString: cwasapi_device_list_name(list, UInt32(index))),
                isDefault: index == defaultIndex,
            )
        }
    }
}

extension WindowsAudioCapture {
    /// Calls `body` with the samples a packet of `frames` stands for: its own buffer, or — when the device marked it
    /// silent, whose buffer must not be read, or gave none — `frames` zeros from `zeros`, grown as needed.
    static func packetSamples(
        frames: Int, data: UnsafePointer<Float>?, silent: Bool, zeros: inout [Float],
        body: (UnsafeBufferPointer<Float>) -> Void,
    ) {
        if !silent, let data {
            body(UnsafeBufferPointer(start: data, count: frames))
            return
        }
        if zeros.count < frames {
            zeros = [Float](repeating: 0, count: frames)
        }
        zeros.withUnsafeBufferPointer { buffer in
            body(UnsafeBufferPointer(rebasing: buffer[0 ..< frames]))
        }
    }
}
