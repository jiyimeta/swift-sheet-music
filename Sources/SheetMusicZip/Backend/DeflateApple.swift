#if canImport(Compression)
    import Compression
    import SheetMusicFoundation

    extension Deflate {
        /// Compress `input` to raw DEFLATE bytes using Apple's `Compression`
        /// framework with `COMPRESSION_ZLIB` (raw DEFLATE — no header, no
        /// checksum). Destination buffer is sized with a small head-room to
        /// tolerate low-entropy expansion.
        static func compress(_ input: Data) throws -> Data {
            if input.isEmpty {
                return Data()
            }
            let srcCount = input.count
            let dstCount = srcCount + max(64, srcCount / 16)
            var output = Data(count: dstCount)
            let written: Int = try output.withUnsafeMutableBytes { dst in
                try input.withUnsafeBytes { src in
                    guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else {
                        throw ZipError.deflateFailure("nil buffer base on Apple compress")
                    }
                    let n = compression_encode_buffer(
                        dstBase.assumingMemoryBound(to: UInt8.self), dstCount,
                        srcBase.assumingMemoryBound(to: UInt8.self), srcCount,
                        nil, COMPRESSION_ZLIB,
                    )
                    guard n > 0 else {
                        throw ZipError.deflateFailure("compression_encode_buffer returned 0")
                    }
                    return n
                }
            }
            return output.prefix(written)
        }

        /// Decompress raw DEFLATE bytes into a buffer pre-sized to
        /// `expectedSize`. The ZIP central directory always carries
        /// uncompressedSize so this is always known.
        static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
            if expectedSize == 0 {
                return Data()
            }
            var output = Data(count: expectedSize)
            let written: Int = try output.withUnsafeMutableBytes { dst in
                try input.withUnsafeBytes { src in
                    guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else {
                        throw ZipError.deflateFailure("nil buffer base on Apple decompress")
                    }
                    let n = compression_decode_buffer(
                        dstBase.assumingMemoryBound(to: UInt8.self), expectedSize,
                        srcBase.assumingMemoryBound(to: UInt8.self), input.count,
                        nil, COMPRESSION_ZLIB,
                    )
                    guard n > 0 else {
                        throw ZipError.deflateFailure("compression_decode_buffer returned 0")
                    }
                    return n
                }
            }
            guard written == expectedSize else {
                throw ZipError.corrupted(
                    "decompressed size mismatch (got \(written), expected \(expectedSize))",
                )
            }
            return output
        }
    }
#endif
