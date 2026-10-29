#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation

    /// Writes recordings in `RecordingPCMCache`'s format ("SMPC", version 1, frame count, rate, then interleaved Int16
    /// left / right) without decoding anything, for tests that need a `MappedRecording` or a file to map.
    enum PCMCacheFixture {
        /// A temporary PCM cache file holding `frames` frames of `sample(frame)` on both channels. The caller removes
        /// it.
        static func write(rate: Int, frames: Int, sample: (Int) -> Int16) throws -> URL {
            var bytes = Data(Array("SMPC".utf8))
            for word in [UInt32(1), UInt32(frames), UInt32(rate)] {
                withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
            }
            var samples: [Int16] = []
            samples.reserveCapacity(frames * 2)
            for frame in 0 ..< frames {
                let value = sample(frame)
                samples.append(value.littleEndian)
                samples.append(value.littleEndian)
            }
            samples.withUnsafeBytes { bytes.append(contentsOf: $0) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID()).pcm")
            try bytes.write(to: url)
            return url
        }
    }
#endif
