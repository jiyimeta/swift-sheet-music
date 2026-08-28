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
    }

    let startTick: Int
    let endTick: Int // inclusive
    let startVelocity: Int // already articulation-scaled
    let endVelocity: Int // already articulation-scaled
    let method: Spanner.HairpinPayload.VeloChangeMethod
    var role: Role = .wedge
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

    /// Latest-starting ramp containing `tick`. Well-formed scores
    /// don't overlap hairpins; this is a defensive choice.
    static func active(in ramps: [HairpinRamp], at tick: Int) -> HairpinRamp? {
        ramps
            .filter { tick >= $0.startTick && tick <= $0.endTick }
            .max(by: { $0.startTick < $1.startTick })
    }

    /// Walk one voice in original (pre-repeat) ticks and resolve every
    /// `<HairPin>` into a concrete `HairpinRamp`. End velocity priority:
    /// (a) `<veloChange>` from the payload, (b) a `Dynamic` anchored on
    /// the hairpin's own end tick *and* pointing the way the wedge does,
    /// (c) no change — a wedge with nothing to aim at is flat. Sign comes
    /// from the subtype (cresc → +, decresc → −) and the final velocity
    /// is clamped to `1...127`.
    static func collect(
        voiceIndex: Int,
        staff: Staff,
        instrument: Instrument,
        division: Int,
    ) -> [HairpinRamp] {
        var dynList: [DynPoint] = []
        var pending: [Pending] = []
        var runningVel = MidiRenderer.effectiveVelocity(
            forDynamic: nil, instrument: instrument,
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
                    runningVel: &runningVel,
                    dynList: &dynList,
                    pending: &pending,
                )
            }
            measureBase += mTicks
        }

        let wedges = resolveChained(pending, dynList: dynList)
        return wedges + holds(after: wedges, dynList: dynList)
    }

    /// Resolve the wedges in tick order, each starting from whatever the
    /// part last reached. A hairpin with no Dynamic of its own picks up
    /// the previous hairpin's end level rather than the last written
    /// mark — MS3's `ChangeMap::cleanupStage3` takes a ramp's start from
    /// "the cached end value if [the previous event] is a ramp".
    private static func resolveChained(
        _ pending: [Pending], dynList: [DynPoint],
    ) -> [HairpinRamp] {
        var resolved: [HairpinRamp] = []
        var reached: (tick: Int, velocity: Int)?
        for p in pending.sorted(by: { $0.startTick < $1.startTick }) {
            var startVelocity = p.startVelocity
            if let reached, reached.tick <= p.startTick {
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
            let nextMark = dynList.first { $0.tick >= from }?.tick ?? Int.max
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
            )
        }
    }

    private struct DynPoint { let tick: Int; let velocity: Int }
    private struct Pending {
        let startTick: Int
        let endTick: Int
        let startVelocity: Int
        let payload: Spanner.HairpinPayload
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
        runningVel: inout Int,
        dynList: inout [DynPoint],
        pending: inout [Pending],
    ) {
        var runningTick = measureBase
        for element in voice.elements {
            switch element {
            case let .dynamic(d):
                let v = MidiRenderer.effectiveVelocity(
                    forDynamic: d, instrument: instrument,
                )
                dynList.append(DynPoint(tick: runningTick, velocity: v))
                runningVel = v
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
                )
                pending.append(Pending(
                    startTick: runningTick,
                    endTick: endTick,
                    startVelocity: runningVel,
                    payload: payload,
                ))
            case let .chord(chord):
                runningTick += chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            default:
                break
            }
        }
    }

    /// Resolve one wedge into the segments it actually plays.
    ///
    /// Every `Dynamic` written under the wedge — inside it or on its end
    /// tick — is a checkpoint: the wedge climbs to that mark, reaching
    /// it on the beat the engraver put it on, and carries on from there
    /// to the next one. So every level this produces is either a mark
    /// the score states or an interpolation between two of them, and a
    /// wedge with no mark to aim at produces no change at all.
    ///
    /// A mark that contradicts the wedge — a crescendo running into a
    /// *quieter* mark — cannot be climbed to, so that stretch stays
    /// flat and the mark still sounds at its own tick; the wedge
    /// resumes from it toward whatever comes next. The direction test
    /// is MS4's (`PlaybackContext::handleHairpin`, `useNominalLevelTo`
    /// requires `isCrescendo ? levelTo > levelFrom : levelTo <
    /// levelFrom`); ending a flat stretch one tick short of the mark
    /// mirrors its `spannerTo -= Fraction::eps()`.
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
    /// `<veloChange>` outranks the marks: it is MS3's own spelling of
    /// the ramp size, handed straight to `ChangeMap::addRamp`, and only
    /// a change of 0 sends MuseScore looking for a neighbouring fix.
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
            )
        }

        if let veloChange = p.payload.veloChange, veloChange != 0 {
            let signed = isCrescendo ? veloChange : -veloChange
            return [segment(
                from: p.startTick, to: p.endTick,
                start: startVelocity,
                end: max(1, min(127, startVelocity + signed)),
            )]
        }

        let checkpoints = dynList
            .filter { $0.tick > p.startTick && $0.tick <= p.endTick }
            .sorted { $0.tick < $1.tick }

        var segments: [HairpinRamp] = []
        var tick = p.startTick
        var velocity = startVelocity
        for mark in checkpoints {
            let level = max(1, min(127, mark.velocity))
            let climbable = isCrescendo ? level > velocity : level < velocity
            if climbable {
                segments.append(segment(
                    from: tick, to: mark.tick, start: velocity, end: level,
                ))
            } else if mark.tick - 1 > tick {
                // Flat up to the mark, which then governs its own note.
                segments.append(segment(
                    from: tick, to: mark.tick - 1,
                    start: velocity, end: velocity,
                ))
            }
            tick = mark.tick
            velocity = level
        }
        // Past the last mark the wedge has nothing left to aim at.
        if tick < p.endTick || segments.isEmpty {
            segments.append(segment(
                from: tick, to: p.endTick, start: velocity, end: velocity,
            ))
        }
        return segments
    }

    /// End tick = startTick + Σ (next-measures-worth of measure ticks)
    /// + nextFractions delta. MuseScore's `<location>` (the `<next>`
    /// child) is **relative to the begin spanner's own tick**, so the
    /// offset is added to `startTick` rather than re-derived from a
    /// measure base: a hairpin written from beat 4 to the next downbeat
    /// carries `<measures>1</measures><fractions>-7/8</fractions>`, and
    /// measuring that from the measure base instead of from beat 4
    /// lands the end before the start. Falls back to `startTick + 1` so
    /// the range stays non-empty.
    ///
    /// Same resolution as `OttavaRanges.computeEndTick` and
    /// `LayoutEngine.endAnchor`.
    private static func computeEndTick(
        startTick: Int,
        startMeasureIndex: Int,
        spanner: Spanner,
        measures: [Measure],
        division: Int,
    ) -> Int {
        var measureSpan = 0
        let endIndex = min(
            measures.count,
            startMeasureIndex + max(0, spanner.nextMeasuresOffset),
        )
        if startMeasureIndex < endIndex {
            let measureDurations = measures.effectiveMeasureDurations()
            for i in startMeasureIndex ..< endIndex {
                let mDuration = i < measureDurations.count
                    ? measureDurations[i]
                    : Fraction(numerator: 4, denominator: 4)
                measureSpan += MidiRenderer.measureTicks(
                    measure: measures[i], division: division,
                    measureDuration: mDuration,
                )
            }
        }
        let fractionDelta = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
        return max(startTick + 1, startTick + measureSpan + fractionDelta)
    }
}
