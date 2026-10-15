import SheetMusicCore
import SheetMusicFoundation

/// What a voice's chords play at, by original (pre-repeat) tick: the ramps (`HairpinRamp`) and the levels its dynamics
/// put in force, in tick order. A chord plays the ramp in force at its onset, else the last level at or before it, else
/// `initialVelocity` — what `MidiRenderer` used to keep as a running level of its own voice.
struct DynamicsTimeline {
    var ramps: [HairpinRamp]
    var levels: [HairpinRamps.DynPoint]
    var initialVelocity: Int

    func velocity(atOriginalTick tick: Int) -> Int {
        if let ramp = HairpinRamps.active(in: ramps, at: tick) {
            return HairpinRamps.interpolate(ramp: ramp, atOriginalTick: tick)
        }
        return level(atOriginalTick: tick)
    }

    func level(atOriginalTick tick: Int) -> Int {
        levels.last { $0.tick <= tick }?.velocity ?? initialVelocity
    }

    /// The level a jump from `tick`, the last of the run it leaves, carries (`HairpinRamps.levelToCarry`).
    func carriedVelocity(atOriginalTick tick: Int) -> Int {
        HairpinRamps.levelToCarry(at: tick, ramps: ramps, running: level(atOriginalTick: tick))
    }

    /// The timeline as a run of measures starting at original tick `start` hears it, `carried` in: the ramps that reach
    /// it (`HairpinRamp.appliesToPass(startingAt:)`), the levels from `start` on, and `carried` until the first.
    func pass(startingAt start: Int, carrying carried: Int) -> DynamicsTimeline {
        DynamicsTimeline(
            ramps: ramps.filter { $0.appliesToPass(startingAt: start) },
            levels: levels.filter { $0.tick >= start },
            initialVelocity: carried,
        )
    }
}
