import Foundation

/// One entry within a ZIP archive.
///
/// On reader-side, `payloadRange` is the byte range (within the source
/// archive `Data`) of the compressed payload — i.e. the bytes immediately
/// after the local file header. On writer-side it is nil until `finish()`
/// has been called.
struct ZipEntry: Equatable {
    let path: String // forward-slash separated, UTF-8
    let uncompressedSize: UInt32
    let compressedSize: UInt32
    let crc32: UInt32
    let method: ZipCompressionMethod
    let payloadRange: Range<Int>?
}
