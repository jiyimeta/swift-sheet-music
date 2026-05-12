import Foundation

/// Records where a `Score` was loaded from, so consumers can branch
/// on the original format (e.g. show a "imported from MIDI" badge,
/// or skip features that don't survive a particular import path).
///
/// `unknown` covers programmatically constructed scores and any
/// future loader that hasn't been taught to set this field.
public enum ScoreSource: Sendable, Hashable {
    /// Standard MIDI File (`.mid`).
    case midi
    /// MuseScore native format (`.mscx` or `.mscz`). The associated
    /// `MSCXVersion` reflects the wire-format major version detected
    /// from `<museScore version="…">`.
    case museScore(MSCXVersion)
    /// MusicXML (`.musicxml` or zipped `.mxl`).
    case musicXML
    /// PDF (raster/vector engraving imported via OCR-style pipeline).
    case pdf
    /// Source not recorded — programmatic construction, tests, or
    /// loaders that predate this property.
    case unknown

    /// Short human-readable label suitable for badges or toolbar items.
    public var displayName: String {
        switch self {
        case .midi: "MIDI"
        case .museScore(.v2): "MuseScore 2"
        case .museScore(.v3): "MuseScore 3"
        case .museScore(.v4): "MuseScore 4"
        case .musicXML: "MusicXML"
        case .pdf: "PDF"
        case .unknown: "Unknown"
        }
    }
}
