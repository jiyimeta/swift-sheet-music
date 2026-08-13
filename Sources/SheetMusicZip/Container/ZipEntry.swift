import SheetMusicFoundation

/// One entry within a ZIP archive.
///
/// On reader-side, `payloadRange` is the byte range (within the source
/// archive `Data`) of the compressed payload — i.e. the bytes immediately
/// after the local file header. On writer-side it is nil until `finish()`
/// has been called.
public struct ZipEntry: Equatable {
    public let path: String // forward-slash separated, UTF-8
    public let uncompressedSize: UInt32
    public let compressedSize: UInt32
    public let crc32: UInt32
    public let method: ZipCompressionMethod
    public let payloadRange: Range<Int>?
}
