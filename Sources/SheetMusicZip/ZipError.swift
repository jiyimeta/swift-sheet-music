import SheetMusicFoundation

/// Error type raised by SheetMusicZip's `ZipReader` and `ZipWriter`.
/// Consumers (e.g. `MSCZReader`, `MXLReader`) translate to
/// `SheetMusicError.corruptedContainer` at the call site.
public enum ZipError: Error, Equatable {
    case notAZip // EOCD not found
    case unsupportedFeature(String) // ZIP64 / encryption / unknown method
    case corrupted(String) // CRC mismatch, size mismatch, malformed
    case entryNotFound(String)
    case deflateFailure(String) // backend wrap
}

extension ZipError {
    /// Stable dotted code under the `zip.` namespace, for embedding into a
    /// `ScoreFault` by consumers that translate this error.
    public var faultCode: String {
        switch self {
        case .notAZip:
            "zip.notAZip"
        case .unsupportedFeature:
            "zip.unsupportedFeature"
        case .corrupted:
            "zip.corrupted"
        case .entryNotFound:
            "zip.entryNotFound"
        case .deflateFailure:
            "zip.deflateFailure"
        }
    }
}
