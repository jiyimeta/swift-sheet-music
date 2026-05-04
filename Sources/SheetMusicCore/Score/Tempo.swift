import Foundation

/// Tempo change. mscx `<tempo>` is in beats per second (a float).
/// C++: `mu::engraving::TempoText` / `mu::engraving::Tempo`.
public struct Tempo: Sendable, Equatable {
    /// Beats per second as encoded in mscx. 2.0 = 120 BPM (since mscx tempo is per quarter).
    public var beatsPerSecond: Double
    /// Per-element font overrides on the displayed tempo text.
    /// `nil`-fields inherit from `TextStyleType.tempo`
    /// (Edwin 12 pt bold by default). Has no effect on MIDI output.
    public var properties: TextProperties

    public init(
        beatsPerSecond: Double,
        properties: TextProperties = TextProperties()
    ) {
        self.beatsPerSecond = beatsPerSecond
        self.properties = properties
    }

    /// Microseconds per quarter note for SMF tempo meta event.
    public var microsecondsPerQuarter: Int {
        Int((1.0 / beatsPerSecond * 1_000_000.0).rounded())
    }
}
