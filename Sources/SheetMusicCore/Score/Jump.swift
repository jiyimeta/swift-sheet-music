import SheetMusicFoundation

/// Measure-right navigation instruction: D.C., D.S., D.C. al Coda, etc.
/// C++: `mu::engraving::Jump`.
public struct Jump: Sendable, Equatable {
    /// MuseScore `<jumpTo>` text ("start", "segno", …).
    public var jumpTo: String
    /// MuseScore `<playUntil>` text ("end", "coda", …).
    public var playUntil: String
    /// MuseScore `<continueAt>` text (empty when jump ends the piece).
    public var continueAt: String
    /// MuseScore `<playRepeats>` — when true, repeats are taken again
    /// after the jump ("Play repeats" checkbox). MuseScore default is
    /// false (`Jump::Jump`, jump.cpp:73): after a jump each repeated
    /// passage plays its final pass only.
    public var playRepeats: Bool
    /// User-facing display text ("D.C. al Fine", "D.S. al Coda", …).
    public var text: String
    /// Source XML children this model does not represent.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        jumpTo: String,
        playUntil: String,
        continueAt: String = "",
        playRepeats: Bool = false,
        text: String = "",
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.jumpTo = jumpTo
        self.playUntil = playUntil
        self.continueAt = continueAt
        self.playRepeats = playRepeats
        self.text = text
        self.preservedMarkup = preservedMarkup
    }
}
