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
}
