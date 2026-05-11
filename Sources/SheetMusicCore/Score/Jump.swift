import Foundation

/// Measure-right navigation instruction: D.C., D.S., D.C. al Coda, etc.
/// C++: `mu::engraving::Jump`.
public struct Jump: Sendable, Equatable {
    /// MuseScore `<jumpTo>` text ("start", "segno", …).
    public var jumpTo: String
    /// MuseScore `<playUntil>` text ("end", "coda", …).
    public var playUntil: String
    /// MuseScore `<continueAt>` text (empty when jump ends the piece).
    public var continueAt: String
    /// User-facing display text ("D.C. al Fine", "D.S. al Coda", …).
    public var text: String

    public init(
        jumpTo: String,
        playUntil: String,
        continueAt: String = "",
        text: String = "",
    ) {
        self.jumpTo = jumpTo
        self.playUntil = playUntil
        self.continueAt = continueAt
        self.text = text
    }
}
