import Foundation

/// Tempo change. mscx `<tempo>` is in beats per second (a float).
/// C++: `mu::engraving::TempoText` / `mu::engraving::Tempo`.
public struct Tempo: Sendable, Equatable {
    /// Beats per second as encoded in mscx. 2.0 = 120 BPM (since mscx tempo is per quarter).
    public var beatsPerSecond: Double

    public init(beatsPerSecond: Double) {
        self.beatsPerSecond = beatsPerSecond
    }

    /// Microseconds per quarter note for SMF tempo meta event.
    public var microsecondsPerQuarter: Int {
        Int((1.0 / beatsPerSecond * 1_000_000.0).rounded())
    }
}
