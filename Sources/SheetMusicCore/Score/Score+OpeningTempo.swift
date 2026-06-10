import Foundation

extension Score {
    /// Quarter-note BPM at the score's opening. Equivalent to `effectiveQuarterBpm(at: nil)`.
    public var openingQuarterBpm: Double {
        effectiveQuarterBpm(at: nil)
    }
}
