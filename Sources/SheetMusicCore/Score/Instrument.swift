import Foundation

/// An instrument definition attached to a part. C++: `mu::engraving::Instrument`.
public struct Instrument: Sendable, Equatable {
    public var id: String
    public var longName: String?
    public var shortName: String?
    public var trackName: String?
    public var minPitchPlayable: Int?   // C++: minPitchP
    public var maxPitchPlayable: Int?   // C++: maxPitchP
    public var minPitchAmateur: Int?    // C++: minPitchA
    public var maxPitchAmateur: Int?    // C++: maxPitchA
    public var articulations: [InstrumentArticulation]
    /// All `<Channel>` blocks defined for this instrument: usually one ("normal")
    /// for simple instruments, multiple for instruments with playback flavours
    /// (e.g. violin = "normal", "pizzicato", "tremolo").
    public var channels: [InstrumentChannel]

    /// Convenience accessor for the primary (= first) channel.
    public var channel: InstrumentChannel {
        channels.first ?? InstrumentChannel()
    }

    public init(
        id: String,
        longName: String? = nil,
        shortName: String? = nil,
        trackName: String? = nil,
        minPitchPlayable: Int? = nil,
        maxPitchPlayable: Int? = nil,
        minPitchAmateur: Int? = nil,
        maxPitchAmateur: Int? = nil,
        articulations: [InstrumentArticulation] = [],
        channels: [InstrumentChannel] = [InstrumentChannel()]
    ) {
        self.id = id
        self.longName = longName
        self.shortName = shortName
        self.trackName = trackName
        self.minPitchPlayable = minPitchPlayable
        self.maxPitchPlayable = maxPitchPlayable
        self.minPitchAmateur = minPitchAmateur
        self.maxPitchAmateur = maxPitchAmateur
        self.articulations = articulations
        self.channels = channels.isEmpty ? [InstrumentChannel()] : channels
    }
}
