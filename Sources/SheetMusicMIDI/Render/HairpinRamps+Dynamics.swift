import SheetMusicCore
import SheetMusicFoundation

/// What `HairpinRamps.collect` gathers from one voice's dynamics, read through `Dynamic.playbackRole`: the running
/// level a wedge starts from, the marks a wedge aims for and a hold stops at, and the wedges waiting to be resolved.
struct DynamicsWalk {
    var runningVelocity: Int
    var marks: [HairpinRamps.DynPoint] = []
    var pending: [HairpinRamps.Pending] = []

    /// One dynamic at `tick`, in the voice's original (pre-repeat) ticks.
    mutating func apply(_ dynamic: Dynamic, atTick tick: Int, instrument: Instrument) {
        switch dynamic.playbackRole {
        case let .level(level):
            let velocity = MidiRenderer.effectiveVelocity(level: level, instrument: instrument)
            marks.append(HairpinRamps.DynPoint(tick: tick, velocity: velocity))
            runningVelocity = velocity
        case .none:
            // No effect: no level, no mark, no hold ends here.
            break
        }
    }
}
