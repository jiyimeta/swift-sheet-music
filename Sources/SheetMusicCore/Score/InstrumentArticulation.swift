import SheetMusicFoundation

/// Per-articulation velocity/gate-time settings for an instrument.
/// C++: `mu::engraving::MidiArticulation`.
public struct InstrumentArticulation: Sendable, Equatable {
    public var name: String? // nil = default articulation
    public var velocity: Int // % multiplier on dynamic
    public var gateTime: Int // 1..100 (% of duration the note actually sounds)

    public init(name: String? = nil, velocity: Int = 100, gateTime: Int = 100) {
        self.name = name
        self.velocity = velocity
        self.gateTime = gateTime
    }
}
