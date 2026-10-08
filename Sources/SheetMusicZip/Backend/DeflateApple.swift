#if canImport(Compression)
    import Compression
    import SheetMusicFoundation

    extension Deflate {
        /// Compress `input` to raw DEFLATE bytes using Apple's `Compression`
        /// framework with `COMPRESSION_ZLIB` (raw DEFLATE — no header, no
        /// checksum). Destination buffer is sized with a small head-room to
        /// tolerate low-entropy expansion.
        package static func compress(_ input: Data) throws -> Data {
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

        /// Decompress raw DEFLATE with an unknown output size. Corrupt or truncated input throws, and so does output
        /// past `limit` bytes: DEFLATE expands up to about a thousandfold, so a few kilobytes of input could otherwise
        /// ask for gigabytes.
        package static func inflate(_ input: Data, limit: Int) throws -> Data {
            if input.isEmpty { return Data() }
            let chunkSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { buffer.deallocate() }
            return try input.withUnsafeBytes { source in
                guard let base = source.baseAddress else { throw ZipError.corrupted("missing deflate input") }
                var stream = compression_stream(
                    dst_ptr: buffer, dst_size: chunkSize,
                    src_ptr: base.assumingMemoryBound(to: UInt8.self), src_size: source.count, state: nil,
                )
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                    == COMPRESSION_STATUS_OK else { throw ZipError.deflateFailure("compression_stream_init failed") }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = base.assumingMemoryBound(to: UInt8.self)
                stream.src_size = source.count
                var output = Data()
                while true {
                    let before = stream.src_size
                    stream.dst_ptr = buffer
                    stream.dst_size = chunkSize
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = chunkSize - stream.dst_size
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                        throw ZipError.corrupted("invalid or truncated deflate stream")
                    }
                    guard produced <= limit - output.count else {
                        throw ZipError.corrupted("deflate output exceeds \(limit) bytes")
                    }
                    output.append(buffer, count: produced)
                    if status == COMPRESSION_STATUS_END { return output }
                    guard before != stream.src_size || produced > 0 else {
                        throw ZipError.corrupted("truncated deflate stream")
                    }
                }
            }
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
