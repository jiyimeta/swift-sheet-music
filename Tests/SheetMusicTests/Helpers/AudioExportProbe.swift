#if !os(Android)
    import AVFoundation
    import Foundation
    import SheetMusicAudioCore

    /// Shared probes for tests that assert on the CONTENT of an exported audio
    /// file rather than just its container — "did anything sound", "did the
    /// master gain scale it". Extend this rather than re-deriving a peak scan
    /// in each suite.
    enum AudioExportProbe {
        struct EmptyExport: Error {}

        /// Largest absolute sample anywhere in `url`, across all channels.
        ///
        /// Reads the whole file into one buffer: export fixtures in this suite
        /// are a couple of measures, and a streaming scan would add moving
        /// parts to what is meant to be a one-line assertion.
        static func peakAmplitude(of url: URL) throws -> Float {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length),
            ) else { throw EmptyExport() }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else { return 0 }
            var peak: Float = 0
            for channel in 0 ..< Int(buffer.format.channelCount) {
                for frame in 0 ..< Int(buffer.frameLength) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
            return peak
        }

        /// A throwaway `.wav` path under the temporary directory.
        static func temporaryWAV() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("smexp-\(UUID().uuidString).wav")
        }
    }

    /// One SF2 for every lookup — enough for tests that need real audible
    /// output rather than the silence a nil-returning resolver produces.
    struct FixedSoundfontResolver: SoundfontResolver {
        let url: URL

        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            url
        }

        var defaultGMSoundfontURL: URL? {
            url
        }
    }
#endif
