import SheetMusicFoundation

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

extension SheetMusicError {
    /// Developer-facing diagnostic text for logs, tests, and sample-app
    /// fallback UI. These English literals are not localized resources: there
    /// is no `.strings` catalog and no bundle lookup. Keep presentation and
    /// localization in the consuming app, which can switch over the enum cases
    /// and provide locale-sensitive copy without depending on Foundation's
    /// `LocalizedError` bridging.
    public var developerDescription: String {
        switch self {
        case let .invalidXML(underlying):
            return "Invalid XML: \(Self.describe(underlying))"
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
            return "I/O error reading \(url.lastPathComponent): \(Self.describe(underlying))"
        case let .invalidEdit(reason):
            return "Invalid edit: \(reason)"
        }
    }

    /// Foreign errors can carry OS-provided localized text. Use it when
    /// Foundation is available, and fall back to Swift's diagnostic rendering
    /// on FoundationEssentials-only platforms.
    private static func describe(_ error: Error) -> String {
        #if canImport(FoundationEssentials)
            String(describing: error)
        #else
            (error as NSError).localizedDescription
        #endif
    }
}
