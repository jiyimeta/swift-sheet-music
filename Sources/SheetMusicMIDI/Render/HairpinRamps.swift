import SheetMusicCore
import SheetMusicFoundation

/// One resolved hairpin: a linear (or v1-falls-through-to-linear)
/// velocity ramp between two ticks in the original (pre-repeat)
/// score timeline. Built by `HairpinRamps.collect` and consumed by
/// `MidiRenderer+Voice` at chord onset.
struct HairpinRamp: Equatable {
    let startTick: Int
    let endTick: Int // inclusive
    let startVelocity: Int // already articulation-scaled
    let endVelocity: Int // already articulation-scaled
    let method: Spanner.HairpinPayload.VeloChangeMethod
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

        return pending.map { resolveRamp($0, dynList: dynList) }
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
    private static func resolveRamp(_ p: Pending, dynList: [DynPoint]) -> HairpinRamp {
        let isCrescendo = p.payload.subtype.isCrescendo
        func stepped(by delta: Int) -> Int {
            max(1, min(127, p.startVelocity + (isCrescendo ? delta : -delta)))
        }
        let anchored = dynList.first { $0.tick == p.endTick }
        let adoptable = anchored.map {
            isCrescendo ? $0.velocity > p.startVelocity : $0.velocity < p.startVelocity
        } ?? false

        let endVel: Int
        if let veloChange = p.payload.veloChange, veloChange != 0 {
            // MS3's own spelling of the ramp size (`Score::updateHairpin`
            // hands it straight to `ChangeMap::addRamp`); only a change of
            // 0 sends MuseScore looking for a neighbouring fix.
            endVel = stepped(by: veloChange)
        } else if adoptable, let anchored {
            endVel = max(1, min(127, anchored.velocity))
        } else {
            endVel = stepped(by: defaultDeltaVelocity)
        }

        let endTick = anchored != nil && !adoptable
            ? max(p.startTick + 1, p.endTick - 1)
            : p.endTick
        return HairpinRamp(
            startTick: p.startTick,
            endTick: endTick,
            startVelocity: p.startVelocity,
            endVelocity: endVel,
            method: p.payload.veloChangeMethod,
        )
    }

    /// Hairpin end tick = (start measure base + nextMeasures-worth of
    /// measure ticks) + nextFractions delta. When both offsets are
    /// zero we still need a usable end tick; default to start +
    /// remainder of the start measure (one beat fallback if even
    /// that is zero).
    private static func computeEndTick(
        startTick: Int,
        startMeasureIndex: Int,
        spanner: Spanner,
        measures: [Measure],
        division: Int,
    ) -> Int {
        // Sum measure-ticks from the start measure forward by
        // `nextMeasuresOffset` measures. The end tick is therefore the
        // base of measure (start + offset).
        let measureDurations = measures.effectiveMeasureDurations()
        func mDuration(_ i: Int) -> Fraction {
            i < measureDurations.count
                ? measureDurations[i]
                : Fraction(numerator: 4, denominator: 4)
        }
        var endMeasureBase = 0
        for i in 0 ..< startMeasureIndex {
            endMeasureBase += MidiRenderer.measureTicks(
                measure: measures[i], division: division,
                measureDuration: mDuration(i),
            )
        }
        let lastIndex = min(
            measures.count - 1,
            startMeasureIndex + max(0, spanner.nextMeasuresOffset),
        )
        for i in startMeasureIndex ..< lastIndex {
            endMeasureBase += MidiRenderer.measureTicks(
                measure: measures[i], division: division,
                measureDuration: mDuration(i),
            )
        }
        let fractionDelta = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
        let computed = endMeasureBase + fractionDelta
        if computed > startTick { return computed }
        // Defensive fallback: ensure endTick > startTick so
        // `interpolate` always sees a valid span.
        return startTick + 1
    }
}
