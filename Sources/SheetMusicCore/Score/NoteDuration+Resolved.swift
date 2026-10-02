import SheetMusicFoundation

extension NoteDuration {
    /// Replace `.measure` with the bar's own length, spelled the way a decoded file spells it. All other cases pass
    /// through unchanged. Use this at the boundary of a per-measure loop so context-free helpers (`asFraction`,
    /// `ticks(division:)`) never trap on `.measure`.
    ///
    /// **The spelling matters, not only the length.** `NoteDuration`'s equality and `Score.stableFingerprint` are
    /// both case-by-case — `.whole != .fraction(1/1)` — and the MSCX decoder spells an undotted length with its
    /// named case (`.whole`, `.half`, …) and only a dotted or irregular one as a `.fraction`. This used to answer
    /// `.fraction(1/1)` for a 4/4 bar, so a note typed into an empty bar (`InputNote` takes the rest's resolved
    /// length) was stored as `.fraction(1/1)`, written as `<durationType>whole</durationType>`, and read back as
    /// `.whole`: the same score, yet not `==` to itself across a save, and with another fingerprint — which a host
    /// that rebuilds its copy by encode and load reads as a divergence. Answering in the decoder's spelling makes
    /// every edit that resolves a bar a fixed point of encode → parse.
    public func resolved(in measureDuration: Fraction) -> NoteDuration {
        switch self {
        case .measure: return Self.canonical(measureDuration)
        default: return self
        }
    }

    /// `length` spelled as the MSCX decoder spells it: the named case when it is an undotted base value, and a
    /// `.fraction` otherwise — a dotted value, a tuplet-scaled one, a 5/4 bar.
    public static func canonical(_ length: Fraction) -> NoteDuration {
        let named: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
            .oneTwentyEighth, .twoFiftySixth,
        ]
        return named.first { $0.asFraction == length } ?? .fraction(length)
    }
}
