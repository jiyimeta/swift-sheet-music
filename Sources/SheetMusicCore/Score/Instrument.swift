import Foundation

/// An instrument definition attached to a part. C++: `mu::engraving::Instrument`.
public struct Instrument: Sendable, Equatable {
    public var id: String
    public var longName: String?
    public var shortName: String?
    public var trackName: String?
    public var minPitchPlayable: Int? // C++: minPitchP
    public var maxPitchPlayable: Int? // C++: maxPitchP
    public var minPitchAmateur: Int? // C++: minPitchA
    public var maxPitchAmateur: Int? // C++: maxPitchA
    public var articulations: [InstrumentArticulation]
    /// All `<Channel>` blocks defined for this instrument: usually one ("normal")
    /// for simple instruments, multiple for instruments with playback flavours
    /// (e.g. violin = "normal", "pizzicato", "tremolo").
    public var channels: [InstrumentChannel]
    /// `<useDrumset>1</useDrumset>` — true for drum kits and percussion. Causes
    /// the renderer to route the part through GM channel 10 (0-indexed: 9), which
    /// DAWs like Logic Pro auto-detect as percussion and dress with a drum kit
    /// patch. C++: `mu::engraving::Instrument::useDrumset()`.
    public var useDrumset: Bool
    /// Per-pitch staff-line mapping for drum instruments. Key = MIDI pitch
    /// (35 = bass drum, 42 = hi-hat, etc.), value = MuseScore line number
    /// (0 = top staff line, 4 = middle, 8 = bottom, negative = above staff).
    /// Used by the UI to position drum noteheads instead of the pitched
    /// diatonic formula.
    public var drumLineMap: [Int: Int]

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
        channels: [InstrumentChannel] = [InstrumentChannel()],
        useDrumset: Bool = false,
        drumLineMap: [Int: Int] = [:],
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
        self.useDrumset = useDrumset
        self.drumLineMap = drumLineMap
    }
}
