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
}
