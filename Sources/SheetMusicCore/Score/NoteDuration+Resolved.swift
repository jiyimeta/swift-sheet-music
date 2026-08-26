import SheetMusicFoundation

extension NoteDuration {
    /// Replace `.measure` with `.fraction(measureDuration)`. All other
    /// cases pass through unchanged. Use this at the boundary of a
    /// per-measure loop so context-free helpers (`asFraction`,
    /// `ticks(division:)`) never trap on `.measure`.
    public func resolved(in measureDuration: Fraction) -> NoteDuration {
        switch self {
        case .measure: return .fraction(measureDuration)
        default: return self
        }
    }
}
