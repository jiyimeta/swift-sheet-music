import SheetMusicFoundation

/// Error type raised by SheetMusicZip's `ZipReader` and `ZipWriter`.
/// Consumers (e.g. `MSCZReader`, `MXLReader`) translate to
/// `SheetMusicError.corruptedContainer(reason:)` at the call site.
public enum ZipError: Error, Equatable {
    case notAZip // EOCD not found
    case unsupportedFeature(String) // ZIP64 / encryption / unknown method
    case corrupted(String) // CRC mismatch, size mismatch, malformed
    case entryNotFound(String)
    case deflateFailure(String) // backend wrap
}
