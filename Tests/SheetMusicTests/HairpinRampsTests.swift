@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct HairpinRampsTests {
    private func ramp(
        startTick: Int = 0,
        endTick: Int = 480,
        startVelocity: Int = 60,
        endVelocity: Int = 112,
        method: Spanner.HairpinPayload.VeloChangeMethod = .normal,
    ) -> HairpinRamp {
        HairpinRamp(
            startTick: startTick,
            endTick: endTick,
            startVelocity: startVelocity,
            endVelocity: endVelocity,
            method: method,
        )
    }

    @Test func interpolateLinearMidpoint() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 240) == 80)
    }

    @Test func interpolateClampsBeforeStart() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: -100) == 60)
    }

    @Test func interpolateClampsAfterEnd() {
        let r = ramp(startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 1000) == 100)
    }

    @Test func interpolateSingleTickSpanReturnsEnd() {
        let r = ramp(startTick: 480, endTick: 480, startVelocity: 60, endVelocity: 100)
        #expect(HairpinRamps.interpolate(ramp: r, atOriginalTick: 480) == 100)
    }

    @Test func nonNormalMethodsFallThroughToLinear() {
        for method: Spanner.HairpinPayload.VeloChangeMethod in
            [.easeIn, .easeOut, .easeInOut, .exponential]
        {
            let r = ramp(startVelocity: 60, endVelocity: 100, method: method)
            #expect(
                HairpinRamps.interpolate(ramp: r, atOriginalTick: 240) == 80,
                "method \(method) should fall through to linear in v1",
            )
        }
    }

    @Test func activeReturnsLatestContainingRamp() {
        let r1 = ramp(startTick: 0, endTick: 480)
        let r2 = ramp(startTick: 240, endTick: 720)
        #expect(HairpinRamps.active(in: [r1, r2], at: 100)?.startTick == 0)
        #expect(HairpinRamps.active(in: [r1, r2], at: 300)?.startTick == 240)
        #expect(HairpinRamps.active(in: [r1, r2], at: 1000) == nil)
    }
}

struct HairpinRampsCollectTests {
    private let division = 480

    private func instrument() -> Instrument {
        Instrument(id: "piano", articulations: [])
    }

    private func mp() -> Dynamic {
        Dynamic(subtype: "mp", velocity: 64)
    }

    private func mf() -> Dynamic {
        Dynamic(subtype: "mf", velocity: 80)
    }

    private func f() -> Dynamic {
        Dynamic(subtype: "f", velocity: 96)
    }

    private func p() -> Dynamic {
        Dynamic(subtype: "p", velocity: 49)
    }

    private func ppp() -> Dynamic {
        Dynamic(subtype: "ppp", velocity: 16)
    }

    private func quarter() -> VoiceElement {
        .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        ))
    }

    private func makeMeasure(_ elements: [VoiceElement]) -> Measure {
        Measure(voices: [Voice(elements: elements)])
    }

    private func staff(_ measures: [Measure]) -> Staff {
        Staff(measures: measures)
    }

    private func cresc(measures: Int = 1, veloChange: Int? = nil) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .crescendo, veloChange: veloChange),
        )
    }

    private func decresc(measures: Int = 1) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .decrescendo),
        )
    }

    @Test func bracketDynamicsOnBothSides() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.filter { $0.role == .wedge }.count == 1)
        #expect(ramps.first?.startVelocity == 64)
        #expect(ramps.first?.endVelocity == 96)
    }

    /// MuseScore 4 reads no `<veloChange>`: with nothing at its end, a crescendo climbs one of its levels — mp to mf.
    @Test func noEndDynamicClimbsOneLevelWhateverVeloChangeSays() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc(veloChange: 20)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.endVelocity == 80) // one level above mp, whatever <veloChange> says
    }

    /// A wedge with nothing to aim at climbs one MuseScore 4 level (`PlaybackContext::handleHairpin`,
    /// `playbackcontext.cpp:613-615`); MuseScore 3 and MuseScore 4's MIDI export leave it flat, MuseScore 4's playback
    /// does not (owner decision c).
    @Test func noEndDynamicClimbsOneLevel() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.startVelocity == 64)
        #expect(ramps.first?.endVelocity == 80)
    }

    @Test func decrescendoSign() {
        let s = staff([
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.startVelocity == 96)
        #expect(ramps.first?.endVelocity == 49)
        #expect(ramps.first?.endVelocity ?? 99 < ramps.first?.startVelocity ?? 0)
    }

    @Test func backToBackHairpinsShareMiddleDynamic() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        let wedges = ramps.filter { $0.role == .wedge }
        #expect(wedges.count == 2)
        #expect(wedges[0].endVelocity == 96)
        #expect(wedges[1].startVelocity == 96)
        #expect(wedges[1].endVelocity == 49)
    }

    /// Only a Dynamic anchored at the hairpin's own end tick brackets
    /// it. MuseScore 4 resolves the end level from the dynamic *snapped*
    /// to the last hairpin segment
    /// (`PlaybackContext::findNominalEndDynamicType` →
    /// `HairpinSegment::findElementToSnapAfter`), never from the next
    /// dynamic wherever it happens to be. A `ppp` four measures later
    /// describes a different passage, not this hairpin's target — so the
    /// wedge is left with nothing at its end and climbs one level.
    @Test func distantDynamicDoesNotBracketTheHairpin() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([
                .dynamic(ppp()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.endVelocity == 80)
    }

    /// A crescendo running into a *quieter* mark does not aim at it: MuseScore 4 climbs one level instead, up to just
    /// short of the mark (`playbackcontext.cpp:609-624`).
    @Test func endDynamicContradictingTheWedgeIsIgnored() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.endVelocity == 80)
    }

    /// Mirror of `endDynamicContradictingTheWedgeIsIgnored` for a
    /// diminuendo running into a *louder* mark.
    @Test func endDynamicContradictingTheDiminuendoIsIgnored() {
        let s = staff([
            makeMeasure([
                .dynamic(f()), .spanner(decresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(Dynamic(subtype: "ff", velocity: 112)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.endVelocity == 80)
    }

    /// MuseScore 4 reads no `<veloChange>`: the f at the end is the target.
    @Test func theEndDynamicWinsOverVeloChange() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc(veloChange: 20)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        #expect(ramps.first?.endVelocity == 96)
    }

    /// End-to-end through MidiRenderer: the collected ramp is applied to
    /// the rendered note-on velocities.
    @Test func noteVelocitiesRampLinearly() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let part = Part(
            id: "P1",
            instrument: instrument(),
            staves: [s],
        )
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        // 4 onsets in measure 1 ramp from 64 toward 96; chord at the
        // hairpin end (start of measure 2) is set by the bracket
        // Dynamic to 96 and is therefore exactly 96.
        #expect(velocities.first == 64)
        #expect(velocities[4] == 96)
        // Strictly monotonic across the ramp, no flat plateau.
        for i in 0 ..< 4 {
            #expect(velocities[i] < velocities[i + 1])
        }
    }

    /// A hairpin that starts partway through a measure ends where its
    /// `<location>` says, and that location is **relative to the
    /// hairpin's own tick** — `<measures>1</measures>` walks one
    /// measure on from there and `<fractions>-7/8</fractions>` then
    /// steps back, which is how MuseScore spells "from beat 4 of this
    /// measure to the next downbeat". Re-deriving the end from the
    /// measure base instead drops the hairpin's own offset, and the
    /// subtraction lands the end *before* the start — collapsing a real
    /// crescendo to a single tick, which reads at playback as the wedge
    /// having no effect at all.
    ///
    /// `OttavaRanges.computeEndTick` and `LayoutEngine.endAnchor`
    /// already resolve it this way; this is the third copy agreeing.
    @Test func aHairpinStartingMidMeasureEndsWhereItsLocationSays() {
        let s = staff([
            makeMeasure([
                quarter(), quarter(), quarter(),
                .dynamic(ppp()),
                .spanner(Spanner(
                    kind: .hairpin, rawType: "HairPin",
                    nextMeasuresOffset: 1,
                    nextFractionsOffset: Fraction(numerator: -3, denominator: 4),
                    hairpin: .init(subtype: .crescendo),
                )),
                quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        let wedge = ramps.first { $0.role == .wedge }
        #expect(wedge?.startTick == 1440)
        #expect(wedge?.endTick == 1920)
        #expect(wedge?.startVelocity == 16)
        #expect(wedge?.endVelocity == 96)
    }

    /// The level a hairpin reaches is where the part stays until the
    /// next Dynamic says otherwise — a crescendo is not undone by its
    /// own last note. Both MuseScore generations hold it: MS3's
    /// `ChangeMap::val` returns `cachedEndVal` for every tick past a
    /// ramp until the next event, and MS4 writes the ramp's levels into
    /// the same dynamics map the following notes read.
    @Test func theLevelReachedHoldsUntilTheNextDynamic() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        #expect(velocities.count == 12)
        // Measure 3 sits past the wedge with no dynamic of its own and
        // stays at the `f` the crescendo arrived on.
        #expect(Array(velocities[8...]) == Array(repeating: 96, count: 4))
    }

    /// …and a part that never says where its wedges land climbs one MuseScore 4 level per wedge — MuseScore 4's
    /// playback ratchets a dozen `cresc.` up a dozen levels; MuseScore 3.6.2 and MuseScore 4's MIDI export play it flat
    /// (owner decision c: the playback).
    @Test func aPartWithNoWrittenTargetsClimbsALevelPerWedge() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
            makeMeasure([
                .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        #expect(velocities.count == 16)
        #expect(velocities == [64, 68, 72, 76, 80, 80, 80, 80, 80, 84, 88, 92, 96, 96, 96, 96])
    }

    /// A second hairpin picks up where the first left off. MS3 spells
    /// this out in `ChangeMap::cleanupStage3`: a ramp with no fix at its
    /// own tick takes the previous event's value, and for a preceding
    /// ramp that value is its `cachedEndVal`.
    @Test func aSecondHairpinStartsFromTheFirstsEndLevel() {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc(veloChange: 20)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let ramps = HairpinRamps.collect(
            voiceIndex: 0, staff: s,
            instrument: instrument(), division: division,
            tempoMap: ResolvedTempoMap(),
        )
        let wedges = ramps.filter { $0.role == .wedge }
        #expect(wedges.count == 2)
        let reached = 80 // one level above the mp; <veloChange> is not read
        #expect(wedges[1].startVelocity == reached)
        // The second wedge has nothing to aim at either, so it climbs one
        // more level from there rather than starting over from the `mp`.
        #expect(wedges[1].endVelocity == 96)
    }

    /// A Dynamic the wedge could not adopt still governs its own note.
    /// The ramp has to stop just short of it, exactly as MuseScore 4
    /// trims the span (`spannerTo -= Fraction::eps()` when a dynamic
    /// sits on the end tick and is not the level being ramped to) —
    /// otherwise the ramp's own end value would overwrite the mark the
    /// engraver wrote.
    @Test func ignoredEndDynamicStillSoundsAtItsOwnTick() throws {
        let s = staff([
            makeMeasure([
                .dynamic(mp()), .spanner(cresc()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(p()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        #expect(velocities.first == 64)
        // Downbeat of measure 2: the `p`, not the crescendo's target.
        #expect(velocities[4] == 49)
    }
}

/// How a wedge treats the Dynamics written along it.
///
/// Split from `HairpinRampsCollectTests` so each suite stays readable;
/// these render through `MidiRenderer` because what matters is the
/// velocity each beat actually sounds at.
struct HairpinCheckpointTests {
    private let division = 480

    private func instrument() -> Instrument {
        Instrument(id: "piano", articulations: [])
    }

    private func quarter() -> VoiceElement {
        .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        ))
    }

    private func ppp() -> Dynamic {
        Dynamic(subtype: "ppp", velocity: 16)
    }

    private func mf() -> Dynamic {
        Dynamic(subtype: "mf", velocity: 80)
    }

    private func f() -> Dynamic {
        Dynamic(subtype: "f", velocity: 96)
    }

    private func makeMeasure(_ elements: [VoiceElement]) -> Measure {
        Measure(voices: [Voice(elements: elements)])
    }

    private func staff(_ measures: [Measure]) -> Staff {
        Staff(measures: measures)
    }

    private func cresc(measures: Int = 1) -> Spanner {
        Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: measures,
            hairpin: .init(subtype: .crescendo),
        )
    }

    /// Dynamics written under a wedge are checkpoints it passes through,
    /// not decoration. A `ppp` crescendo through `pp` and `mf` to `f`
    /// hits each mark at the beat it is written on, and climbs between
    /// them — so every level played is either a mark the engraver wrote
    /// or an interpolation between two of them.
    ///
    /// Neither MuseScore does this, and both lose information doing it:
    /// MS3 deletes any dynamic enclosed in a hairpin outright
    /// (`ChangeMap::cleanupStage1` — "remove any ramps **or fixes** that
    /// are completely enclosed within other ramps"), so it plays a
    /// smooth 16 → 96 and the marks never sound; MS4's live playback
    /// overwrites them with the hairpin's own curve — rendering this
    /// score to audio from MuseScore 4 gives a waveform identical to
    /// the same score with the marks deleted. MS4's MIDI export is the
    /// closest: it keeps the marks (its `VelocityMap` drops MS3's
    /// erase-enclosed-fixes branch) but plateaus between them.
    @Test func writtenDynamicsInsideTheWedgeArePassedThrough() throws {
        let s = staff([
            makeMeasure([
                .dynamic(ppp()), .spanner(cresc(measures: 2)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(Dynamic(subtype: "pp", velocity: 33)),
                quarter(), quarter(),
                .dynamic(mf()),
                quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(f()),
                quarter(), quarter(), quarter(), quarter(),
            ]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        let v: [Int] = events.compactMap {
            if case let .noteOn(_, _, x) = $0.event { return x } else { return nil }
        }
        // Each mark sounds at its own beat.
        #expect(v[0] == 16) // ppp
        #expect(v[4] == 33) // pp
        #expect(v[6] == 80) // mf
        #expect(v[8] == 96) // f
        // …and the beats between them climb rather than plateau.
        for i in 1 ... 3 {
            #expect(v[i] > v[i - 1] && v[i] < 33)
        }
        #expect(v[5] > 33 && v[5] < 80)
        #expect(v[7] > 80 && v[7] < 96)
    }

    /// A mark that contradicts the wedge stops the ramp without losing
    /// its own level: a crescendo written over a `pp` cannot climb *to*
    /// a level below where it started, so it stays flat until the `pp`,
    /// which then sounds as written — and the wedge resumes climbing
    /// from there to the next mark. MuseScore 3 loses both marks here
    /// (it erases them, then flattens the ramp it can no longer
    /// resolve) and MuseScore 4's live playback ignores them, including
    /// the `ff`.
    @Test func aQuieterMarkStopsTheClimbButKeepsItsOwnLevel() throws {
        let s = staff([
            makeMeasure([
                .spanner(cresc(measures: 2)),
                quarter(), quarter(), quarter(), quarter(),
            ]),
            makeMeasure([
                .dynamic(Dynamic(subtype: "pp", velocity: 33)),
                quarter(), quarter(),
                .dynamic(Dynamic(subtype: "ff", velocity: 112)),
                quarter(), quarter(),
            ]),
            makeMeasure([quarter(), quarter(), quarter(), quarter()]),
        ])
        let part = Part(id: "P1", instrument: instrument(), staves: [s])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: s, part: part,
            route: MidiRenderer.PartChannelRoute(
                defaultChannel: 0, defaultPort: 0, switches: [],
            ),
            division: division,
            plan: MidiRenderer.playbackPlan(for: s.measures, division: division),
            tempoMap: ResolvedTempoMap(),
        )
        let v: [Int] = events.compactMap {
            if case let .noteOn(_, _, x) = $0.event { return x } else { return nil }
        }
        // Nothing to climb to, so the wedge waits at the running level.
        #expect(Array(v[0 ... 3]) == Array(repeating: 80, count: 4))
        #expect(v[4] == 33) // the pp sounds as written
        #expect(v[5] > 33 && v[5] < 112) // then climbs toward the ff
        #expect(v[6] == 112) // ff
        // Past the last mark the wedge has nothing left to aim at, and
        // the level it reached holds beyond the wedge's end.
        #expect(Array(v[6...]) == Array(repeating: 112, count: v.count - 6))
    }
}

/// MuseScore 4 plays a hairpin toward the dynamic at its end when that dynamic lies in the hairpin's direction, and
/// otherwise one of its own levels (`DYNAMIC_LEVEL_STEP`, 5 %) past where it starts; it never reads `<veloChange>`
/// (`PlaybackContext::handleHairpin`, `engraving/playback/playbackcontext.cpp:569-647`). This library's velocities
/// stand for MuseScore 4's levels through `dynList` (`MuseScoreDynamicLevels`) (owner decision c).
@Suite("Hairpin end level, as MuseScore 4 plays it")
struct HairpinEndLevelTests {
    private typealias F = DynamicPlaybackFixtures

    @Test("one level is one ordinary dynamic", arguments: [
        (49, true, 64), (64, true, 80), (80, true, 96), (96, true, 112), (112, true, 126), (126, true, 127),
        (127, true, 127), (80, false, 64), (49, false, 33), (33, false, 16), (5, false, 1), (1, false, 1),
    ] as [(Int, Bool, Int)])
    func oneStepIsOneOrdinaryDynamic(from: Int, up: Bool, to: Int) {
        #expect(MuseScoreDynamicLevels.oneStep(from: from, up: up) == to)
    }

    @Test("a velocity between two dynamics steps from where it stands")
    func betweenTwoDynamics() {
        // 60 is 11/15 of the way from p (49, 42.5 %) to mp (64, 47.5 %): 46.17 %. One level up, 51.17 %, is 0.733 of
        // the way from mp to mf (80, 52.5 %): 75.7, so 76.
        #expect(MuseScoreDynamicLevels.oneStep(from: 60, up: true) == 76)
        #expect(MuseScoreDynamicLevels.level(ofVelocity: 80) == 5250)
        #expect(MuseScoreDynamicLevels.velocity(ofLevel: 5750) == 96)
    }

    @Test("a crescendo with no dynamic at its end climbs one level, and holds it")
    func crescendoWithNoEndDynamicClimbsOneLevel() throws {
        let score = F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 53, 57, 60, 64, 64, 64, 64])
    }

    @Test("a diminuendo with no dynamic at its end falls one level")
    func diminuendoWithNoEndDynamicFallsOneLevel() throws {
        let score = F.score([
            [F.dynamic("f"), F.diminuendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [96, 92, 88, 84, 80, 80, 80, 80])
    }

    @Test("<veloChange> is not read: the end dynamic wins, and without one the change is one level")
    func veloChangeIsNotRead() throws {
        let withEnd = F.score([
            [F.dynamic("p"), F.crescendo(veloChange: 10), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("f"), F.quarter],
        ])
        #expect(try F.velocities(withEnd) == [49, 61, 73, 84, 96])
        let withoutEnd = F.score([
            [F.dynamic("p"), F.crescendo(veloChange: 40), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter],
        ])
        #expect(try F.velocities(withoutEnd) == [49, 53, 57, 60, 64])
    }

    @Test("an end dynamic against the hairpin's direction: one level up to it, then the dynamic on its own beat")
    func endDynamicAgainstTheDirection() throws {
        let score = F.score([
            [F.dynamic("mf"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("p"), F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [80, 84, 88, 92, 49, 49])
    }

    @Test("hairpins with no dynamics climb a level each")
    func successiveHairpinsClimbALevelEach() throws {
        let score = F.score([
            [F.dynamic("mp"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter],
        ])
        #expect(try F.velocities(score) == [64, 68, 72, 76, 80, 84, 88, 92, 96])
    }
}
