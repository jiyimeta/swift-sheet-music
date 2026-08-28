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
    static let defaultDeltaVelocity = 10

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
    /// (c) ±10 default. Sign comes from the subtype (cresc → +,
    /// decresc → −) and the final velocity is clamped to `1...127`.
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

        let resolved = resolveChained(pending, dynList: dynList)
        let wedges = resolved.map(\.ramp)
        return wedges + holds(
            after: resolved.filter(\.endIsWritten).map(\.ramp),
            wedges: wedges,
            dynList: dynList,
        )
    }

    /// Resolve the wedges in tick order, each starting from whatever the
    /// part last reached. A hairpin with no Dynamic of its own picks up
    /// the previous hairpin's end level rather than the last written
    /// mark — MS3's `ChangeMap::cleanupStage3` takes a ramp's start from
    /// "the cached end value if [the previous event] is a ramp".
    private static func resolveChained(
        _ pending: [Pending], dynList: [DynPoint],
    ) -> [Resolved] {
        var resolved: [Resolved] = []
        var reached: (tick: Int, velocity: Int)?
        for p in pending.sorted(by: { $0.startTick < $1.startTick }) {
            var startVelocity = p.startVelocity
            if let reached, reached.tick <= p.startTick {
                let lastMark = dynList
                    .last { $0.tick <= p.startTick }?.tick ?? Int.min
                if reached.tick > lastMark { startVelocity = reached.velocity }
            }
            let one = resolveRamp(
                p, startVelocity: startVelocity, dynList: dynList,
            )
            resolved.append(one)
            reached = one.endIsWritten
                ? (one.ramp.endTick, one.ramp.endVelocity)
                : reached
        }
        return resolved
    }

    /// A resolved wedge plus whether its end level came from the score
    /// or from us.
    ///
    /// `endIsWritten` is true when the engraver said where the wedge
    /// lands — a Dynamic anchored on its end tick, or an explicit
    /// `<veloChange>`. It is false for the `defaultDeltaVelocity` guess,
    /// which stands in for a target the score never states.
    ///
    /// The distinction governs how far that level travels. A level the
    /// score states holds until the next mark and the next wedge starts
    /// from it, as in MuseScore. A level we guessed stays inside its own
    /// wedge: MS3 never propagates one (it has no default step at all —
    /// `veloChange` defaults to 0 and `ChangeMap` flattens what it
    /// cannot resolve), and while MS4 does hold its default step, doing
    /// so compounds. Real charts carry a dozen `cresc.` wedges and not
    /// one dynamic; holding a guess there ratchets the whole part up by
    /// a step per wedge and never comes down, which is neither what the
    /// engraver wrote nor what either MuseScore exports.
    private struct Resolved {
        let ramp: HairpinRamp
        let endIsWritten: Bool
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
        after held: [HairpinRamp], wedges: [HairpinRamp], dynList: [DynPoint],
    ) -> [HairpinRamp] {
        held.compactMap { wedge in
            let from = wedge.endTick + 1
            let nextMark = dynList.first { $0.tick >= from }?.tick ?? Int.max
            let nextWedge = wedges
                .lazy.map(\.startTick).filter { $0 >= from }.min() ?? Int.max
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

    /// The end level a hairpin reaches, and the tick it reaches it on.
    ///
    /// Only a `Dynamic` sitting on the hairpin's own end tick can serve
    /// as its target, and only when it points the way the wedge does.
    /// Both restrictions are MuseScore's: MS4 reads the end level off
    /// the dynamic *snapped to the last hairpin segment*
    /// (`PlaybackContext::findNominalEndDynamicType`) and adopts it only
    /// when `isCrescendo ? levelTo > levelFrom : levelTo < levelFrom`,
    /// falling back to a single dynamic step otherwise. MS3 arrives at
    /// the same place from the other side: `ChangeMap::cleanupStage3`
    /// will happily read a distant fix, then flattens the ramp whenever
    /// the two disagree about direction. A crescendo must never ramp
    /// *down* — the wedge, not the next mark in the part, says which way
    /// this passage goes.
    ///
    /// An unusable dynamic on the end tick still owns its own note, so
    /// the ramp stops one tick short of it, mirroring MS4's
    /// `spannerTo -= Fraction::eps()`.
    private static func resolveRamp(
        _ p: Pending, startVelocity: Int, dynList: [DynPoint],
    ) -> Resolved {
        let isCrescendo = p.payload.subtype.isCrescendo
        func stepped(by delta: Int) -> Int {
            max(1, min(127, startVelocity + (isCrescendo ? delta : -delta)))
        }
        let anchored = dynList.first { $0.tick == p.endTick }
        let adoptable = anchored.map {
            isCrescendo ? $0.velocity > startVelocity : $0.velocity < startVelocity
        } ?? false

        let endVel: Int
        let endIsWritten: Bool
        if let veloChange = p.payload.veloChange, veloChange != 0 {
            // MS3's own spelling of the ramp size (`Score::updateHairpin`
            // hands it straight to `ChangeMap::addRamp`); only a change of
            // 0 sends MuseScore looking for a neighbouring fix.
            endVel = stepped(by: veloChange)
            endIsWritten = true
        } else if adoptable, let anchored {
            endVel = max(1, min(127, anchored.velocity))
            endIsWritten = true
        } else {
            endVel = stepped(by: defaultDeltaVelocity)
            endIsWritten = false
        }

        let endTick = anchored != nil && !adoptable
            ? max(p.startTick + 1, p.endTick - 1)
            : p.endTick
        return Resolved(
            ramp: HairpinRamp(
                startTick: p.startTick,
                endTick: endTick,
                startVelocity: startVelocity,
                endVelocity: endVel,
                method: p.payload.veloChangeMethod,
            ),
            endIsWritten: endIsWritten,
        )
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
