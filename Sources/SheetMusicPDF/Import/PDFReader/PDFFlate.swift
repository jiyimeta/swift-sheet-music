#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

#if canImport(Compression)
    import Compression
#else
    import zlib
#endif

/// Foundation-only `/FlateDecode` (RFC 1950 zlib) inflater.
///
/// The output size of a PDF stream is not known ahead of time, so the raw
/// bytes are streamed into a buffer that grows in 64 KiB chunks. Apple uses
/// the `Compression` framework (`COMPRESSION_ZLIB` = raw DEFLATE, so the
/// 2-byte zlib header is stripped and the trailing Adler-32 is ignored);
/// Android uses system `zlib` with `windowBits = 47` (auto-detect the
/// zlib/gzip header). Mirrors `SheetMusicZip`'s `DeflateApple` /
/// `DeflateZLib` back-ends.
enum PDFFlate {
    private static let chunkSize = 64 * 1024

    /// Inflate a zlib-format (RFC 1950) `/FlateDecode` stream. Returns `nil`
    /// on error and empty `Data` for empty input.
    static func inflate(_ data: Data) -> Data? {
        if data.isEmpty {
            return Data()
        }
        #if canImport(Compression)
            guard data.count >= 2 else {
                return nil
            }
            // Strip the 2-byte zlib header; COMPRESSION_ZLIB expects raw DEFLATE.
            let raw = [UInt8](data.dropFirst(2))
            return inflateRawDeflate(raw)
        #else
            return inflateZlibAuto([UInt8](data))
        #endif
    }

    #if canImport(Compression)
        private static func inflateRawDeflate(_ raw: [UInt8]) -> Data? {
            if raw.isEmpty {
                return Data()
            }
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { dstBuffer.deallocate() }

            return raw.withUnsafeBufferPointer { srcBuf -> Data? in
                guard let srcBase = srcBuf.baseAddress else {
                    return Data()
                }
                var stream = compression_stream(
                    dst_ptr: dstBuffer,
                    dst_size: chunkSize,
                    src_ptr: srcBase,
                    src_size: srcBuf.count,
                    state: nil,
                )
                guard compression_stream_init(
                    &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB,
                ) == COMPRESSION_STATUS_OK else {
                    return nil
                }
                defer { compression_stream_destroy(&stream) }

                // `compression_stream_init` clears the src/dst fields, so set the
                // whole input after init. The destination buffer must also be
                // refreshed before *every* `_process` call: when output exceeds
                // one chunk, a full buffer with more to emit returns ERROR (not
                // OK) if `dst_size` is left at 0.
                stream.src_ptr = srcBase
                stream.src_size = srcBuf.count
                var output = Data()
                let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                while true {
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = chunkSize
                    let status = compression_stream_process(&stream, flags)
                    switch status {
                    case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                        let produced = chunkSize - stream.dst_size
                        if produced > 0 {
                            output.append(dstBuffer, count: produced)
                        }
                        if status == COMPRESSION_STATUS_END {
                            return output
                        }
                    default:
                        return nil
                    }
                }
            }
        }
    #else
        private static func inflateZlibAuto(_ input: [UInt8]) -> Data? {
            if input.isEmpty {
                return Data()
            }
            var stream = z_stream()
            var ret = inflateInit2_(
                &stream, 47, // 47 = auto-detect zlib/gzip header
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size),
            )
            guard ret == Z_OK else {
                return nil
            }
            defer { inflateEnd(&stream) }

            return input.withUnsafeBufferPointer { srcBuf -> Data? in
                guard let srcBase = srcBuf.baseAddress else {
                    return Data()
                }
                stream.next_in = UnsafeMutablePointer(mutating: srcBase)
                stream.avail_in = UInt32(srcBuf.count)

                var output = Data()
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                repeat {
                    ret = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                        stream.next_out = buf.baseAddress
                        stream.avail_out = UInt32(buf.count)
                        // Qualify: `PDFFlate.inflate(_:)` (this enum's own
                        // static method) otherwise shadows the global zlib
                        // `inflate` inside this scope.
                        return zlib.inflate(&stream, Z_NO_FLUSH)
                    }
                    guard ret == Z_OK || ret == Z_STREAM_END else {
                        return nil
                    }
                    let produced = buffer.count - Int(stream.avail_out)
                    output.append(contentsOf: buffer.prefix(produced))
                } while ret != Z_STREAM_END
                return output
            }
        }
    #endif
}
