import SheetMusicCore
import SheetMusicFoundation

/// What `HairpinRamps.collect` gathers from one voice's dynamics, read through `Dynamic.playbackRole`: the running
/// level a wedge starts from, the marks a wedge aims for and a hold stops at, the wedges waiting to be resolved, and
/// the ramps a dynamic sounds by itself — an accent over its chord, a two-level change's steps.
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

    /// One dynamic at `tick`, in the voice's original (pre-repeat) ticks. `beatsPerSecond` is the tempo map's where it
    /// stands (a two-level change's length).
    mutating func apply(
        _ dynamic: Dynamic, atTick tick: Int, instrument: Instrument, beatsPerSecond: Double, division: Int,
    ) {
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
        case let .transition(from, to):
            let fromVelocity = MidiRenderer.effectiveVelocity(level: from, instrument: instrument)
            let toVelocity = MidiRenderer.effectiveVelocity(level: to, instrument: instrument)
            let length = dynamic.velocityChangeTicks(beatsPerSecond: beatsPerSecond, division: division)
            ramps += Self.transitionRamps(from: fromVelocity, to: toVelocity, ticks: length, at: tick)
            // A wedge ending here aims for the first level (`findNominalEndDynamicLevel`,
            // `playbackcontext.cpp:136-139`); one starting here starts once the change is done, from the second
            // (`:576-593`).
            marks.append(HairpinRamps.DynPoint(tick: tick, velocity: fromVelocity, startsTransition: true))
            runningVelocity = toVelocity
            wedgeStartOverride = WedgeStart(at: tick, tick: tick + length, velocity: toVelocity)
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
    /// (MuseScore 4's `appliableDynamicLevel` there includes it, `playbackcontext.cpp:600-601`); on a two-level
    /// dynamic, once its change is done, from its second level (`playbackcontext.cpp:576-593`); otherwise at its own
    /// tick from the running level.
    func wedgeStart(at tick: Int) -> (tick: Int, velocity: Int) {
        guard let start = wedgeStartOverride, start.at == tick else { return (tick, runningVelocity) }
        return (start.tick, start.velocity)
    }

    /// Whether a wedge whose spanner stands at `tick` starts on an accent or a two-level dynamic — from that dynamic's
    /// level, which no earlier wedge's end replaces (`HairpinRamps.resolveChained`).
    func wedgeStartsOnItsDynamic(at tick: Int) -> Bool {
        wedgeStartOverride?.at == tick
    }

    /// A two-level change's steps (`Dynamic.transitionSteps`), each a flat ramp from its offset to the next one's; the
    /// level it lands on is the running level from then on and needs none.
    static func transitionRamps(from: Int, to: Int, ticks: Int, at tick: Int) -> [HairpinRamp] {
        let steps = Dynamic.transitionSteps(from: from, to: to, ticks: ticks)
        return zip(steps, steps.dropFirst()).compactMap { step, next -> HairpinRamp? in
            guard next.offset > step.offset else { return nil }
            return HairpinRamp(
                startTick: tick + step.offset, endTick: tick + next.offset - 1,
                startVelocity: step.velocity, endVelocity: step.velocity, method: .normal, role: .transition,
            )
        }
    }
}
