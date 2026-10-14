import SheetMusicCore
import SheetMusicFoundation

/// One resolved hairpin: a linear (or v1-falls-through-to-linear)
/// velocity ramp between two ticks in the original (pre-repeat)
/// score timeline. Built by `HairpinRamps.collect` and consumed by
/// `MidiRenderer+Voice` at chord onset.
struct HairpinRamp: Equatable {
    /// What the range represents. A `wedge` is an engraved hairpin; a
    /// `hold` is the flat stretch after one, keeping the level it
    /// reached until the next Dynamic. Both resolve by tick through the
    /// same lookup, so consumers need not tell them apart — but callers
    /// counting hairpins do.
    enum Role: Equatable {
        case wedge
        case hold
        /// The chord an accent stands on: its level over that chord alone (`Dynamic.PlaybackRole.accent`). Outranks
        /// every other ramp at its ticks (`HairpinRamps.active(in:at:)`).
        case accent
        /// One step of a two-level dynamic's change (`Dynamic.PlaybackRole.transition`).
        case transition
    }

    let startTick: Int
    let endTick: Int // inclusive
    let startVelocity: Int // already articulation-scaled
    let endVelocity: Int // already articulation-scaled
    let method: Spanner.HairpinPayload.VeloChangeMethod
    var role: Role = .wedge
    /// The ticks of what produced the ramp — a wedge's whole span for its segments and for its hold, a two-level
    /// dynamic's own tick for its steps; `nil` for the ramp's own range (an accent's chord).
    var origin: ClosedRange<Int>?

    /// MuseScore 4 builds its dynamics map in playback order and lays out, for each run of measures, only the hairpins
    /// that overlap it (`PlaybackContext::update`, `engraving/playback/playbackcontext.cpp:324-339`; `handleSpanners`,
    /// `:540-567`): a run starting at original tick `start` hears a ramp produced there or later, or one whose hairpin
    /// reaches past its start.
    func appliesToPass(startingAt start: Int) -> Bool {
        let range = origin ?? startTick ... endTick
        return range.lowerBound >= start || range.upperBound > start
    }
}

enum HairpinRamps {
    /// Linear interpolation. v1: non-`.normal` methods fall through
    /// to the linear branch — leaves an obvious extension point for
    /// future curve work.
    static func interpolate(ramp: HairpinRamp, atOriginalTick tick: Int) -> Int {
        // Order matters for degenerate (start == end) ramps: a tick
        // sitting on both endpoints resolves to endVelocity.
        if tick >= ramp.endTick { return ramp.endVelocity }
        if tick <= ramp.startTick { return ramp.startVelocity }
        let span = max(1, ramp.endTick - ramp.startTick)
        let progress = tick - ramp.startTick
        switch ramp.method {
        case .normal, .easeIn, .easeOut, .easeInOut, .exponential: // v1: linear-only
            let delta = ramp.endVelocity - ramp.startVelocity
            // Round-half-away-from-zero so symmetric cresc/decresc match.
            let scaled = delta * progress
            let rounded = (scaled + (scaled >= 0 ? span / 2 : -span / 2)) / span
            return ramp.startVelocity + rounded
        }
    }

    /// The ramp in force at `tick`: an accent's, which outranks the rest — an accent sounds over a wedge or a hold, as
    /// a mark under a wedge does (`resolveRamp`) — else the latest-starting ramp containing it (well-formed scores do
    /// not overlap hairpins; this is a defensive choice; of two starting together, the first in `collect`'s order).
    static func active(in ramps: [HairpinRamp], at tick: Int) -> HairpinRamp? {
        let containing = ramps.filter { tick >= $0.startTick && tick <= $0.endTick }
        if let accent = containing.first(where: { $0.role == .accent }) { return accent }
        return containing.max(by: { $0.startTick < $1.startTick })
    }

    /// Walk one voice in original (pre-repeat) ticks and resolve every `<HairPin>` into a concrete `HairpinRamp`. The
    /// end velocity is MuseScore 4's — see `resolveRamp`. Sign comes from the subtype (cresc → +, decresc → −) and the
    /// final velocity is clamped to `1...127`.
    static func collect(
        voiceIndex: Int,
        staff: Staff,
        instrument: Instrument,
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> [HairpinRamp] {
        var walk = DynamicsWalk(
            runningVelocity: MidiRenderer.effectiveVelocity(forDynamic: nil, instrument: instrument),
        )
        var measureBase = 0
        let measureDurations = staff.measures.effectiveMeasureDurations()

        for (measureIdx, measure) in staff.measures.enumerated() {
            let measureDuration = measureIdx < measureDurations.count
                ? measureDurations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
            let mTicks = MidiRenderer.measureTicks(
                measure: measure, division: division,
                measureDuration: measureDuration,
                measureIndex: measureIdx, tempoMap: tempoMap,
            )
            // Read the literal voice — hairpins inside a
            // measure-repeat source apply each time the group plays
            // back, and the runtime override re-uses the original
            // tick anyway.
            if voiceIndex < measure.voices.count {
                walkVoice(
                    measure.voices[voiceIndex],
                    measureIdx: measureIdx,
                    measureBase: measureBase,
                    measureDuration: measureDuration,
                    instrument: instrument,
                    measures: staff.measures,
                    division: division,
                    tempoMap: tempoMap,
                    walk: &walk,
                )
            }
            measureBase += mTicks
        }

        // A wedge ending on an accent aims for the accent's level (MuseScore 4's `findNominalEndDynamicLevel`,
        // `playbackcontext.cpp:124-142`); an accent anywhere else is no mark for a wedge. The level coming back after
        // an accent's chord ends a hold, as a mark does (`DynamicsWalk.restores`).
        let endingAccents = walk.accents.filter { accent in walk.pending.contains { $0.endTick == accent.tick } }
        let targets = endingAccents.isEmpty ? walk.marks : (walk.marks + endingAccents).sorted { $0.tick < $1.tick }
        let wedges = resolveChained(walk.pending, dynList: targets)
        let holdEnds = walk.restores.isEmpty ? walk.marks : (walk.marks + walk.restores).sorted { $0.tick < $1.tick }
        return wedges + holds(after: wedges, dynList: holdEnds) + walk.ramps
    }

    /// Resolve the wedges in tick order, each starting from whatever the
    /// part last reached. A hairpin with no Dynamic of its own picks up
    /// the previous hairpin's end level rather than the last written
    /// mark — MS3's `ChangeMap::cleanupStage3` takes a ramp's start from
    /// "the cached end value if [the previous event] is a ramp". One
    /// starting on an accent or a two-level dynamic starts from that
    /// dynamic, as MuseScore 4's `appliableDynamicLevel` does there
    /// (`playbackcontext.cpp:576-601`).
    private static func resolveChained(
        _ pending: [Pending], dynList: [DynPoint],
    ) -> [HairpinRamp] {
        var resolved: [HairpinRamp] = []
        var reached: (tick: Int, velocity: Int)?
        for p in pending.sorted(by: { $0.startTick < $1.startTick }) {
            var startVelocity = p.startVelocity
            if !p.startsOnItsDynamic, let reached, reached.tick <= p.startTick {
                let lastMark = dynList
                    .last { $0.tick <= p.startTick }?.tick ?? Int.min
                if reached.tick > lastMark { startVelocity = reached.velocity }
            }
            let segments = resolveRamp(
                p, startVelocity: startVelocity, dynList: dynList,
            )
            resolved.append(contentsOf: segments)
            if let last = segments.last {
                reached = (last.endTick, last.endVelocity)
            }
        }
        return resolved
    }

    /// The level a wedge reaches is where the part stays until the next
    /// Dynamic — a crescendo is not undone by its own last note. MS3's
    /// `ChangeMap::val` returns `cachedEndVal` for every tick past a ramp
    /// until the next event; MS4 writes the ramp's levels into the same
    /// dynamics map the following notes read.
    ///
    /// Modelled as a flat ramp rather than as state carried by the voice
    /// walker so that every consumer — chords, tremolo strokes, anything
    /// that resolves velocity by tick — holds the level without knowing
    /// it has to.
    private static func holds(
        after wedges: [HairpinRamp], dynList: [DynPoint],
    ) -> [HairpinRamp] {
        wedges.compactMap { wedge in
            let from = wedge.endTick + 1
            // A two-level dynamic the wedge ends on moves on to its second level by itself: nothing holds after it.
            let nextMark = dynList.first {
                $0.tick >= from || ($0.startsTransition && $0.tick >= wedge.endTick)
            }?.tick ?? Int.max
            // From `wedge.endTick`, not from `from`: a wedge split at its
            // checkpoints hands off to the next segment either on its own
            // end tick or one past it, and both must cancel the hold
            // rather than let it shadow the segment that follows.
            let nextWedge = wedges
                .lazy.map(\.startTick).filter { $0 >= wedge.endTick }.min() ?? Int.max
            let until = min(nextMark, nextWedge) - 1
            guard until >= from else { return nil }
            return HairpinRamp(
                startTick: from,
                endTick: until,
                startVelocity: wedge.endVelocity,
                endVelocity: wedge.endVelocity,
                method: .normal,
                role: .hold,
                origin: wedge.origin,
            )
        }
    }

    struct DynPoint {
        let tick: Int
        let velocity: Int
        /// A two-level dynamic's mark: the level a wedge ending on it aims for is its first, and it moves on to its
        /// second by itself, so no hold follows a wedge ending on it.
        var startsTransition = false
    }

    struct Pending {
        let startTick: Int
        let endTick: Int
        let startVelocity: Int
        let payload: Spanner.HairpinPayload
        /// The wedge starts on an accent or a two-level dynamic, from that dynamic's level, which no earlier wedge's
        /// end replaces (`resolveChained`).
        var startsOnItsDynamic = false
    }

    // swiftlint:disable:next function_parameter_count
    private static func walkVoice(
        _ voice: Voice,
        measureIdx: Int,
        measureBase: Int,
        measureDuration: Fraction,
        instrument: Instrument,
        measures: [Measure],
        division: Int,
        tempoMap: ResolvedTempoMap,
        walk: inout DynamicsWalk,
    ) {
        var runningTick = measureBase
        for element in voice.elements {
            switch element {
            case let .dynamic(d):
                let bps = tempoMap.beatsPerSecond(atMeasure: measureIdx, tickInMeasure: runningTick - measureBase)
                walk.apply(d, atTick: runningTick, instrument: instrument, beatsPerSecond: bps, division: division)
            case let .spanner(s) where s.kind == .hairpin:
                // Only the begin-side spanner carries a non-nil
                // payload. End-side placeholders (`<prev>` only) have
                // hairpin == nil and must NOT be treated as a new
                // ramp — otherwise they create a phantom zero-length
                // hairpin that overrides the real ramp's endpoint.
                guard let payload = s.hairpin else { break }
                let endTick = computeEndTick(
                    startTick: runningTick,
                    startMeasureIndex: measureIdx,
                    spanner: s,
                    measures: measures,
                    division: division,
                    tempoMap: tempoMap,
                )
                // A wedge starting on an accent starts from its level (`DynamicsWalk.wedgeStart`). One that would start
                // at or past its own end plays nothing, as MuseScore's does (`playbackcontext.cpp:626-629`).
                let start = walk.wedgeStart(at: runningTick)
                guard start.tick < endTick else { break }
                walk.pending.append(Pending(
                    startTick: start.tick,
                    endTick: endTick,
                    startVelocity: start.velocity,
                    payload: payload,
                    startsOnItsDynamic: walk.wedgeStartsOnItsDynamic(at: runningTick),
                ))
            case let .chord(chord):
                let ticks = chord.duration.resolved(in: measureDuration).ticks(division: division)
                walk.close(chordAt: runningTick, ticks: ticks)
                runningTick += ticks
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            default:
                break
            }
        }
    }

    /// Resolve one wedge into the segments it actually plays.
    ///
    /// Every `Dynamic` written under the wedge — inside it or on its end tick — is a checkpoint: the wedge climbs to
    /// that mark, reaching it on the beat the engraver put it on, and carries on from there to the next one. Past its
    /// last mark the wedge ends where MuseScore 4 ends it (below).
    ///
    /// A mark that contradicts the wedge — a crescendo running into a *quieter* mark — cannot be climbed to, so that
    /// stretch stays flat (on the wedge's end tick it climbs one level instead, below) and the mark still sounds at
    /// its own tick; the wedge resumes from it toward whatever comes next. The direction test is MS4's
    /// (`PlaybackContext::handleHairpin`, `useNominalLevelTo` requires `isCrescendo ? levelTo > levelFrom : levelTo <
    /// levelFrom`); ending a flat stretch one tick short of the mark mirrors its `spannerTo -= Fraction::eps()`.
    ///
    /// Neither MuseScore plays the marks under a wedge, and both lose
    /// what the engraver wrote doing it. MS3 erases every dynamic
    /// enclosed in a hairpin (`ChangeMap::cleanupStage1`: "remove any
    /// ramps **or fixes** that are completely enclosed within other
    /// ramps"), so `ppp` cresc `pp` `mf` `f` plays as a smooth 16 → 96
    /// with the middle marks silent — and a wedge over `pp` then `ff`
    /// with nothing at its end loses both marks *and* the ramp. MS4's
    /// live playback overwrites them with the hairpin's own dynamics
    /// curve: rendering such a score to audio from MuseScore 4 produces
    /// a waveform identical to the same score with the marks deleted.
    /// MS4's MIDI export keeps them (its `VelocityMap` has no
    /// erase-enclosed-fixes branch) but plateaus between them rather
    /// than climbing.
    ///
    /// The end is MuseScore 4's (`PlaybackContext::handleHairpin`, `playbackcontext.cpp:603-624`): the dynamic on the
    /// wedge's end tick when it lies in the wedge's direction; otherwise one of MuseScore 4's levels past the wedge's
    /// start (`MuseScoreDynamicLevels.oneStep`), stopping one tick short of an end dynamic that went the other way.
    /// `<veloChange>` — MuseScore 3's spelling of the ramp's size — is not read: MuseScore 4 ignores it.
    private static func resolveRamp(
        _ p: Pending, startVelocity: Int, dynList: [DynPoint],
    ) -> [HairpinRamp] {
        let isCrescendo = p.payload.subtype.isCrescendo
        func segment(from: Int, to: Int, start: Int, end: Int) -> HairpinRamp {
            HairpinRamp(
                startTick: from,
                endTick: max(from + 1, to),
                startVelocity: start,
                endVelocity: end,
                method: p.payload.veloChangeMethod,
                origin: p.startTick ... p.endTick,
            )
        }

        let checkpoints = dynList
            .filter { $0.tick > p.startTick && $0.tick <= p.endTick }
            .sorted { $0.tick < $1.tick }

        // MuseScore 4 aims a wedge at the dynamic on its end when that dynamic lies in its direction, and otherwise one
        // of its levels past where the wedge starts (`handleHairpin`, `playbackcontext.cpp:603-615`).
        let stepTarget = MuseScoreDynamicLevels.oneStep(from: startVelocity, up: isCrescendo)
        func climbs(to level: Int, from velocity: Int) -> Bool {
            isCrescendo ? level > velocity : level < velocity
        }
        var segments: [HairpinRamp] = []
        var tick = p.startTick
        var velocity = startVelocity
        for mark in checkpoints {
            let level = max(1, min(127, mark.velocity))
            if climbs(to: level, from: velocity) {
                segments.append(segment(from: tick, to: mark.tick, start: velocity, end: level))
            } else if mark.tick == p.endTick, climbs(to: stepTarget, from: velocity) {
                // An end dynamic against the wedge: one level, up to just short of the dynamic, which then governs its
                // own note (`spannerTo -= Fraction::eps()`, `playbackcontext.cpp:617-624`).
                segments.append(segment(from: tick, to: mark.tick - 1, start: velocity, end: stepTarget))
            } else if mark.tick - 1 > tick {
                // Flat up to the mark, which then governs its own note.
                segments.append(segment(from: tick, to: mark.tick - 1, start: velocity, end: velocity))
            }
            tick = mark.tick
            velocity = level
        }
        // No dynamic at the end: one level past where the wedge started, unless its checkpoints already took it there.
        if tick < p.endTick || segments.isEmpty {
            let end = climbs(to: stepTarget, from: velocity) ? stepTarget : velocity
            segments.append(segment(from: tick, to: p.endTick, start: velocity, end: end))
        }
        return segments
    }
}
