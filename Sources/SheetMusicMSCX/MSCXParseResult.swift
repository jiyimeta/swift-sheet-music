import Foundation
import SheetMusicCore

/// Result of an MSCX / MSCZ parse that surfaces non-fatal anomalies
/// alongside the parsed score. Returned by
/// `MSCXParser.parseWithDiagnostics(...)` /
/// `MSCZReader.parseWithDiagnostics(...)`. The matching
/// `parse(...) -> Score` overloads share the same internal decode
/// path but discard `diagnostics`.
public struct MSCXParseResult: Sendable {
    public let score: Score
    public let diagnostics: [ScoreDiagnostic]

    public init(score: Score, diagnostics: [ScoreDiagnostic]) {
        self.score = score
        self.diagnostics = diagnostics
    }
}
