import Foundation

/// Errors raised by SheetMusic libraries when reading mscx data, building
/// the score model, or rendering MIDI.
public enum SheetMusicError: Error, Sendable {
    /// XML was syntactically invalid (could not be parsed by Foundation `XMLParser`).
    case invalidXML(underlying: Error)
    /// XML parsed but a required element/attribute was missing or malformed.
    case malformedScore(reason: String)
    /// A score element exists in the file but is not yet supported by the library.
    case unsupportedFeature(name: String, location: String?)
    /// An `.mscz` / ZIP container is unreadable: bytes are not a valid ZIP,
    /// the archive has no main `.mscx` entry, an entry failed to
    /// decompress, or archive creation failed on the writer side.
    case corruptedContainer(reason: String)
    /// Wrapping for `Data(contentsOf:)` / `Data.write(to:)` failures in
    /// the URL-based API overloads. The original error is preserved.
    case ioError(url: URL, underlying: Error)
    /// An `EditCommand` could not be applied — typically because the
    /// target path no longer resolves, or the element at that path
    /// is the wrong kind for the command.
    case invalidEdit(reason: String)
}

/// Surface the case-specific reason via `localizedDescription` — without this,
/// callers (and SwiftUI alerts that just print `error.localizedDescription`)
/// only see "SheetMusicError error N" with no diagnostic payload.
extension SheetMusicError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidXML(underlying):
            return "Invalid XML: \(underlying.localizedDescription)"
        case let .malformedScore(reason):
            return reason
        case let .unsupportedFeature(name, location):
            if let location {
                return "Unsupported feature \(name) at \(location)"
            }
            return "Unsupported feature \(name)"
        case let .corruptedContainer(reason):
            return "Corrupted archive: \(reason)"
        case let .ioError(url, underlying):
            return "I/O error reading \(url.lastPathComponent): \(underlying.localizedDescription)"
        case let .invalidEdit(reason):
            return "Invalid edit: \(reason)"
        }
    }
}
