import Foundation

/// Tempo change. mscx `<tempo>` is in beats per second (a float).
/// C++: `mu::engraving::TempoText` / `mu::engraving::Tempo`.
public struct Tempo: Sendable, Equatable {
    /// Beats per second as encoded in mscx. 2.0 = 120 BPM (since mscx tempo is per quarter).
    public var beatsPerSecond: Double
    /// Author-supplied X offset relative to the default placement,
    /// in spatium units. Applied AFTER autoplace-style stacking.
    public var offsetX: Double
    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down).
    public var offsetY: Double
    /// Per-element font overrides on the displayed tempo text.
    /// `nil`-fields inherit from `TextStyleType.tempo`
    /// (Edwin 12 pt bold by default). Has no effect on MIDI output.
    public var properties: TextProperties
    /// MuseScore `<visible>0</visible>` flag. When false the tempo
    /// label is hidden — layout drops it (no glyph, no reserved
    /// space) but the tempo change still applies to playback / MIDI.
    public var visible: Bool

    public init(
        beatsPerSecond: Double,
        offsetX: Double = 0,
        offsetY: Double = 0,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
    ) {
        self.beatsPerSecond = beatsPerSecond
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.properties = properties
        self.visible = visible
    }

    /// Microseconds per quarter note for SMF tempo meta event.
    public var microsecondsPerQuarter: Int {
        Int((1.0 / beatsPerSecond * 1_000_000.0).rounded())
    }
}
