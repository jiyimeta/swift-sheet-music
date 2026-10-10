import SheetMusicFoundation

/// AIFF bytes for `AudioFileFormat.aiff` on a host whose platform writes no audio files itself (Windows): the header
/// and the samples, big-endian, as bytes the host puts wherever it likes. Integer depths are plain AIFF (`FORM` /
/// `COMM` / `SSND`, a 54-byte header); `.float32` is AIFF-C with the `fl32` compression type and the `FVER` chunk
/// AIFF-C requires (92 bytes) — the bytes Apple's writer puts in its `.aifc` for the same options.
///
/// Samples are `WAVEncoding`'s — clamped, rounded and averaged for `.mono` the same way — with each sample's bytes in
/// the other order.
public enum AIFFEncoding {
    /// The most sample bytes an AIFF can say it holds: the `FORM` size is 32-bit and counts the header too (on a 32-bit
    /// host such as WebAssembly, an `Int`'s most, less the header, so the sizes the header adds up stay in range). A
    /// writer stops before this; a header asked for more says this much rather than wrapping round.
    public static let maximumDataBytes = Int(clamping: Int64(UInt32.max)) - 92

    /// The header for `frameCount` frames, its length fixed by `options`. A writer that does not know the count yet
    /// writes it with 0 and writes it again once it does.
    public static func header(options: PCMOptions, frameCount: Int) -> [UInt8] {
        let channels = options.channels.rawValue
        let dataBytes = min(
            WAVEncoding.byteCount(frames: frameCount, bytesPerFrame: bytesPerFrame(options)), maximumDataBytes,
        )
        let isFloat = options.bitDepth == .float32
        let compressionName = Array("32-bit floating point".utf8)
        // COMM: channels, frames, sample size, rate; AIFF-C adds the compression type and its name as a Pascal string
        // (count byte first), padded to an even length.
        let pascalLength = 1 + compressionName.count
        let commSize = isFloat ? 18 + 4 + pascalLength + pascalLength % 2 : 18
        let fverChunk = isFloat ? 12 : 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(92)
        bytes += Array("FORM".utf8)
        append(UInt32(clamping: 4 + fverChunk + 8 + commSize + 16 + dataBytes), to: &bytes)
        bytes += Array((isFloat ? "AIFC" : "AIFF").utf8)
        if isFloat {
            bytes += Array("FVER".utf8)
            append(UInt32(4), to: &bytes)
            append(UInt32(0xA280_5140), to: &bytes) // AIFF-C version 1
        }
        bytes += Array("COMM".utf8)
        append(UInt32(commSize), to: &bytes)
        append(UInt16(channels), to: &bytes)
        append(UInt32(clamping: frameCount), to: &bytes)
        append(UInt16(bytesPerFrame(options) / channels * 8), to: &bytes)
        bytes += extended(options.sampleRate)
        if isFloat {
            bytes += Array("fl32".utf8)
            bytes.append(UInt8(compressionName.count))
            bytes += compressionName
            if pascalLength % 2 == 1 { bytes.append(0) }
        }
        bytes += Array("SSND".utf8)
        append(UInt32(clamping: 8 + dataBytes), to: &bytes)
        append(UInt32(0), to: &bytes) // offset
        append(UInt32(0), to: &bytes) // block size
        return bytes
    }

    /// Appends `frames` frames of `interleavedStereo` in `options`' depth and channel count, big-endian.
    public static func appendSamples(
        _ interleavedStereo: UnsafeBufferPointer<Float>, frames: Int, options: PCMOptions, to bytes: inout [UInt8],
    ) {
        let start = bytes.count
        WAVEncoding.appendSamples(interleavedStereo, frames: frames, options: options, to: &bytes)
        let width = bytesPerFrame(options) / options.channels.rawValue
        var sample = start
        while sample < bytes.count {
            bytes[sample ..< sample + width].reverse()
            sample += width
        }
    }

    public static func bytesPerFrame(_ options: PCMOptions) -> Int {
        WAVEncoding.bytesPerFrame(options)
    }

    /// `rate` as the 80-bit IEEE 754 extended float AIFF's `COMM` carries: sign and 15-bit exponent, then a 64-bit
    /// mantissa with its integer bit explicit. Rates are whole numbers of hertz, so the mantissa is the rate shifted
    /// left until its top bit is set.
    static func extended(_ rate: Double) -> [UInt8] {
        let whole = UInt64(max(1, rate.rounded()))
        let shift = whole.leadingZeroBitCount
        let exponent = UInt16(16383 + 63 - shift)
        let mantissa = whole << UInt64(shift)
        var bytes: [UInt8] = []
        append(exponent, to: &bytes)
        append(UInt32(truncatingIfNeeded: mantissa >> 32), to: &bytes)
        append(UInt32(truncatingIfNeeded: mantissa), to: &bytes)
        return bytes
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8(value >> 16 & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}
