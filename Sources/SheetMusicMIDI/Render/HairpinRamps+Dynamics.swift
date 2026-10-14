import SheetMusicCore
import SheetMusicFoundation

/// What `HairpinRamps.collect` gathers from one voice's dynamics, read through `Dynamic.playbackRole`: the running
/// level a wedge starts from, the marks a wedge aims for and a hold stops at, the wedges waiting to be resolved, and
/// the ramps a dynamic sounds by itself — an accent over its chord.
struct DynamicsWalk {
    /// A wedge whose spanner stands at `at` starts at `tick`, from `velocity`.
    struct WedgeStart {
        let at: Int
        let tick: Int
        let velocity: Int
    }

    var runningVelocity: Int
    var marks: [HairpinRamps.DynPoint] = []
    var pending: [HairpinRamps.Pending] = []
    /// Every accent: a wedge ending on one aims for its level.
    var accents: [HairpinRamps.DynPoint] = []
    /// Where each accent's chord ends, at the level the dynamics alone had in force before the accent — MuseScore 4's
    /// `prevDynamicLevel`, read before any hairpin is laid out (`playbackcontext.cpp:398-405`, `:324-339`). A restore
    /// ends a hairpin's hold, so the level before the hairpin comes back; it is no mark a wedge aims for, so inside a
    /// wedge the wedge carries on (MuseScore's own points come back within a sixteenth, `:632-640`).
    var restores: [HairpinRamps.DynPoint] = []
    /// The ramps the dynamics sound by themselves.
    var ramps: [HairpinRamp] = []
    private var pendingAccent: (accent: HairpinRamps.DynPoint, restore: Int)?
    private var wedgeStartOverride: WedgeStart?

    init(runningVelocity: Int) {
        self.runningVelocity = runningVelocity
    }

    /// One dynamic at `tick`, in the voice's original (pre-repeat) ticks.
    mutating func apply(_ dynamic: Dynamic, atTick tick: Int, instrument: Instrument) {
        switch dynamic.playbackRole {
        case let .level(level):
            let velocity = MidiRenderer.effectiveVelocity(level: level, instrument: instrument)
            marks.append(HairpinRamps.DynPoint(tick: tick, velocity: velocity))
            runningVelocity = velocity
            wedgeStartOverride = nil
        case let .accent(level):
            let accent = HairpinRamps.DynPoint(
                tick: tick, velocity: MidiRenderer.effectiveVelocity(level: level, instrument: instrument),
            )
            pendingAccent = (accent, runningVelocity)
            accents.append(accent)
            wedgeStartOverride = WedgeStart(at: tick, tick: tick, velocity: accent.velocity)
        case .none:
            // No effect: no level, no mark, no hold ends here.
            break
        }
    }

    /// The chord at `tick`, `ticks` long: an accent standing on its tick sounds over the whole chord — its graces and
    /// tremolo strokes too — and only over it; MuseScore 4 restores the level at the next segment
    /// (`playbackcontext.cpp:401-405`), here the chord's end.
    mutating func close(chordAt tick: Int, ticks: Int) {
        defer { pendingAccent = nil }
        guard let pending = pendingAccent, pending.accent.tick == tick, ticks > 0 else { return }
        let velocity = pending.accent.velocity
        ramps.append(HairpinRamp(
            startTick: tick, endTick: tick + ticks - 1,
            startVelocity: velocity, endVelocity: velocity, method: .normal, role: .accent,
        ))
        restores.append(HairpinRamps.DynPoint(tick: tick + ticks, velocity: pending.restore))
    }

    /// Where a wedge whose spanner stands at `tick` starts, and from which level: on an accent, from the accent's level
    /// (MuseScore 4's `appliableDynamicLevel` there includes it, `playbackcontext.cpp:600-601`); otherwise at its own
    /// tick from the running level.
    func wedgeStart(at tick: Int) -> (tick: Int, velocity: Int) {
        guard let start = wedgeStartOverride, start.at == tick else { return (tick, runningVelocity) }
        return (start.tick, start.velocity)
    }
}
