/// Translates between the playback sequencer's tick space (which begins with a count-in pre-roll region)
/// and the score's own tick space. A count-in shifts all score content forward by `preRollTicks` and starts
/// it at score tick `baseTick`; ticks below `preRollTicks` are the pre-roll (no score position — cursor pinned).
struct SequenceMap: Equatable {
    let preRollTicks: Int
    let baseTick: Int

    static let identity = SequenceMap(preRollTicks: 0, baseTick: 0)

    /// The score tick a raw sequencer tick corresponds to, or nil while inside the pre-roll.
    func scoreTick(fromSequencer sequencerTick: Int) -> Int? {
        sequencerTick < preRollTicks ? nil : baseTick + (sequencerTick - preRollTicks)
    }

    /// The raw sequencer tick a score tick maps to (score tick must be >= baseTick).
    func sequencerTick(fromScore scoreTick: Int) -> Int {
        preRollTicks + (scoreTick - baseTick)
    }
}
