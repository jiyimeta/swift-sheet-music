import SheetMusicFoundation

/// RIFF/WAVE bytes for `AudioFileFormat.wav` on a host whose platform writes no audio files itself (Windows): the
/// header and the samples, as bytes the host puts wherever it likes. Integer depths are `WAVE_FORMAT_PCM` in the
/// canonical 44-byte header; `.float32` is `WAVE_FORMAT_IEEE_FLOAT`, whose `fmt ` chunk carries a `cbSize` and whose
/// header adds the `fact` chunk a non-PCM format must have (58 bytes).
///
/// The source is always interleaved stereo float — what the Windows engine renders — and each sample is clamped to
/// full scale, rounded to the nearest step, and averaged into one channel for `.mono`.
public enum WAVEncoding {
    /// The header for `frameCount` frames. A writer that does not know the count yet writes it with 0 and writes it
    /// again, at the same length, once it does.
    public static func header(options: PCMOptions, frameCount: Int) -> [UInt8] {
        let channels = options.channels.rawValue
        let bytesPerSample = bytesPerSample(options.bitDepth)
        let dataBytes = frameCount * channels * bytesPerSample
        let isFloat = options.bitDepth == .float32
        var bytes: [UInt8] = []
        bytes.reserveCapacity(58)
        bytes += Array("RIFF".utf8)
        append(UInt32((isFloat ? 50 : 36) + dataBytes), to: &bytes)
        bytes += Array("WAVEfmt ".utf8)
        append(UInt32(isFloat ? 18 : 16), to: &bytes)
        append(UInt16(isFloat ? 3 : 1), to: &bytes)
        append(UInt16(channels), to: &bytes)
        append(UInt32(options.sampleRate), to: &bytes)
        append(UInt32(Int(options.sampleRate) * channels * bytesPerSample), to: &bytes)
        append(UInt16(channels * bytesPerSample), to: &bytes)
        append(UInt16(bytesPerSample * 8), to: &bytes)
        if isFloat {
            append(UInt16(0), to: &bytes)
            bytes += Array("fact".utf8)
            append(UInt32(4), to: &bytes)
            append(UInt32(frameCount), to: &bytes)
        }
        bytes += Array("data".utf8)
        append(UInt32(dataBytes), to: &bytes)
        return bytes
    }

    /// Appends `frames` frames of `interleavedStereo` in `options`' depth and channel count.
    public static func appendSamples(
        _ interleavedStereo: UnsafeBufferPointer<Float>, frames: Int, options: PCMOptions, to bytes: inout [UInt8],
    ) {
        bytes.reserveCapacity(bytes.count + frames * bytesPerFrame(options))
        for frame in 0 ..< frames {
            let left = interleavedStereo[frame * 2]
            let right = interleavedStereo[frame * 2 + 1]
            switch options.channels {
            case .stereo:
                append(left, depth: options.bitDepth, to: &bytes)
                append(right, depth: options.bitDepth, to: &bytes)
            case .mono:
                append((left + right) / 2, depth: options.bitDepth, to: &bytes)
            }
        }
    }

    public static func bytesPerFrame(_ options: PCMOptions) -> Int {
        options.channels.rawValue * bytesPerSample(options.bitDepth)
    }

    private static func bytesPerSample(_ depth: PCMBitDepth) -> Int {
        switch depth {
        case .int16: 2
        case .int24: 3
        case .int32, .float32: 4
        }
    }

    private static func append(_ sample: Float, depth: PCMBitDepth, to bytes: inout [UInt8]) {
        let clamped = Double(max(-1, min(1, sample)))
        switch depth {
        case .int16:
            append(UInt16(bitPattern: Int16((clamped * 32767).rounded())), to: &bytes)
        case .int24:
            let value = UInt32(bitPattern: Int32((clamped * 8_388_607).rounded()))
            bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)]
        case .int32:
            append(UInt32(bitPattern: Int32((clamped * 2_147_483_647).rounded())), to: &bytes)
        case .float32:
            append(Float(clamped).bitPattern, to: &bytes)
        }
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }
}
