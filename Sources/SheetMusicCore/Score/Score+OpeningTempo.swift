import Foundation

extension Score {
    /// Quarter-note BPM of the tempo governing the very start of the score
    /// (measure 0, tick 0), or MuseScore's 120 default when none is marked
    /// there. This is the opening value a tempo readout multiplies by the
    /// playback rate to show "♩ = N".
    ///
    /// Mirrors the Reader's `effectiveQuarterBpm(at: nil)` derivation so iOS
    /// and Android show the same number from one shared place — Android reads
    /// it over JNI (`nativeOpeningQuarterBpm`).
    public var openingQuarterBpm: Double {
        guard !systemMeasures.isEmpty else { return 120 }
        var governing: Tempo?
        for positioned in systemMeasures[0].elements {
            guard case let .tempo(tempo) = positioned.element else { continue }
            // A marking only governs the start once it sits at (or before) tick 0.
            if positioned.position.ticks(division: division) <= 0 {
                governing = tempo
            }
        }
        return (governing?.beatsPerSecond ?? 2.0) * 60
    }
}
