#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
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
            return peak(of: buffer)
        }

        /// Largest absolute sample in frames `[from · sampleRate, to · sampleRate)` of `url`, across all channels,
        /// with the window clamped to the file — "did anything sound between these two moments".
        ///
        /// Throws `EmptyExport` when the clamped window holds no frame: a window past the end of the file is a
        /// mistake in the test, and reading it as silence would let it pass whatever the export did.
        static func peakAmplitude(of url: URL, from: TimeInterval, to: TimeInterval) throws -> Float {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            // Clamped as `Double`s, so `to: .infinity` means "to the end" instead of trapping in the conversion.
            let length = Double(file.length)
            let start = AVAudioFramePosition(min(max(0, from * sampleRate), length))
            let end = AVAudioFramePosition(min(max(Double(start), to * sampleRate), length))
            let frameCount = AVAudioFrameCount(end - start)
            guard frameCount > 0, let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frameCount,
            ) else { throw EmptyExport() }
            file.framePosition = start
            try file.read(into: buffer, frameCount: frameCount)
            return peak(of: buffer)
        }

        private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
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
