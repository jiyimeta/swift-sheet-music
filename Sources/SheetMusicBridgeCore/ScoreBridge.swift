import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLoader

/// The bridge's name for [ScoreLoader], kept so the host-facing call sites read in this file's own vocabulary.
/// Every decision lives in `SheetMusicLoader`; nothing about routing a payload to a parser is a bridge's business,
/// and when this held its own copy of that table the copy is exactly what fell behind — a consumer parsing the same
/// file in a second image reached for `MSCZReader` directly and could not read four of the five formats this one
/// accepted.
public enum ScoreBridge {
    /// See ``ScoreLoader/SniffedFormat``.
    public typealias SniffedFormat = ScoreLoader.SniffedFormat

    /// See ``ScoreLoader/sniff(_:)``.
    public static func sniff(_ bytes: Data) -> SniffedFormat {
        ScoreLoader.sniff(bytes)
    }

    /// See ``ScoreLoader/loadScore(bytes:sourceFilename:)``.
    ///
    /// No `sourceFilename`: a host that imports a score names it from the picker's display name after this returns,
    /// so a MIDI title fallback derived here would only be overwritten.
    public static func loadScore(bytes: Data) throws -> Score {
        try ScoreLoader.loadScore(bytes: bytes)
    }

    /// See ``ScoreLoader/loadScoreWithDiagnostics(bytes:sourceFilename:)``.
    public static func loadScoreWithDiagnostics(bytes: Data) throws -> ScoreLoader.LoadedScore {
        try ScoreLoader.loadScoreWithDiagnostics(bytes: bytes)
    }
}
