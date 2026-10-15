import SheetMusicCore
import SheetMusicFoundation

/// What one voice's walk gathers from the dynamics that reach it (`HairpinRamps.timeline`), read through
/// `Dynamic.playbackRole`: the running level a wedge starts from, the marks a wedge aims for and a hold stops at, the
/// wedges waiting to be resolved, and the ramps a dynamic sounds by itself — an accent over its chord, a two-level
/// change's steps.
struct DynamicsWalk {
    /// A wedge whose spanner stands at `at` starts at `tick`, from `velocity`. A two-level dynamic moves the start only
    /// for a hairpin written in its own track (`ownTrack`), as MuseScore reads the start segment's dynamic of the
    /// hairpin's track (`playbackcontext.cpp:576-593`); one written elsewhere starts on the tick, from the first level
    /// in force there (`elsewhereVelocity`). An accent's level is in force on every track it reaches (`ownTrack` nil).
    struct WedgeStart {
        let at: Int
        let tick: Int
        let velocity: Int
        let ownTrack: PartTrack?
        let elsewhereVelocity: Int
    }

    var runningVelocity: Int
    var marks: [HairpinRamps.DynPoint] = []
    /// The level each dynamic puts in force from its tick on — an ordinary one's, a two-level one's second — what a
    /// chord plays when no ramp is in force (`DynamicsTimeline`).
    var levels: [HairpinRamps.DynPoint] = []
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

    /// One dynamic written in `track` at `tick`, in the voice's original (pre-repeat) ticks. `beatsPerSecond` is the
    /// tempo map's where it stands (a two-level change's length). Of two dynamics on one tick, the later stands there —
    /// `PartDynamicEvent.appliesBefore` puts MuseScore's winner (`applyDynamic`) last.
    mutating func apply(
        _ dynamic: Dynamic, atTick tick: Int, track: PartTrack, instrument: Instrument, beatsPerSecond: Double,
        division: Int,
    ) {
        switch dynamic.playbackRole {
        case let .level(level):
            let velocity = MidiRenderer.effectiveVelocity(level: level, instrument: instrument)
            if overrule(transitionAt: tick, with: velocity, track: track) { return }
            supersede(at: tick)
            marks.append(HairpinRamps.DynPoint(tick: tick, velocity: velocity, track: track))
            levels.append(HairpinRamps.DynPoint(tick: tick, velocity: velocity, track: track))
            runningVelocity = velocity
            wedgeStartOverride = nil
        case let .accent(level):
            let velocity = MidiRenderer.effectiveVelocity(level: level, instrument: instrument)
            let accent = HairpinRamps.DynPoint(tick: tick, velocity: velocity, track: track)
            pendingAccent = (accent, runningVelocity)
            accents.append(accent)
            wedgeStartOverride = WedgeStart(
                at: tick, tick: tick, velocity: accent.velocity, ownTrack: nil, elsewhereVelocity: accent.velocity,
            )
        case let .transition(from, to):
            supersede(at: tick)
            let fromVelocity = MidiRenderer.effectiveVelocity(level: from, instrument: instrument)
            let toVelocity = MidiRenderer.effectiveVelocity(level: to, instrument: instrument)
            let length = dynamic.velocityChangeTicks(beatsPerSecond: beatsPerSecond, division: division)
            ramps += Self.transitionRamps(from: fromVelocity, to: toVelocity, ticks: length, at: tick)
            // A wedge ending here aims for the first level (`findNominalEndDynamicLevel`,
            // `playbackcontext.cpp:136-139`); one starting here starts once the change is done, from the second
            // (`:576-593`).
            marks.append(
                HairpinRamps.DynPoint(tick: tick, velocity: fromVelocity, startsTransition: true, track: track),
            )
            levels.append(HairpinRamps.DynPoint(tick: tick, velocity: toVelocity, track: track))
            runningVelocity = toVelocity
            wedgeStartOverride = WedgeStart(
                at: tick, tick: tick + length, velocity: toVelocity, ownTrack: track, elsewhereVelocity: fromVelocity,
            )
        case .none:
            // No effect: no level, no mark, no hold ends here.
            break
        }
    }

    /// One part event (`PartDynamicEvent`): a dynamic at the tempo where it stands, or a hairpin from where
    /// `wedgeStart` says — one that would start at or past its own end plays nothing, as MuseScore's does
    /// (`playbackcontext.cpp:626-629`).
    mutating func apply(
        _ event: PartDynamicEvent, instrument: Instrument, division: Int, tempoMap: ResolvedTempoMap,
    ) {
        switch event.payload {
        case let .dynamic(dynamic):
            let bps = tempoMap.beatsPerSecond(atMeasure: event.measureIndex, tickInMeasure: event.tickInMeasure)
            apply(
                dynamic, atTick: event.tick, track: event.track, instrument: instrument, beatsPerSecond: bps,
                division: division,
            )
        case let .hairpin(payload, endTick):
            let start = wedgeStart(at: event.tick, writtenIn: event.track)
            guard start.tick < endTick else { return }
            pending.append(HairpinRamps.Pending(
                startTick: start.tick, endTick: endTick, startVelocity: start.velocity, payload: payload,
                startsOnItsDynamic: wedgeStartsOnItsDynamic(at: event.tick, writtenIn: event.track),
                source: event.source,
            ))
        }
    }

    /// The wedges of the hairpins written in `track`, each resolved once, on that track, as MuseScore resolves it
    /// (`handleHairpin`, `playbackcontext.cpp:569-647`): it starts from the level every dynamic reaching the track put
    /// in force, and it climbs only to the dynamics written in the track itself — a hairpin's end dynamic is one in its
    /// own track (`HairpinSegment::findEndDynamicOrExpression`, `dom/hairpin.cpp:415-450`). Keyed by the hairpin.
    func resolvedWedges(writtenIn track: PartTrack) -> [PartDynamicEvent.Source: [HairpinRamp]] {
        let own = pending.filter { $0.source?.track == track }
        let ownMarks = marks.filter { $0.track == track }
        // A wedge ending on an accent aims for the accent's level (MuseScore 4's `findNominalEndDynamicLevel`,
        // `playbackcontext.cpp:124-142`); an accent anywhere else is no mark for a wedge.
        let endingAccents = accents.filter { accent in
            accent.track == track && own.contains { $0.endTick == accent.tick }
        }
        let targets = endingAccents.isEmpty ? ownMarks : (ownMarks + endingAccents).sorted { $0.tick < $1.tick }
        var wedges: [PartDynamicEvent.Source: [HairpinRamp]] = [:]
        for (wedge, segments) in HairpinRamps.resolveChained(own, dynList: targets, stops: marks) {
            if let source = wedge.source { wedges[source] = segments }
        }
        return wedges
    }

    /// The voice's timeline: `wedges` — every hairpin reaching it, as resolved where it is written — the holds after
    /// them, which last until a dynamic reaching this voice, and the dynamics' own ramps. The level coming back after
    /// an accent's chord ends a hold, as a mark does (`restores`).
    func timeline(initialVelocity: Int, wedges: [HairpinRamp]) -> DynamicsTimeline {
        let holdEnds = restores.isEmpty ? marks : (marks + restores).sorted { $0.tick < $1.tick }
        let allRamps = wedges + HairpinRamps.holds(after: wedges, dynList: holdEnds) + ramps
        return DynamicsTimeline(ramps: allRamps, levels: levels, initialVelocity: initialVelocity)
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

    /// Where a wedge whose spanner stands at `tick` in `track` starts, and from which level: on an accent, from the
    /// accent's level (MuseScore 4's `appliableDynamicLevel` there includes it, `playbackcontext.cpp:600-601`); on a
    /// two-level dynamic of its own track, once its change is done, from its second level
    /// (`playbackcontext.cpp:576-593`), on one written elsewhere at its tick from its first; otherwise at its own tick
    /// from the running level.
    func wedgeStart(at tick: Int, writtenIn track: PartTrack) -> (tick: Int, velocity: Int) {
        guard let start = wedgeStartOverride, start.at == tick else { return (tick, runningVelocity) }
        if let ownTrack = start.ownTrack, ownTrack != track { return (tick, start.elsewhereVelocity) }
        return (start.tick, start.velocity)
    }

    /// Whether a wedge whose spanner stands at `tick` in `track` starts on an accent or on a two-level dynamic of its
    /// own track — from that dynamic's level, which no earlier wedge's end replaces (`HairpinRamps.resolveChained`).
    func wedgeStartsOnItsDynamic(at tick: Int, writtenIn track: PartTrack) -> Bool {
        guard let start = wedgeStartOverride, start.at == tick else { return false }
        return start.ownTrack == nil || start.ownTrack == track
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
                origin: tick ... tick,
            )
        }
    }

    /// An earlier dynamic on `tick` loses the tick to a later one: its mark and level, and an accent's chord, which the
    /// later level overwrites (`applyDynamic`, `playbackcontext.cpp:831-835`).
    private mutating func supersede(at tick: Int) {
        if marks.last?.tick == tick { marks.removeLast() }
        if levels.last?.tick == tick { levels.removeLast() }
        if pendingAccent?.accent.tick == tick {
            pendingAccent = nil
            accents.removeAll { $0.tick == tick }
        }
    }

    /// A level on the tick of a two-level change that came before it overrules the change's first step only: its later
    /// steps, and the second level they land on, still follow, as each is a later write of its own
    /// (`updateDynamicMap`, `playbackcontext.cpp:410-427`). Returns whether there was such a change.
    private mutating func overrule(transitionAt tick: Int, with velocity: Int, track: PartTrack) -> Bool {
        guard let first = ramps.lastIndex(where: {
            $0.role == .transition && $0.startTick == tick && $0.origin?.lowerBound == tick
        }) else { return false }
        let step = ramps[first]
        ramps[first] = HairpinRamp(
            startTick: step.startTick, endTick: step.endTick, startVelocity: velocity, endVelocity: velocity,
            method: .normal, role: .transition, origin: step.origin,
        )
        if marks.last?.tick == tick { marks.removeLast() }
        // Still a change's mark: it moves on to its second level by itself, so no hold follows a wedge ending on it.
        marks.append(HairpinRamps.DynPoint(tick: tick, velocity: velocity, startsTransition: true, track: track))
        return true
    }
}

extension HairpinRamps {
    /// The level a jump carries from `tick`, the last of the run it leaves: the ramp in force there, else `running` —
    /// but never an accent's, which MuseScore 4 has already restored by the next segment, the jump's target
    /// (`playbackcontext.cpp:401-405`).
    static func levelToCarry(at tick: Int, ramps: [HairpinRamp], running: Int) -> Int {
        let ramp = active(in: ramps.filter { $0.role != .accent }, at: tick)
        return ramp.map { interpolate(ramp: $0, atOriginalTick: tick) } ?? running
    }
}
