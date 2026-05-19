#if !canImport(Compression)
    import Foundation
    import zlib

    extension Deflate {
        /// Compress `input` to raw DEFLATE bytes using system zlib with
        /// `windowBits = -15` (raw DEFLATE — no zlib header).
        static func compress(_ input: Data) throws -> Data {
            if input.isEmpty {
                return Data()
            }
            var stream = z_stream()
            var ret = deflateInit2_(
                &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                -15, // windowBits negative => raw DEFLATE
                8, // memLevel default
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size),
            )
            guard ret == Z_OK else {
                throw ZipError.deflateFailure("deflateInit2 returned \(ret)")
            }
            defer { deflateEnd(&stream) }

            return try input.withUnsafeBytes { src -> Data in
                guard let srcBase = src.baseAddress else {
                    throw ZipError.deflateFailure("nil src base")
                }
                stream.next_in = UnsafeMutablePointer(mutating: srcBase.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = UInt32(input.count)

                var out = Data()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                repeat {
                    ret = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                        stream.next_out = buf.baseAddress
                        stream.avail_out = UInt32(buf.count)
                        return deflate(&stream, Z_FINISH)
                    }
                    guard ret == Z_OK || ret == Z_STREAM_END else {
                        throw ZipError.deflateFailure("deflate returned \(ret)")
                    }
                    let produced = buffer.count - Int(stream.avail_out)
                    out.append(contentsOf: buffer.prefix(produced))
                } while ret != Z_STREAM_END
                return out
            }
        }

        /// Decompress raw DEFLATE bytes using system zlib with
        /// `windowBits = -15`. `expectedSize` is used to pre-size the
        /// output buffer.
        static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
            if expectedSize == 0 {
                return Data()
            }
            var stream = z_stream()
            var ret = inflateInit2_(
                &stream, -15,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size),
            )
            guard ret == Z_OK else {
                throw ZipError.deflateFailure("inflateInit2 returned \(ret)")
            }
            defer { inflateEnd(&stream) }

            return try input.withUnsafeBytes { src -> Data in
                guard let srcBase = src.baseAddress else {
                    throw ZipError.deflateFailure("nil src base")
                }
                stream.next_in = UnsafeMutablePointer(mutating: srcBase.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = UInt32(input.count)

                var out = Data(capacity: expectedSize)
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                repeat {
                    ret = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                        stream.next_out = buf.baseAddress
                        stream.avail_out = UInt32(buf.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    guard ret == Z_OK || ret == Z_STREAM_END else {
                        throw ZipError.deflateFailure("inflate returned \(ret)")
                    }
                    let produced = buffer.count - Int(stream.avail_out)
                    out.append(contentsOf: buffer.prefix(produced))
                } while ret != Z_STREAM_END

                guard out.count == expectedSize else {
                    throw ZipError.corrupted(
                        "inflate size mismatch (got \(out.count), expected \(expectedSize))",
                    )
                }
                return out
            }
        }
    }
#endif
